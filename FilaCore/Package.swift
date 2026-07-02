// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FilaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FilaCore", targets: ["FilaCore"]),
    ],
    targets: [
        .target(
            name: "FilaCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "FilaCoreTests",
            dependencies: ["FilaCore"]
        ),
    ]
)
