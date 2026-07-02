// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelBuilder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../FilaCore"),
    ],
    targets: [
        .executableTarget(
            name: "ModelBuilder",
            dependencies: [.product(name: "FilaCore", package: "FilaCore")]
        ),
    ]
)
