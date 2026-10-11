// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import PackageDescription

// RustCore links the UniFFI XCFramework built by khensu-core. It is only added
// when the framework exists, so the package still builds (with MockCore only)
// on machines that haven't built khensu-core.
let coreRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../khensu-core/target")
    .standardizedFileURL
let xcframework = coreRoot.appendingPathComponent("KhensuCore.xcframework")
let hasRustCore = FileManager.default.fileExists(atPath: xcframework.path)

var targets: [Target] = [
    .target(
        name: "KhensuKit",
        resources: [.copy("Resources/wordlist-en.txt")],
        swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .testTarget(
        name: "KhensuKitTests",
        dependencies: ["KhensuKit"]
    ),
]

var products: [Product] = [
    .library(name: "KhensuKit", targets: ["KhensuKit"]),
]

if hasRustCore {
    targets += [
        .binaryTarget(name: "KhensuCoreFFI", path: "../../../khensu-core/target/KhensuCore.xcframework"),
        .target(
            name: "KhensuRustCore",
            dependencies: ["KhensuKit", "KhensuCoreFFI"],
            swiftSettings: [.define("KHENSU_RUST_CORE")]
        ),
    ]
    products.append(.library(name: "KhensuRustCore", targets: ["KhensuRustCore"]))
}

let package = Package(
    name: "KhensuKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: products,
    targets: targets
)
