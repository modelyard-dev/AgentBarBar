// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBarBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBarBarCore", targets: ["AgentBarBarCore"]),
        .executable(name: "AgentBarBar", targets: ["AgentBarBarApp"]),
        .executable(name: "agentbarbar-cli", targets: ["AgentBarBarCLI"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CZstd", path: "ThirdParty/zstd", exclude: ["README.md", "LICENSE", "COPYING"], sources: ["zstddeclib.c"], publicHeadersPath: "include"),
        .target(name: "AgentBarBarCore", dependencies: ["CSQLite", "CZstd"]),
        .executableTarget(name: "AgentBarBarApp", dependencies: ["AgentBarBarCore"]),
        .executableTarget(name: "AgentBarBarCLI", dependencies: ["AgentBarBarCore"]),
        .testTarget(name: "AgentBarBarCoreTests", dependencies: ["AgentBarBarCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
