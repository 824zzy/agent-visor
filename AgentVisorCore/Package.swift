// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentVisorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentVisorCore", targets: ["AgentVisorCore"]),
    ],
    targets: [
        .target(name: "AgentVisorCore"),
        .testTarget(name: "AgentVisorCoreTests", dependencies: ["AgentVisorCore"]),
    ]
)
