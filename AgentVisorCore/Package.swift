// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentVisorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentVisorCore", targets: ["AgentVisorCore"]),
        .executable(name: "AgentVisorNativeHelper", targets: ["AgentVisorNativeHelper"]),
    ],
    targets: [
        .target(name: "AgentVisorCore"),
        .executableTarget(name: "AgentVisorNativeHelper", dependencies: ["AgentVisorCore"]),
        .testTarget(name: "AgentVisorCoreTests", dependencies: ["AgentVisorCore"]),
        .testTarget(name: "AgentVisorNativeHelperTests", dependencies: ["AgentVisorNativeHelper"]),
    ]
)
