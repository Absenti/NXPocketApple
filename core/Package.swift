// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NXPocketKit",
    platforms: [.iOS(.v26), .macOS(.v13)],
    products: [
        .library(name: "NXPocketKit", targets: ["NXPocketKit"]),
        // The SFTP source, apart from NXPocketKit: the one place that needs the SSH stack, so the rest of NXPocketKit stays
        // free of it. docs/SHARING.md §9 says why it is a dependency.
        .library(name: "NXPocketSFTP", targets: ["NXPocketSFTP"])
    ],
    dependencies: [
        // MIT. SSH client and SFTP over SwiftNIO SSH (Apache 2.0). Pinned exactly: it is the code that authenticates a server
        // before a game it sends is signed and run.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.9.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.2"..<"0.4.0")
    ],
    targets: [
        .target(name: "NXPocketKit", path: "Sources/NXPocketKit"),
        .target(name: "NXPocketSFTP",
                dependencies: ["NXPocketKit",
                               .product(name: "Citadel", package: "Citadel"),
                               .product(name: "NIOCore", package: "swift-nio"),
                               .product(name: "NIOPosix", package: "swift-nio"),
                               .product(name: "NIOSSH", package: "swift-nio-ssh")],
                path: "Sources/NXPocketSFTP"),
        .testTarget(name: "NXPocketKitTests", dependencies: ["NXPocketKit"], path: "Tests/NXPocketKitTests"),
        .testTarget(name: "NXPocketSFTPTests", dependencies: ["NXPocketSFTP", "NXPocketKit"], path: "Tests/NXPocketSFTPTests")
    ],
    swiftLanguageModes: [.v5]
)
