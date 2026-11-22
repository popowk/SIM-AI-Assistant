// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SIM-AI-Assistant",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SIMAICore", targets: ["SIMAICore"]),
        .executable(name: "SIMAIAssistant", targets: ["SIMAIAssistant"])
    ],
    targets: [
        .target(name: "SIMAICore"),
        .executableTarget(name: "SIMAIAssistant", dependencies: ["SIMAICore"]),
        .testTarget(name: "SIMAICoreTests", dependencies: ["SIMAICore"])
    ]
)
