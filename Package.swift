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
        revision: "7f873747447ba7c7b11d57cb9ccde63e47f20fa9"
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
            // M156 includes matching distribution symbols. Pin the source and binary checksum.
            revision: "3cc466ea040e5dcd1344697bf211dc4c079d1a0c"
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
            ],
            swiftSettings: [.define("NOCTCORD_VERIFIED_CORE")]
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
            ],
            swiftSettings: [.define("NOCTCORD_VERIFIED_CORE")]
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
            )],
            swiftSettings: [.define("NOCTCORD_VERIFIED_CORE")]
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
            ],
            swiftSettings: [.define("NOCTCORD_VERIFIED_CORE")]
        ),
    ]
)
