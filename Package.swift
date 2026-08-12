// swift-tools-version: 6.0
import Foundation
import PackageDescription

let noctweaveDependency: Package.Dependency
let noctweavePackageIdentity: String
let webRTCPackageIdentity = "WebRTC"

if let localPath = ProcessInfo.processInfo.environment["NOCTWEAVE_PACKAGE_PATH"],
   !localPath.isEmpty {
    noctweaveDependency = .package(path: localPath)
    noctweavePackageIdentity = URL(fileURLWithPath: localPath).lastPathComponent
} else {
    noctweaveDependency = .package(
        url: "https://github.com/luizwidmer/Noctweave.git",
        revision: "41a874fc68dc87898f7406b23d290b308364442b"
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
            exact: "150.0.0"
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
