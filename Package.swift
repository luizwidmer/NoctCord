// swift-tools-version: 6.0
import Foundation
import PackageDescription

let noctweaveDependency: Package.Dependency
let noctweavePackageIdentity: String
let webRTCPackageIdentity = "WebRTC"

// Local protocol work can override the immutable public revision without
// changing the checked-in dependency graph.
if let localPath = ProcessInfo.processInfo.environment["NOCTWEAVE_PACKAGE_PATH"],
   !localPath.isEmpty {
    noctweaveDependency = .package(path: localPath)
    noctweavePackageIdentity = URL(fileURLWithPath: localPath).lastPathComponent
} else {
    noctweaveDependency = .package(
        url: "https://github.com/luizwidmer/Noctweave.git",
        revision: "7ffaff6b74d8ede577a130f1d88275a3066d0fd3"
    )
    noctweavePackageIdentity = "Noctweave"
}

let package = Package(
    name: "NoctCord",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "NoctCordCore", targets: ["NoctCordCore"]),
        .library(name: "NoctCordMedia", targets: ["NoctCordMedia"]),
        .library(name: "NoctCordUI", targets: ["NoctCordUI"]),
        .executable(name: "NoctCordApp", targets: ["NoctCordApp"]),
        .executable(name: "NoctCordDemo", targets: ["NoctCordDemo"]),
    ],
    dependencies: [
        noctweaveDependency,
        .package(
            url: "https://github.com/stasel/WebRTC.git",
            // M152 includes matching distribution symbols. Pin the source and binary checksum.
            revision: "1d04692697cb642bfebf6ad2dd99fe52649c3d6d"
        ),
    ],
    targets: [
        .target(
            name: "NoctCordCore",
            dependencies: [
                .product(
                    name: "NoctweaveCore",
                    package: noctweavePackageIdentity
                )
            ]
        ),
        .target(
            name: "NoctCordMedia",
            dependencies: [
                .product(name: "WebRTC", package: webRTCPackageIdentity)
            ]
        ),
        .executableTarget(
            name: "NoctCordApp",
            dependencies: ["NoctCordUI"]
        ),
        .target(
            name: "NoctCordUI",
            dependencies: [
                "NoctCordCore",
                "NoctCordMedia",
                .product(
                    name: "NoctweaveCore",
                    package: noctweavePackageIdentity
                )
            ]
        ),
        .executableTarget(
            name: "NoctCordDemo",
            dependencies: ["NoctCordCore", .product(
                name: "NoctweaveCore",
                package: noctweavePackageIdentity
            )]
        ),
        .testTarget(
            name: "NoctCordCoreTests",
            dependencies: ["NoctCordCore", .product(
                name: "NoctweaveCore",
                package: noctweavePackageIdentity
            )]
        ),
        .testTarget(
            name: "NoctCordMediaTests",
            dependencies: ["NoctCordMedia"]
        ),
        .testTarget(
            name: "NoctCordUITests",
            dependencies: [
                "NoctCordUI",
                .product(
                    name: "NoctweaveCore",
                    package: noctweavePackageIdentity
                )
            ]
        ),
    ]
)
