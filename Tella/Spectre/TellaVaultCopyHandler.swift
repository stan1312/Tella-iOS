//
//  SPECTRE Capture — deletion of the Tella vault entry for a confirmed capture.
//  Uses Tella's own API (VaultFilesManager.deleteVaultFile) so the encrypted
//  container AND the DB row (which holds the thumbnail) are removed, then
//  checks both are really gone. Requires the vault to be unlocked; otherwise
//  the copy is reported as remaining and retried at the next unlock.
//

import Foundation
#if canImport(SpectreCore)
import SpectreCore
#endif

final class TellaVaultCopyHandler: LocalCopyHandler, @unchecked Sendable {
    let kind = LocalCopyKind.vaultEntry
    weak var mainAppModel: MainAppModel?

    init(mainAppModel: MainAppModel) { self.mainAppModel = mainAppModel }

    enum Failure: Error { case vaultLocked, deleteFailed }

    func delete(_ ref: LocalCopyRef) throws {
        guard let app = mainAppModel, let files = app.vaultFilesManager, app.vaultManager.isUnlocked else {
            throw Failure.vaultLocked
        }
        let result = files.deleteVaultFile(fileIds: [ref.reference])
        if case .failure? = result { throw Failure.deleteFailed }
    }

    func exists(_ ref: LocalCopyRef) -> Bool {
        guard let app = mainAppModel, let files = app.vaultFilesManager, app.vaultManager.isUnlocked else {
            return true // cannot prove absence while locked: never claim it is gone
        }
        let rowExists = files.getVaultFile(id: ref.reference) != nil
        let containerExists = (app.vaultManager as? VaultManager)?.vaultContainerExists(fileId: ref.reference) ?? true
        return rowExists || containerExists
    }
}
