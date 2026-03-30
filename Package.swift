// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceStreamInput",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceStreamInput", targets: ["VoiceStreamInput"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceStreamInput",
            path: "Sources/VoiceStreamInput"
        )
    ]
)
