// swift-tools-version:6.0
//
// Strongroom for macOS. Builds with the Command Line Tools alone (no Xcode
// project): `scripts/build-core.sh` produces lib/libstrongroom_ffi.a and the
// UniFFI bindings, then `swift build` / `swift test` / `scripts/build-app.sh`.
//
// Only Apple system frameworks are used. No third-party Swift packages.

import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libDir = packageDir + "/lib"

let package = Package(
    name: "StrongroomMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Strongroom", targets: ["StrongroomMac"]),
        .executable(name: "strongroom-mac-cli", targets: ["StrongroomMacCLI"]),
    ],
    targets: [
        // C declarations of the Rust FFI (generated header + hand-written
        // module map that links libstrongroom_ffi.a from lib/).
        .systemLibrary(name: "strongroomFFI", path: "Sources/strongroomFFI"),

        // Generated Swift bindings + the macOS platform layer shared by the app,
        // the CLI and the tests (Secure Enclave key, unlock policy inputs,
        // secure files, clipboard).
        .target(
            name: "StrongroomKit",
            dependencies: ["strongroomFFI"],
            linkerSettings: [
                .unsafeFlags(["-L", libDir]),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("c++"),
            ]
        ),

        .executableTarget(
            name: "StrongroomMac",
            dependencies: ["StrongroomKit"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),

        .executableTarget(
            name: "StrongroomMacCLI",
            dependencies: ["StrongroomKit"]
        ),

        .testTarget(
            name: "StrongroomKitTests",
            dependencies: ["StrongroomKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
