//
//  SPECTRE Capture — on-disk locations for the deposit queue and outbox.
//  Application Support/Spectre, excluded from iCloud/iTunes backups.
//  Protection: completeUntilFirstUserAuthentication, so that a background
//  transfer can read the (already AES-GCM encrypted) outbox while locked.
//

import Foundation

enum SpectreStorage {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Spectre", isDirectory: true)
    }
    static var queueDirectory: URL { root.appendingPathComponent("queue", isDirectory: true) }
    static var outboxDirectory: URL { root.appendingPathComponent("outbox", isDirectory: true) }

    static func prepareDirectories() {
        for dir in [root, queueDirectory, outboxDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            protect(dir)
        }
    }

    /// Applied to every directory and file SPECTRE writes.
    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// Wipes every SPECTRE file (used when Tella deletes everything after failed unlocks).
    static func wipeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}
