// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Easel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Easel",
            path: "Sources/Easel"
        )
    ]
)
