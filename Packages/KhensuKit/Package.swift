// swift-tools-version: 6.2
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import PackageDescription

// RustCore wraps khensu-core's UniFFI bindings. scripts/link-core.sh puts the
// XCFramework and the generated Swift in place (both gitignored); without
// them the package builds MockCore only.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasRustCore = ["Frameworks/KhensuCore.xcframework", "Sources/KhensuCoreBindings/KhensuCore.swift"]
    .allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }

var kitDependencies: [Target.Dependency] = []
var targets: [Target] = []

if hasRustCore {
    targets += [
        .binaryTarget(name: "KhensuCoreFFI", path: "Frameworks/KhensuCore.xcframework"),
        // Generated code: built in Swift 5 mode, as UniFFI emits it.
        .target(
            name: "KhensuCoreBindings",
            dependencies: ["KhensuCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
    kitDependencies.append("KhensuCoreBindings")
}

targets += [
    .target(
        name: "KhensuKit",
        dependencies: kitDependencies,
        resources: [.copy("Resources/wordlist-en.txt")],
        swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .testTarget(
        name: "KhensuKitTests",
        dependencies: ["KhensuKit"]
    ),
]

let package = Package(
    name: "KhensuKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "KhensuKit", targets: ["KhensuKit"]),
    ],
    targets: targets
)
