//  SPECTRE Capture — SpectreCore
//  Deletes every app-managed local copy of a capture, ONLY with a VerifiedReceipt.

import Foundation

public protocol LocalCopyHandler: Sendable {
    var kind: LocalCopyKind { get }
    func delete(_ ref: LocalCopyRef) throws
    func exists(_ ref: LocalCopyRef) -> Bool
}

public struct DeletionReport: Equatable, Sendable {
    public var deleted: [LocalCopyKind]
    public var failed: [LocalCopyKind: String]
    public var allDeleted: Bool { failed.isEmpty }

    /// Honest statement shown in the UI / handover (mandate §3.3).
    public static let limitations = [
        "La suppression retire les fichiers et clés gérés par l'application ; l'effacement physique de la mémoire flash n'est pas garanti.",
        "Le conteneur d'envoi est chiffré avec une clé propre à la captation, détruite en premier (effacement cryptographique).",
        "Les copies créées hors de l'application (capture d'écran, autre app, sauvegarde antérieure) ne sont pas couvertes.",
    ]
}

public final class DeletionCoordinator: @unchecked Sendable {
    private let handlers: [LocalCopyKind: LocalCopyHandler]
    /// Deletion order: plaintext temps first, vault, then the outbox (key first).
    static let order: [LocalCopyKind] = [.plaintextTemp, .cameraOriginalTemp, .uploadChunkTemp, .vaultEntry, .outboxEncrypted]

    public init(handlers: [LocalCopyHandler]) {
        var m: [LocalCopyKind: LocalCopyHandler] = [:]
        for h in handlers { m[h.kind] = h }
        self.handlers = m
    }

    public func deleteLocalCopies(of record: CaptureRecord, authorizedBy proof: VerifiedReceipt) -> DeletionReport {
        var report = DeletionReport(deleted: [], failed: [:])
        guard proof.receipt.captureId == record.captureId else {
            for c in record.localCopies { report.failed[c.kind] = "reçu non lié à cette captation" }
            return report
        }
        let copies = record.localCopies.sorted {
            (Self.order.firstIndex(of: $0.kind) ?? 99) < (Self.order.firstIndex(of: $1.kind) ?? 99)
        }
        for copy in copies {
            guard let h = handlers[copy.kind] else {
                report.failed[copy.kind] = "aucun gestionnaire de suppression"
                continue
            }
            do {
                if h.exists(copy) { try h.delete(copy) }
                if h.exists(copy) {
                    report.failed[copy.kind] = "copie toujours présente après suppression"
                } else {
                    report.deleted.append(copy.kind)
                }
            } catch {
                report.failed[copy.kind] = "échec de suppression"
            }
        }
        return report
    }
}

/// Handler for the SPECTRE encrypted outbox (key destroyed first).
public struct OutboxCopyHandler: LocalCopyHandler {
    public let kind = LocalCopyKind.outboxEncrypted
    let outbox: EncryptedOutbox
    public init(outbox: EncryptedOutbox) { self.outbox = outbox }
    public func delete(_ ref: LocalCopyRef) throws { try outbox.destroy(ref.reference) }
    public func exists(_ ref: LocalCopyRef) -> Bool { outbox.exists(ref.reference) || outbox.hasKey(ref.reference) }
}

/// Handler for plain files (temp copies). Overwrites then removes; the overwrite
/// is best-effort only (flash wear-levelling, APFS copy-on-write).
public struct FileCopyHandler: LocalCopyHandler {
    public let kind: LocalCopyKind
    let allowedRoot: URL
    public init(kind: LocalCopyKind, allowedRoot: URL) { self.kind = kind; self.allowedRoot = allowedRoot.standardizedFileURL }

    func url(_ ref: LocalCopyRef) -> URL? {
        let u = URL(fileURLWithPath: ref.reference).standardizedFileURL
        return u.path.hasPrefix(allowedRoot.path + "/") ? u : nil
    }
    public func delete(_ ref: LocalCopyRef) throws {
        guard let u = url(ref) else { throw SpectreError.protocolViolation("path outside managed root") }
        if let h = try? FileHandle(forWritingTo: u) {
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue ?? 0
            var remaining = size
            let zero = Data(repeating: 0, count: 64 * 1024)
            while remaining > 0 { let n = min(remaining, zero.count); try? h.write(contentsOf: zero.prefix(n)); remaining -= n }
            try? h.synchronize(); try? h.close()
        }
        try FileManager.default.removeItem(at: u)
    }
    public func exists(_ ref: LocalCopyRef) -> Bool {
        guard let u = url(ref) else { return true } // unknown location: never claim it is gone
        return FileManager.default.fileExists(atPath: u.path)
    }
}
