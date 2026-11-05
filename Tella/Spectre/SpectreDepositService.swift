//
//  SPECTRE Capture — glue between Tella and SpectreCore.
//
//  Flow: CameraService records → Tella encrypts into its vault (unchanged) →
//  EncryptionService reports .completed for a camera file → handleNewCameraVideo
//  registers a durable task and builds the SPECTRE encrypted outbox from the
//  vault copy → DepositEngine uploads to Drive via a backend-issued resumable
//  session → backend verifies → receipt verified → all managed copies deleted.
//
//  The service lives in MainAppModel (not in a view), so the queue does not
//  depend on the screen currently displayed.
//

import Foundation
import Combine
import UIKit
import BackgroundTasks
#if canImport(SpectreCore)
import SpectreCore
#endif

/// Not actor-isolated so that MainAppModel can create it from any context;
/// published state is always updated on the main queue.
final class SpectreDepositService: ObservableObject, @unchecked Sendable {

    /// Weak handle for the BGTaskScheduler launch handler (registered in AppDelegate).
    static weak var current: SpectreDepositService?

    static let backgroundTaskIdentifier: String = (Bundle.main.bundleIdentifier ?? "spectre") + ".spectre-upload"

    @Published private(set) var records: [CaptureRecord] = []
    @Published private(set) var isEnrolled: Bool = false
    @Published private(set) var lastEnrollmentError: String?

    private weak var mainAppModel: MainAppModel?
    private let secrets = SpectreKeychainSecretStore()
    private let engine: DepositEngine?
    private var cancellables: Set<AnyCancellable> = []
    private var preparing: Set<String> = []
    private let preparingLock = NSLock()

    init(mainAppModel: MainAppModel) {
        self.mainAppModel = mainAppModel
        SpectreStorage.prepareDirectories()
        let transport = URLSessionTransport(timeout: 60)
        var built: DepositEngine?
        do {
            let store = try FileQueueStore(directory: SpectreStorage.queueDirectory)
            store.didWriteFile = { SpectreStorage.protect($0) }
            let outbox = try EncryptedOutbox(directory: SpectreStorage.outboxDirectory, secrets: secrets)
            outbox.didCreateFile = { SpectreStorage.protect($0) }
            let deletion = DeletionCoordinator(handlers: [
                OutboxCopyHandler(outbox: outbox),
                TellaVaultCopyHandler(mainAppModel: mainAppModel),
                FileCopyHandler(kind: .plaintextTemp, allowedRoot: URL(fileURLWithPath: NSTemporaryDirectory())),
            ])
            built = DepositEngine(store: store, outbox: outbox, secrets: secrets,
                                  backend: HTTPDepositBackend(transport: transport),
                                  uploader: ResumableUploader(transport: transport, chunkSize: 8 * 1024 * 1024),
                                  deletion: deletion, log: SpectreLog(sink: nil))   // no technical log on device by default
        } catch {
            built = nil
        }
        engine = built
        _isEnrolled = Published(initialValue: CredentialVault(secrets: secrets).load() != nil)

        mainAppModel.networkMonitor.connectionDidChange
            .filter { $0 }
            .sink { [weak self] _ in self?.kick() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.kick() }
            .store(in: &cancellables)
        SpectreDepositService.current = self
        Task { await self.refresh() }
    }

    // MARK: - Capture intake (called from EncryptionService)

    /// Deterministic capture id derived from the Tella vault id, so that a
    /// repeated callback for the same file can never create a second task.
    static func captureId(forVaultFileId id: String) -> String {
        let h = SpectreCrypto.sha256Hex(Data(("spectre-capture:" + id).utf8))
        let c = Array(h.prefix(32))
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-4\(String(c[13..<16]))-a\(String(c[17..<20]))-\(String(c[20..<32]))"
    }

    func handleNewCameraVideo(_ vaultFile: VaultFileDB) {
        guard let engine, let vaultId = vaultFile.id, vaultFile.tellaFileType == .video else { return }
        let captureId = Self.captureId(forVaultFileId: vaultId)
        let ext = vaultFile.fileExtension.lowercased() == "mp4" ? "mp4" : "mov"
        let mime = ext == "mp4" ? "video/mp4" : "video/quicktime"
        Task {
            do {
                // 1) durable task, created immediately at the end of the recording
                try await engine.register(captureId: captureId, mimeType: mime, fileExtension: ext,
                                          localCopies: [LocalCopyRef(kind: .vaultEntry, reference: vaultId)])
                await self.refresh()
                // 2) outbox (needs the unlocked vault; otherwise retried at next unlock)
                await self.prepare(captureId: captureId, vaultFile: vaultFile)
                self.kick()
            } catch {
                await self.refresh()
            }
        }
    }

