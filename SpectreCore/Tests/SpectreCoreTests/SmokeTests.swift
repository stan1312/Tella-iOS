import XCTest
@testable import SpectreCore
final class SmokeTests: XCTestCase { func testVersion() { XCTAssertEqual(SpectreCoreVersion.value, "0.1.0") } }
