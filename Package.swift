// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EndTranslate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EndTranslate",
            path: "Sources/EndTranslate",
            resources: [.copy("Resources/Renderer")]
        ),
        .testTarget(
            name: "EndTranslateTests",
            dependencies: ["EndTranslate"],
            path: "Tests/EndTranslateTests"
        )
    ]
)
