//  SPECTRE Capture — SpectreCore
//  Persistent, idempotent state machine:
//  awaitingPreparation → queued → uploading → awaitingVerification → confirmed → completed
//  Every transition is written to the QueueStore BEFORE the next side effect,
//  so a crash at any point resumes safely. Local copies are deleted only from
//  `confirmed`, with a receipt re-verified at deletion time.

import Foundation

public struct RetryPolicy: Sendable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var maxAutomaticAttempts: Int
    public var maxPendingChecks: Int
    public init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 15 * 60,
                maxAutomaticAttempts: Int = 8, maxPendingChecks: Int = 20) {
        self.baseDelay = baseDelay; self.maxDelay = maxDelay
        self.maxAutomaticAttempts = maxAutomaticAttempts; self.maxPendingChecks = maxPendingChecks
    }
    public func delay(forAttempt n: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(max(0, n - 1))))
    }
}

public actor DepositEngine {
    private let store: QueueStore
    private let outbox: EncryptedOutbox
    private let secrets: SecretStore
    private let credentials: CredentialVault
    private let backend: DepositBackend
    private let uploader: ResumableUploader
    private let verifier: ReceiptVerifier
    private let deletion: DeletionCoordinator
    private let retry: RetryPolicy
    private let clock: @Sendable () -> Date
    private let log: SpectreLog
    private var inFlight: Set<CaptureID> = []
    private var pendingChecks: [CaptureID: Int] = [:]
    private var observers: [@Sendable (CaptureRecord) -> Void] = []

    public init(store: QueueStore, outbox: EncryptedOutbox, secrets: SecretStore,
                backend: DepositBackend, uploader: ResumableUploader,
                verifier: ReceiptVerifier = ReceiptVerifier(),
                deletion: DeletionCoordinator, retry: RetryPolicy = RetryPolicy(),
                clock: @escaping @Sendable () -> Date = { Date() }, log: SpectreLog = SpectreLog(sink: nil)) {
        self.store = store; self.outbox = outbox; self.secrets = secrets
        self.credentials = CredentialVault(secrets: secrets)
        self.backend = backend; self.uploader = uploader; self.verifier = verifier
        self.deletion = deletion; self.retry = retry; self.clock = clock; self.log = log
    }

    public func addObserver(_ o: @escaping @Sendable (CaptureRecord) -> Void) { observers.append(o) }

    // MARK: - Intake

    /// Step 1 (synchronous with the end of recording): durable task creation.
    /// Idempotent: registering the same captureId twice returns the existing record.
    @discardableResult
    public func register(captureId: CaptureID = UUID().uuidString.lowercased(), mimeType: String,
                         fileExtension: String, localCopies: [LocalCopyRef]) throws -> CaptureRecord {
        if let existing = try store.load(captureId) { return existing }
        var r = CaptureRecord(captureId: captureId, createdAt: clock(), mimeType: mimeType,
                              fileExtension: fileExtension, stage: .awaitingPreparation, localCopies: localCopies)
        r.localCopies.append(LocalCopyRef(kind: .outboxEncrypted, reference: captureId))
        try persist(&r)
        log.event("registered", ["capture": captureId])
        return r
    }

    /// Step 2: build the encrypted outbox from the original plaintext file.
    /// `expectedSHA256` (e.g. the hash Tella computed at import) is cross-checked.
    public func prepare(captureId: CaptureID, plaintextURL: URL, expectedSHA256: String?) throws -> CaptureRecord {
        guard var r = try store.load(captureId) else { throw SpectreError.invalidCaptureId }
        guard r.stage == .awaitingPreparation else { return r }
        do {
            let fp = try outbox.importPlaintext(from: plaintextURL, captureId: captureId)
            if let e = expectedSHA256?.lowercased(), !e.isEmpty, e != fp.sha256 {
                try? outbox.destroy(captureId)
                throw SpectreError.outboxCorrupted
            }
            guard fp.size > 0 else { try? outbox.destroy(captureId); throw SpectreError.protocolViolation("empty") }
            r.fingerprint = fp
            r.stage = .queued
            r.failure = nil
            try persist(&r)
            log.event("prepared", ["capture": captureId, "bytes": String(fp.size)])
        } catch {
            r.failure = CaptureFailure(kind: .preparationFailed,
                                       message: "Préparation de l'envoi impossible ; la vidéo reste dans le coffre.",
                                       attempts: r.failure.map { $0.attempts + 1 } ?? 1, nextAttemptAt: nil)
            try persist(&r)
            throw error
        }
        return r
    }

    // MARK: - Queries

    public func record(_ id: CaptureID) throws -> CaptureRecord? { try store.load(id) }
    public func allRecords() throws -> [CaptureRecord] { try store.all() }

    /// Earliest date at which `processAll` has something to do (for BG scheduling).
    public func nextWakeDate() throws -> Date? {
        try store.all().compactMap { r -> Date? in
            switch r.stage {
            case .completed, .blocked, .awaitingPreparation: return nil
            default: return r.failure?.nextAttemptAt ?? r.notBefore ?? (r.failure == nil ? clock() : nil)
            }
        }.min()
    }

    // MARK: - User actions

    /// "Réessayer": clears a halted failure. After an integrity block, a brand-new
    /// upload is requested; the server never overwrites a verified file.
    public func retryNow(_ id: CaptureID) throws {
        guard var r = try store.load(id) else { return }
        if r.stage == .blocked {
            r.stage = .queued
            r.forceNewUpload = true
            r.uploadId = nil
            r.driveFileIdFromUpload = nil
            r.receipt = nil
            r.bytesConfirmedByServer = 0
            try? secrets.delete(SecretKeys.session(id))
        }
        r.failure = nil
        r.transientAttempts = 0
        r.notBefore = nil
        pendingChecks[id] = 0
        try persist(&r)
    }

    // MARK: - Processing

    public func processAll() async {
        guard let all = try? store.all() else { return }
        for r in all { _ = await process(r.captureId) }
    }

    @discardableResult
    public func process(_ id: CaptureID) async -> CaptureRecord? {
        guard !inFlight.contains(id) else { return try? store.load(id) }   // T08: no concurrent duplicate
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        var steps = 0
        while steps < 12 {
            steps += 1
            guard var r = try? store.load(id) else { return nil }
            let now = clock()
            if let f = r.failure {
                guard f.kind.isAutomaticallyRetryable, let at = f.nextAttemptAt, at <= now else { return r }
            }
            if let nb = r.notBefore, nb > now { return r }

            switch r.stage {
            case .awaitingPreparation, .completed, .blocked, .failed:
                return r
            case .queued:
                await authorize(&r)
            case .uploading:
                await upload(&r)
            case .awaitingVerification:
                await finalize(&r)
            case .confirmed:
                deleteLocal(&r)
            }
            if r.failure != nil || r.notBefore != nil { return r }
        }
        return try? store.load(id)
    }

    // MARK: steps

    private func authorize(_ r: inout CaptureRecord) async {
        guard let creds = credentials.load() else {
            fail(&r, .notEnrolled, "Appareil non enrôlé ; scannez votre invitation.")
            return
        }
        guard let fp = r.fingerprint else { fail(&r, .preparationFailed, "Empreinte manquante"); return }
        do {
            let res = try await backend.initUpload(InitUploadRequest(
                captureId: r.captureId, size: fp.size, sha256: fp.sha256, md5: fp.md5,
                mimeType: r.mimeType, ext: r.fileExtension,
                renewSession: r.renewSession, forceNewUpload: r.forceNewUpload), credentials: creds)
            switch res {
            case .session(let uploadId, let url):
                try secrets.set(Data(url.absoluteString.utf8), for: SecretKeys.session(r.captureId))
                if r.uploadId != uploadId { r.driveFileIdFromUpload = nil; r.bytesConfirmedByServer = 0 }
                r.uploadId = uploadId
                r.stage = .uploading
            case .finalizeExisting(let uploadId):
                r.uploadId = uploadId
                r.stage = .awaitingVerification
            case .alreadyVerified(let receipt):
                r.uploadId = receipt.uploadId
                acceptReceipt(&r, receipt, creds)
                if r.stage != .confirmed { return }
            }
            r.renewSession = false
            r.forceNewUpload = false
            succeed(&r)
            log.event("authorized", ["capture": r.captureId])
        } catch {
            handle(&r, error)
        }
    }

    private func upload(_ r: inout CaptureRecord) async {
        guard let fp = r.fingerprint else { fail(&r, .preparationFailed, "Empreinte manquante"); return }
        guard let raw = (try? secrets.get(SecretKeys.session(r.captureId))) ?? nil,
              let session = URL(string: String(decoding: raw, as: UTF8.self)) else {
            r.stage = .queued
            try? persist(&r)
            return
        }
        let id = r.captureId
        let store = self.store
        let outbox = self.outbox
        do {
            let fileId = try await uploader.upload(
                session: session, total: fp.size,
                read: { off, len in try outbox.readPlaintext(id, offset: off, length: len) },
                progress: { confirmed in
                    if var cur = try? store.load(id), cur.bytesConfirmedByServer != confirmed {
                        cur.bytesConfirmedByServer = confirmed
                        cur.updatedAt = Date()
                        try? store.save(cur)
                    }
                })
            r = (try? store.load(id)) ?? r
            r.driveFileIdFromUpload = fileId
            r.bytesConfirmedByServer = fp.size
            r.stage = .awaitingVerification
            succeed(&r)
            log.event("uploaded", ["capture": id, "bytes": String(fp.size)])
        } catch SpectreError.sessionExpired {
            r = (try? store.load(id)) ?? r
            try? secrets.delete(SecretKeys.session(id))
            r.renewSession = true
            r.stage = .queued
            r.bytesConfirmedByServer = 0
            handle(&r, SpectreError.sessionExpired)
        } catch {
            r = (try? store.load(id)) ?? r
            handle(&r, error)
        }
    }

    private func finalize(_ r: inout CaptureRecord) async {
        guard let creds = credentials.load() else { fail(&r, .notEnrolled, "Appareil non enrôlé"); return }
        guard let uid = r.uploadId else { r.stage = .queued; try? persist(&r); return }
        do {
            switch try await backend.finalize(uploadId: uid, captureId: r.captureId,
                                              driveFileId: r.driveFileIdFromUpload, credentials: creds) {
            case .verified(let receipt):
                acceptReceipt(&r, receipt, creds)
            case .pending(let after):
                let n = (pendingChecks[r.captureId] ?? 0) + 1
                pendingChecks[r.captureId] = n
                if n > retry.maxPendingChecks {
                    fail(&r, .serverUnavailable, "Vérification Drive non disponible pour l'instant ; la vidéo reste sur le téléphone.")
                } else {
                    r.notBefore = clock().addingTimeInterval(max(1, after))
                    try? persist(&r)
                }
            case .incomplete:
                r.stage = .uploading
                try? persist(&r)
            case .mismatch(let detail):
                block(&r, .integrityMismatch, "Le fichier sur le Drive ne correspond pas (\(detail)). Original conservé.")
            }
        } catch {
            handle(&r, error)
        }
    }

    private func acceptReceipt(_ r: inout CaptureRecord, _ receipt: DepositReceipt, _ creds: DeviceCredentials) {
        switch verifier.verify(receipt, record: r, credentials: creds) {
        case .verified:
            r.receipt = receipt
            r.stage = .confirmed       // persisted BEFORE any deletion
            succeed(&r)
            try? secrets.delete(SecretKeys.session(r.captureId))
            log.event("verified", ["capture": r.captureId])
        case .rejected(let kind, let reason):
            block(&r, kind, reason + ". Original conservé.")
        }
    }

    private func deleteLocal(_ r: inout CaptureRecord) {
        guard let creds = credentials.load(), let receipt = r.receipt else {
            fail(&r, .notEnrolled, "Reçu ou identifiants indisponibles ; suppression différée.")
            return
        }
        // Re-verify at deletion time (receipt read back from disk).
        guard case .verified(let proof) = verifier.verify(receipt, record: r, credentials: creds) else {
            block(&r, .receiptInvalid, "Reçu stocké invalide ; suppression bloquée.")
            return
        }
        let report = deletion.deleteLocalCopies(of: r, authorizedBy: proof)
        r.remainingCopies = Array(report.failed.keys).sorted { $0.rawValue < $1.rawValue }
        if report.allDeleted {
            r.stage = .completed
            succeed(&r)
            log.event("local-deleted", ["capture": r.captureId, "copies": String(report.deleted.count)])
        } else {
            r.failure = CaptureFailure(kind: .localDeletionFailed,
                                       message: "Transfert confirmé, mais une copie locale n'a pas pu être supprimée.",
                                       attempts: (r.failure?.attempts ?? 0) + 1,
                                       nextAttemptAt: clock().addingTimeInterval(retry.delay(forAttempt: (r.failure?.attempts ?? 0) + 1)))
            try? persist(&r)
            log.event("local-delete-incomplete", ["capture": r.captureId, "copies": String(report.failed.count)])
        }
    }

    // MARK: failure handling

    private func handle(_ r: inout CaptureRecord, _ error: Error) {
        let (kind, msg) = Self.classify(error)
        if kind == .integrityMismatch || kind == .receiptInvalid { block(&r, kind, msg); return }
        let attempts = r.transientAttempts + 1
        r.transientAttempts = attempts
        let auto = kind.isAutomaticallyRetryable && attempts < retry.maxAutomaticAttempts
        r.failure = CaptureFailure(kind: kind, message: msg, attempts: attempts,
                                   nextAttemptAt: auto ? clock().addingTimeInterval(retry.delay(forAttempt: attempts)) : nil)
        try? persist(&r)
        log.event("failure", ["capture": r.captureId, "kind": kind.rawValue, "attempt": String(attempts)])
    }

    private func fail(_ r: inout CaptureRecord, _ kind: FailureKind, _ msg: String) {
        r.failure = CaptureFailure(kind: kind, message: msg, attempts: r.transientAttempts + 1, nextAttemptAt: nil)
        try? persist(&r)
        log.event("failure", ["capture": r.captureId, "kind": kind.rawValue])
    }

    private func block(_ r: inout CaptureRecord, _ kind: FailureKind, _ msg: String) {
        r.stage = .blocked
        r.failure = CaptureFailure(kind: kind, message: msg, attempts: r.transientAttempts, nextAttemptAt: nil)
        try? persist(&r)
        log.event("blocked", ["capture": r.captureId, "kind": kind.rawValue])
    }

    private func succeed(_ r: inout CaptureRecord) {
        r.failure = nil
        r.transientAttempts = 0
        r.notBefore = nil
        try? persist(&r)
    }

    private func persist(_ r: inout CaptureRecord) throws {
        r.updatedAt = clock()
        try store.save(r)
        let snapshot = r
        for o in observers { o(snapshot) }
    }

    static func classify(_ error: Error) -> (FailureKind, String) {
        switch error {
        case SpectreError.transport:
            return (.network, "Réseau indisponible ; nouvel essai automatique.")
        case SpectreError.sessionExpired:
            return (.sessionExpired, "Session d'envoi expirée ; une nouvelle sera demandée.")
        case SpectreError.http(let s) where s == 429:
            return (.rateLimited, "Trop de requêtes ; nouvel essai plus tard.")
        case SpectreError.http(let s) where s >= 500:
            return (.serverUnavailable, "Service Google indisponible (\(s)).")
        case SpectreError.http(let s) where s == 401 || s == 403:
            return (.deviceNotAuthorized, "Envoi refusé par le serveur (\(s)).")
        case SpectreError.http(let s):
            return (.invalidRequest, "Requête refusée (\(s)).")
        case SpectreError.outboxKeyMissing, SpectreError.outboxCorrupted, SpectreError.outboxRange:
            return (.preparationFailed, "Copie d'envoi locale illisible ; la vidéo du coffre est conservée.")
        case SpectreError.backend(let code, _):
            switch code {
            case "DEVICE_REVOKED": return (.deviceNotAuthorized, "Cet appareil a été révoqué par le responsable.")
            case "DEVICE_EXPIRED": return (.deviceNotAuthorized, "L'autorisation de cet appareil a expiré.")
            case "AUTH_INVALID", "REPLAY": return (.deviceNotAuthorized, "Authentification refusée.")
            case "RATE_LIMITED": return (.rateLimited, "Trop de requêtes ; nouvel essai plus tard.")
            case "QUOTA_EXCEEDED": return (.quotaExceeded, "Quota de dépôt de l'appareil atteint ; nouvel essai plus tard.")
            case "DRIVE_QUOTA": return (.driveQuotaExceeded, "Espace Drive du responsable plein ; vidéo conservée.")
            case "DRIVE_UNAVAILABLE", "INTERNAL", "BUSY": return (.serverUnavailable, "Service Google indisponible.")
            case "FILE_TOO_LARGE": return (.fileTooLarge, "Fichier trop volumineux pour la politique de dépôt.")
            case "MISMATCH": return (.integrityMismatch, "Incohérence d'intégrité signalée par le serveur.")
            default: return (.invalidRequest, "Requête refusée (\(code)).")
            }
        default:
            return (.unknown, "Erreur inattendue ; la vidéo est conservée.")
        }
    }
}
