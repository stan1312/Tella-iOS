//  SPECTRE Capture — SpectreCore
//  Persistent model of one capture travelling through the deposit pipeline.

import Foundation

public typealias CaptureID = String

/// Kinds of local copies the app manages for one capture. Each must be
/// processed by the DeletionCoordinator once a verified receipt exists.
public enum LocalCopyKind: String, Codable, Sendable, CaseIterable {
    case outboxEncrypted      // SPECTRE encrypted outbox container (+ its key)
    case vaultEntry           // Tella vault: encrypted container + DB row (incl. thumbnail)
    case plaintextTemp        // decrypted temp file used while preparing the outbox
    case cameraOriginalTemp   // AVCaptureMovieFileOutput file in NSTemporaryDirectory
    case uploadChunkTemp      // per-chunk temp files used by background transfers
}

public enum FailureKind: String, Codable, Sendable {
    case network                // offline, timeout, DNS, TLS
    case serverUnavailable      // 5xx, Apps Script unavailable
    case rateLimited
    case quotaExceeded          // per-device quota (backend)
    case driveQuotaExceeded     // owner Drive full
    case deviceNotAuthorized    // revoked / expired / unknown credentials
    case notEnrolled
    case sessionExpired
    case fileTooLarge
    case insufficientStorage
    case preparationFailed      // could not read the vault / build the outbox
    case integrityMismatch      // remote size/checksum differs — deletion BLOCKED
    case receiptInvalid         // receipt failed verification — deletion BLOCKED
    case localDeletionFailed
    case invalidRequest
    case unknown

    /// Whether the engine may retry on its own (bounded).
    public var isAutomaticallyRetryable: Bool {
        switch self {
        case .network, .serverUnavailable, .rateLimited, .sessionExpired, .driveQuotaExceeded, .quotaExceeded:
            return true
        default:
            return false
        }
    }
}

public enum CaptureStage: String, Codable, Sendable {
    case awaitingPreparation   // vault entry exists; outbox not built yet (needs unlocked vault)
    case queued                // outbox ready, waiting for network/authorization
    case uploading             // resumable session active
    case awaitingVerification  // all bytes sent; waiting for server-side verification
    case confirmed             // verified receipt stored; local deletion pending
    case completed             // receipt verified AND all managed local copies deleted
    case failed                // see failure; original kept
    case blocked               // integrity problem; original kept; needs human attention
}

public struct CaptureFailure: Codable, Equatable, Sendable {
    public var kind: FailureKind
    public var message: String          // non-sensitive, user-facing (FR)
    public var attempts: Int
    public var nextAttemptAt: Date?
    public init(kind: FailureKind, message: String, attempts: Int, nextAttemptAt: Date?) {
        self.kind = kind; self.message = message; self.attempts = attempts; self.nextAttemptAt = nextAttemptAt
    }
}

public struct LocalCopyRef: Codable, Equatable, Sendable {
    public var kind: LocalCopyKind
    /// Opaque reference interpreted by the platform adapter (vault id, file path…).
    public var reference: String
    public init(kind: LocalCopyKind, reference: String) { self.kind = kind; self.reference = reference }
}

public struct CaptureRecord: Codable, Equatable, Sendable {
    public var captureId: CaptureID
    public var createdAt: Date
    public var mimeType: String
    public var fileExtension: String
    public var fingerprint: FileFingerprint?      // computed while building the outbox
    public var stage: CaptureStage
    public var uploadId: String?
    public var driveFileIdFromUpload: String?     // as returned by Drive at the last chunk
    public var bytesConfirmedByServer: UInt64
    public var receipt: DepositReceipt?
    public var failure: CaptureFailure?
    public var localCopies: [LocalCopyRef]
    public var remainingCopies: [LocalCopyKind]   // after a (partial) deletion
    public var transientAttempts: Int
    /// Scheduled wait that is not an error (e.g. Drive checksum not computed yet).
    public var notBefore: Date?
    /// Set when the user asks to resend after an integrity block.
    public var forceNewUpload: Bool
    /// Set when the resumable session expired and a new one must be issued.
    public var renewSession: Bool
    public var updatedAt: Date

