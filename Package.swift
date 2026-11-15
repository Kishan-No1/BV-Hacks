// swift-tools-version: 6.2
// READ-ONLY for builders after the scaffold commit. Report problems in open_issues.
import PackageDescription

let package = Package(
    name: "Nod",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NodCore", targets: ["NodCore"]),
        .executable(name: "Nod", targets: ["Nod"]),
    ],
    targets: [
        // Models, RiskEngine, RulesStore, StepFormatter, SessionStore, HookServer. No UI.
        .target(
            name: "NodCore",
            path: "Sources/NodCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu-bar app (LSUIElement). SwiftUI + AppKit + Carbon hotkeys.
        .executableTarget(
            name: "Nod",
            dependencies: ["NodCore"],
            path: "Sources/Nod",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AppKit")]
        ),
        // Workstream A (core-logic) tests + shared contract tests. Fixtures live here.
        .testTarget(
            name: "NodCoreTests",
            dependencies: ["NodCore"],
            path: "Tests/NodCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Workstream B (bridge) tests: HookServer, SessionStore, hook + install scripts.
        .testTarget(
            name: "NodBridgeTests",
            dependencies: ["NodCore"],
            path: "Tests/NodBridgeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Workstream C (app-ui) tests for pure view-model logic in the app target.
        .testTarget(
            name: "NodAppTests",
            dependencies: ["Nod", "NodCore"],
            path: "Tests/NodAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
