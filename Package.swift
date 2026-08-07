// swift-tools-version: 6.0
import Foundation
import PackageDescription

let noctweaveDependency: Package.Dependency
let noctweavePackageIdentity: String

if let localPath = ProcessInfo.processInfo.environment["NOCTWEAVE_PACKAGE_PATH"],
   !localPath.isEmpty {
    noctweaveDependency = .package(path: localPath)
    noctweavePackageIdentity = URL(fileURLWithPath: localPath).lastPathComponent
} else {
    noctweaveDependency = .package(
        url: "https://github.com/luizwidmer/Noctweave.git",
        branch: "main"
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
        .executable(name: "NoctCordDemo", targets: ["NoctCordDemo"]),
    ],
    dependencies: [noctweaveDependency],
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
    ]
)
