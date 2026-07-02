// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmojiMapBuilder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../FilaCore"),
    ],
    targets: [
        .executableTarget(
            name: "EmojiMapBuilder",
            dependencies: [.product(name: "FilaCore", package: "FilaCore")]
        ),
    ]
)
