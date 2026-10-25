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

        // The app's SwiftUI views, model and AppKit glue. A library (kept in
        // Sources/StrongroomMac) so the debug snapshot harness can render the
        // same views; the app executable below only calls its entry point.
        .target(
            name: "StrongroomMacUI",
            dependencies: ["StrongroomKit"],
            path: "Sources/StrongroomMac",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),

        .executableTarget(
            name: "StrongroomMac",
            dependencies: ["StrongroomMacUI"],
            path: "Sources/StrongroomMacMain"
        ),

        // Debug-only tool: renders the app's screens offscreen to PNG at
        // several window sizes, light and dark, from a throwaway vault. Not
        // part of Strongroom.app (scripts/build-app.sh builds only the app and
        // CLI products). See Sources/StrongroomSnapshots/main.swift.
        .executableTarget(
            name: "StrongroomSnapshots",
            dependencies: ["StrongroomMacUI", "StrongroomKit"]
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
