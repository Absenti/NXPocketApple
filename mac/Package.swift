// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NXPocket",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NXPocket", targets: ["NXPocket"])
    ],
    dependencies: [
        .package(path: "../core")
    ],
    targets: [
        .target(name: "NXPMacKit",
                dependencies: [.product(name: "NXPocketKit", package: "core")],
                path: "Sources/NXPMacKit"),
        .target(name: "NXPMacModel",
                dependencies: ["NXPMacKit"],
                path: "Sources/NXPMacModel"),
        .executableTarget(name: "NXPocket",
                          dependencies: ["NXPMacModel", "NXPMacKit"],
                          path: "Sources/NXPMac"),
        .testTarget(name: "NXPMacKitTests",
                    dependencies: ["NXPMacKit", "NXPMacModel"],
                    path: "Tests/NXPMacKitTests")
    ],
    swiftLanguageModes: [.v5]
)
