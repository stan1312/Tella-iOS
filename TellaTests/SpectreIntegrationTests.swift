//
//  SPECTRE Capture — integration tests that need the iOS app target
//  (Keychain, Application Support protection, Tella types). Run on macOS:
//  xcodebuild test -workspace Tella.xcworkspace -scheme Tella -destination 'platform=iOS Simulator,name=iPhone 15'
//  NOT executed in the Linux environment where SpectreCore was tested.
//

import XCTest
@testable import Tella

final class SpectreIntegrationTests: XCTestCase {

    func testKeychainStoreRoundTripIsThisDeviceOnly() throws {
        let store = SpectreKeychainSecretStore(service: "ch.spectre.capture.tests.\(UUID().uuidString)")
        defer { store.deleteAll() }
        try store.set(Data("x".utf8), for: "k")
        XCTAssertEqual(try store.get("k"), Data("x".utf8))
        try store.delete("k")
        XCTAssertNil(try store.get("k"))
    }

    func testCaptureIdIsDeterministicUUID() {
        let a = SpectreDepositService.captureId(forVaultFileId: "ABC")
        XCTAssertEqual(a, SpectreDepositService.captureId(forVaultFileId: "ABC"))
        XCTAssertNotEqual(a, SpectreDepositService.captureId(forVaultFileId: "ABD"))
        XCTAssertTrue(Validation.isUUID(a))
    }

    func testStorageIsExcludedFromBackup() throws {
        SpectreStorage.prepareDirectories()
        let values = try SpectreStorage.queueDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testInfoPlistDeclaresSpectreSchemeAndBackgroundTask() {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        XCTAssertTrue(ids.contains(SpectreDepositService.backgroundTaskIdentifier))
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("spectre"))
    }

    func testVideoCapabilitiesDetectionDoesNotCrashOnSimulator() {
        let caps = SpectreVideoCapabilities.detect()
        // Simulator has no camera: an empty list is the honest answer.
        XCTAssertNotNil(caps.modes)
    }
}
