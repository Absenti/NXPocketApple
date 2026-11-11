// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The signing engine is a build product, never committed: tools/build_zsign.sh produces it, and a checkout without
// it still builds. Linking it is what turns DeviceSigner on -- `#if canImport(NXZSign)` -- so the app imports and
// verifies games and refuses to sign one until it is there.
//
// It is a binaryTarget rather than a framework the Xcode project links, because the code that imports it lives in
// this package: an Xcode dependency would only reach the app target, and canImport would be false in the target
// that needs it. False is silent, so that mistake surfaces on the device as "no signing engine" and nowhere else.
//
// The existence check has to be anchored to this file. A relative path would be resolved against whatever directory
// the manifest is evaluated from, which is not the package, and the answer would be "absent" for a tree that has it.
let engineRelativePath = "Signing/libnxzsign.xcframework"
let manifestDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasSigningEngine = FileManager.default.fileExists(
    atPath: manifestDirectory.appendingPathComponent(engineRelativePath).path)

var targets: [Target] = [
    .target(name: "NXShellUI",
            dependencies: [.product(name: "NXPocketKit", package: "core")],
            path: "Sources/NXShellUI")
]

var hostDependencies: [Target.Dependency] = ["NXShellUI", .product(name: "NXPocketKit", package: "core")]
if hasSigningEngine {
    targets.append(.binaryTarget(name: "NXZSign", path: engineRelativePath))
    hostDependencies.append("NXZSign")
}

targets += [
    .target(name: "NXShellHost", dependencies: hostDependencies, path: "Sources/NXShellHost"),
    .testTarget(name: "NXShellHostTests", dependencies: ["NXShellHost"], path: "Tests/NXShellHostTests"),
    .testTarget(name: "NXShellUITests", dependencies: ["NXShellUI"], path: "Tests/NXShellUITests")
]

let package = Package(
    name: "NXShell",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "NXShellUI", targets: ["NXShellUI"]),
        .library(name: "NXShellHost", targets: ["NXShellHost"])
    ],
    dependencies: [
        .package(path: "../core")
    ],
    targets: targets,
    swiftLanguageModes: [.v5]
)
