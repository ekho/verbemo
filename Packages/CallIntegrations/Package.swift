// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "CallIntegrations", platforms: [.macOS("14.2")], products: [
    .library(name: "CallIntegrations", targets: ["CallIntegrations"]),
    .library(name: "KTalkIntegration", targets: ["KTalkIntegration"]),
    .executable(name: "call-integration-probe", targets: ["CallIntegrationProbe"]),
], targets: [
    .target(name: "CallIntegrations"),
    .target(name: "KTalkIntegration", dependencies: ["CallIntegrations"], resources: [.process("Resources")]),
    .executableTarget(name: "CallIntegrationProbe", dependencies: ["CallIntegrations", "KTalkIntegration"]),
    .testTarget(name: "CallIntegrationTests", dependencies: ["CallIntegrations", "KTalkIntegration"]),
])
