// swift-tools-version: 6.2
// READ-ONLY for builders after the scaffold commit. Report problems in open_issues.
import PackageDescription

let package = Package(
    name: "notchAgent",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NotchAgentCore", targets: ["NotchAgentCore"]),
        // The product name is the binary name: build/notchAgent.app/Contents/MacOS/notchAgent.
        .executable(name: "notchAgent", targets: ["NotchAgent"]),
    ],
    targets: [
        // Models, RiskEngine, RulesStore, StepFormatter, SessionStore, HookServer. No UI.
        .target(
            name: "NotchAgentCore",
            path: "Sources/NotchAgentCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu-bar app (LSUIElement). SwiftUI + AppKit + Carbon hotkeys.
        .executableTarget(
            name: "NotchAgent",
            dependencies: ["NotchAgentCore"],
            path: "Sources/NotchAgent",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AppKit")]
        ),
        // Workstream A (core-logic) tests + shared contract tests. Fixtures live here.
        .testTarget(
            name: "NotchAgentCoreTests",
            dependencies: ["NotchAgentCore"],
            path: "Tests/NotchAgentCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Workstream B (bridge) tests: HookServer, SessionStore, hook + install scripts.
        .testTarget(
            name: "NotchAgentBridgeTests",
            dependencies: ["NotchAgentCore"],
            path: "Tests/NotchAgentBridgeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Workstream C (app-ui) tests for pure view-model logic in the app target.
        .testTarget(
            name: "NotchAgentAppTests",
            dependencies: ["NotchAgent", "NotchAgentCore"],
            path: "Tests/NotchAgentAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
