// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenPhonic",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "OpenPhonic",
            path: "Sources/OpenPhonic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
