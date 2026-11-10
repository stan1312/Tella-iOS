//
//  SPECTRE Capture — Keychain-backed SecretStore.
//  Items are this-device-only and never synchronised to iCloud Keychain.
//  AfterFirstUnlock is required so that queued uploads can continue while the
//  screen is locked (documented trade-off, see docs/SECURITY_THREAT_MODEL.md).
//
//  Fork of Tella iOS — Copyright © HORIZONTAL, MIT. SPECTRE additions MIT.
//

import Foundation
import Security
#if canImport(SpectreCore)
import SpectreCore
#endif

final class SpectreKeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    init(service: String = "ch.spectre.capture.secrets") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    func set(_ data: Data, for key: String) throws {
        var q = baseQuery(key)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func get(_ key: String) throws -> Data? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return out as? Data
    }

    func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Used by "Réinitialiser l'appareil" and Tella's delete-after-failed-unlock flow.
    func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }
}
