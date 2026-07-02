// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DecodeBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../FilaCore"),
    ],
    targets: [
        .executableTarget(
            name: "DecodeBench",
            dependencies: [.product(name: "FilaCore", package: "FilaCore")]
        ),
    ]
)
