// swift-tools-version:6.2
import PackageDescription

// No third-party dependencies: keeps the binary small and the memory footprint low.
let package = Package(
    name: "shadow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Shadow", targets: ["Shadow"]),
        .executable(name: "shadow-mcp", targets: ["shadow-mcp"]),
        .library(name: "ShadowKit", targets: ["ShadowKit"]),
    ],
    targets: [
        // UI-free core: everything that touches the system, parses output or decides something. Unit tested.
        .target(name: "ShadowKit"),
        // The menu bar + Dock app.
        .executableTarget(name: "Shadow", dependencies: ["ShadowKit"]),
        // Model Context Protocol server (stdio) so agents can drive the app's capabilities.
        .executableTarget(name: "shadow-mcp", dependencies: ["ShadowKit"]),
        .testTarget(name: "ShadowKitTests", dependencies: ["ShadowKit"]),
    ],
    swiftLanguageModes: [.v6]
)
