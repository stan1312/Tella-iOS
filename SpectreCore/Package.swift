// swift-tools-version:5.9
//
// SpectreCore — platform-agnostic deposit pipeline for SPECTRE Capture
// (queue, encrypted outbox, resumable transport, receipt verification,
// conditional deletion). Compiles on Apple platforms (CryptoKit) and on
// Linux (swift-crypto) so that the logic can be tested without Xcode.
//
import PackageDescription

let package = Package(
    name: "SpectreCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SpectreCore", targets: ["SpectreCore"]),
    ],
    dependencies: [
        // Only linked on Linux; Apple platforms use CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "SpectreCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "SpectreCoreTests",
            dependencies: ["SpectreCore"]
        ),
    ]
)