    /// Builds the outbox for every capture still waiting for it (called after unlock).
    func prepareAwaitingCaptures() {
        guard let engine, let files = mainAppModel?.vaultFilesManager else { return }
        Task {
            let waiting = ((try? await engine.allRecords()) ?? []).filter { $0.stage == .awaitingPreparation }
            for r in waiting {
                guard let ref = r.localCopies.first(where: { $0.kind == .vaultEntry }),
                      let vf = files.getVaultFile(id: ref.reference) else { continue }
                await self.prepare(captureId: r.captureId, vaultFile: vf)
            }
            self.kick()
        }
    }

    private func prepare(captureId: String, vaultFile: VaultFileDB) async {
        guard let engine, let app = mainAppModel, app.vaultManager.isUnlocked else { return }
        let claimed: Bool = preparingLock.withLock { preparing.insert(captureId).inserted }
        guard claimed else { return }
        defer { preparingLock.withLock { _ = preparing.remove(captureId) } }
        guard let plaintext = await app.vaultManager.loadVaultFileToURLAsync(file: vaultFile) else { return }
        defer { app.vaultManager.deleteTmpFiles(files: [plaintext]) }   // Tella's secure temp wipe
        _ = try? await engine.prepare(captureId: captureId, plaintextURL: plaintext, expectedSHA256: vaultFile.hash)
        await refresh()
    }

    // MARK: - Processing

    func kick() {
        guard let engine else { return }
        Task { @MainActor in
            // A few extra minutes after leaving the app; iOS gives no guarantee.
            let bg = UIApplication.shared.beginBackgroundTask(withName: "spectre-deposit") { }
            await engine.processAll()
            await self.refresh()
            self.scheduleBackgroundProcessing()
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    func retry(_ captureId: String) {
        guard let engine else { return }
        Task { try? await engine.retryNow(captureId); self.kick() }
    }

    private func refresh() async {
        guard let engine else { return }
        let all = ((try? await engine.allRecords()) ?? []).sorted { $0.createdAt > $1.createdAt }
        let enrolled = CredentialVault(secrets: secrets).load() != nil
        await MainActor.run {
            self.records = all
            self.isEnrolled = enrolled
        }
    }

    // MARK: - Tella quick delete

    /// Tella "quick delete": the user wants no video left on this phone, deposited or not.
    /// Removes queue records, encrypted outbox copies and their per-capture keys
    /// (crypto-erase); keeps the device enrolment. Captures not yet deposited are lost
    /// on purpose — that is what the user asked for.
    func wipeQueuedCaptures() {
        Task {
            let ids = ((try? await engine?.allRecords()) ?? []).map(\.captureId)
            for id in ids {
                try? secrets.delete(SecretKeys.outboxKey(id))
                try? secrets.delete(SecretKeys.session(id))
            }
            try? FileManager.default.removeItem(at: SpectreStorage.queueDirectory)
            try? FileManager.default.removeItem(at: SpectreStorage.outboxDirectory)
            SpectreStorage.prepareDirectories()
            await refresh()
        }
    }

    // MARK: - Enrolment

    func enroll(with payload: String) async -> Bool {
        do {
            #if DEBUG
            let invite = try EnrollmentParser.parse(payload, allowInsecureLocalhost: true)
            #else
            let invite = try EnrollmentParser.parse(payload)
            #endif
            _ = try await CredentialVault(secrets: secrets).enroll(using: invite, backend: HTTPDepositBackend(transport: URLSessionTransport()))
            await MainActor.run { self.lastEnrollmentError = nil }
            if let engine {
                for r in (try? await engine.allRecords()) ?? [] where r.failure?.kind == .notEnrolled || r.failure?.kind == .deviceNotAuthorized {
                    try? await engine.retryNow(r.captureId)
                }
            }
            await refresh()
            kick()
            return true
        } catch {
            await MainActor.run { self.lastEnrollmentError = "Invitation invalide, expirée ou déjà utilisée." }
            return false
        }
    }

    // MARK: - Background (best effort: iOS decides when this runs)

    static func registerBackgroundTask(handler: @escaping () -> SpectreDepositService?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            Task { @MainActor in
                guard let service = handler(), let engine = service.engine else { task.setTaskCompleted(success: false); return }
                let work = Task { await engine.processAll() }
                task.expirationHandler = { work.cancel() }
                await work.value
                await service.refresh()
                service.scheduleBackgroundProcessing()
                task.setTaskCompleted(success: true)
            }
        }
    }

    @MainActor private func scheduleBackgroundProcessing() {
        let pending = records.contains { ![.completed, .blocked].contains($0.stage) }
        guard pending else { return }
        let req = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        req.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}
