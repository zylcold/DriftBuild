// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DriftBuild",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "drift", targets: ["DriftCLI"]),
        .executable(name: "drift-server", targets: ["DriftServer"]),
        .library(name: "DriftCore", targets: ["DriftCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.100.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "DriftCore"
        ),
        .executableTarget(
            name: "DriftCLI",
            dependencies: [
                "DriftCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "DriftServer",
            dependencies: [
                "DriftCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .testTarget(
            name: "DriftBuildTests",
            dependencies: ["DriftCore"]
        )
    ]
)