    public init(captureId: CaptureID = UUID().uuidString.lowercased(),
                createdAt: Date = Date(),
                mimeType: String,
                fileExtension: String,
                fingerprint: FileFingerprint? = nil,
                stage: CaptureStage,
                localCopies: [LocalCopyRef]) {
        self.captureId = captureId
        self.createdAt = createdAt
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.fingerprint = fingerprint
        self.stage = stage
        self.uploadId = nil
        self.driveFileIdFromUpload = nil
        self.bytesConfirmedByServer = 0
        self.receipt = nil
        self.failure = nil
        self.localCopies = localCopies
        self.remainingCopies = []
        self.transientAttempts = 0
        self.notBefore = nil
        self.forceNewUpload = false
        self.renewSession = false
        self.updatedAt = createdAt
    }
}

/// Receipt returned by the deposit backend once it has itself verified the
/// Drive file. It is authenticated with an HMAC keyed by the device secret.
public struct DepositReceipt: Codable, Equatable, Sendable {
    public var v: Int
    public var status: String
    public var captureId: String
    public var uploadId: String
    public var deviceId: String
    public var driveFileId: String
    public var size: UInt64
    public var sha256: String
    public var md5: String
    public var checksumSource: String   // "sha256" or "md5" (when Drive has no sha256)
    public var verifiedAt: String
    public var mac: String

    public init(v: Int, status: String, captureId: String, uploadId: String, deviceId: String,
                driveFileId: String, size: UInt64, sha256: String, md5: String,
                checksumSource: String, verifiedAt: String, mac: String) {
        self.v = v; self.status = status; self.captureId = captureId; self.uploadId = uploadId
        self.deviceId = deviceId; self.driveFileId = driveFileId; self.size = size
        self.sha256 = sha256; self.md5 = md5; self.checksumSource = checksumSource
        self.verifiedAt = verifiedAt; self.mac = mac
    }

    /// Canonical string covered by the MAC. MUST match backend `receiptCanonical_`.
    public var canonicalString: String {
        ["spectre-receipt-v1", String(v), status, captureId, uploadId, deviceId,
         driveFileId, String(size), sha256, md5, checksumSource, verifiedAt].joined(separator: "\n")
    }
}

/// User-facing status (mandate §3.1: Filmer / En attente / Transfert en cours /
/// Transfert confirmé / Erreur – à réessayer) plus the honest intermediate states.
public enum UserFacingStatus: Equatable, Sendable {
    case pending                    // "En attente" — still on this phone
    case transferring(progress: Double)
    case verifying
    case confirmedLocalCopyRemains  // confirmed on Drive but a local copy still exists
    case confirmed                  // confirmed and local managed copies deleted
    case error(retryable: Bool, message: String)
    case blocked(message: String)

    public var labelFR: String {
        switch self {
        case .pending: return "En attente (vidéo encore sur ce téléphone)"
        case .transferring(let p): return "Transfert en cours (\(Int((p * 100).rounded())) %)"
        case .verifying: return "Vérification sur le Drive…"
        case .confirmedLocalCopyRemains: return "Transfert confirmé — copie locale encore présente"
        case .confirmed: return "Transfert confirmé — supprimée du téléphone"
        case .error(let r, let m): return (r ? "Erreur — nouvel essai prévu : " : "Erreur — à réessayer : ") + m
        case .blocked(let m): return "Suppression BLOQUÉE : " + m
        }
    }
}

extension CaptureRecord {
    public var userFacingStatus: UserFacingStatus {
        switch stage {
        case .awaitingPreparation, .queued:
            if let f = failure { return .error(retryable: f.kind.isAutomaticallyRetryable, message: f.message) }
            return .pending
        case .uploading:
            if let f = failure { return .error(retryable: f.kind.isAutomaticallyRetryable, message: f.message) }
            let total = Double(fingerprint?.size ?? 0)
            return .transferring(progress: total > 0 ? Double(bytesConfirmedByServer) / total : 0)
        case .awaitingVerification:
            if let f = failure { return .error(retryable: f.kind.isAutomaticallyRetryable, message: f.message) }
            return .verifying
        case .confirmed: return .confirmedLocalCopyRemains
        case .completed: return remainingCopies.isEmpty ? .confirmed : .confirmedLocalCopyRemains
        case .failed: return .error(retryable: failure?.kind.isAutomaticallyRetryable ?? false,
                                    message: failure?.message ?? "Erreur inconnue")
        case .blocked: return .blocked(message: failure?.message ?? "Incohérence détectée")
        }
    }
}
