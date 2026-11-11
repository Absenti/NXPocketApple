// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NXPocketKit",
    platforms: [.iOS(.v26), .macOS(.v13)],
    products: [
        .library(name: "NXPocketKit", targets: ["NXPocketKit"])
    ],
    targets: [
        .target(name: "NXPocketKit", path: "Sources/NXPocketKit"),
        .testTarget(name: "NXPocketKitTests", dependencies: ["NXPocketKit"], path: "Tests/NXPocketKitTests")
    ],
    swiftLanguageModes: [.v5]
)
