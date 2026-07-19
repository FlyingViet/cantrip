// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cantrip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cantrip",
            path: "Sources/Cantrip"
        )
    ]
)
