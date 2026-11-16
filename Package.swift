// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TqLLMControlCenter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TqLLMControlCenter",
            path: "Sources"
        )
    ],
    swiftLanguageVersions: [.v5]
)