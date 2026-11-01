// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Direct (Developer ID) builds ship Sparkle for updates; Mac App Store builds must not. `task bundle` sets EDMUNDZ_DIRECT.
let direct = ProcessInfo.processInfo.environment["EDMUNDZ_DIRECT"] != nil

let package = Package(
    name: "Edmundz",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Edmundz", targets: ["Edmundz"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark", branch: "gfm"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
    ] + (direct ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")] : []),
    targets: [
        // Pure logic: parsing, reveal model, format commands. Foundation only, fully unit-tested.
        .target(
            name: "EdmundzCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // AppKit: document, editor, live rendering, media, settings.
        .target(
            name: "EdmundzKit",
            dependencies: ["EdmundzCore", .product(name: "SwiftMath", package: "SwiftMath")]
                + (direct ? [.product(name: "Sparkle", package: "Sparkle")] : []),
            swiftSettings: [.swiftLanguageMode(.v5)] + (direct ? [.define("DIRECT")] : [])
        ),
        .executableTarget(
            name: "Edmundz",
            dependencies: ["EdmundzKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Quick Look preview extension (embedded as an .appex by scripts/bundle.sh). Its entry point is NSExtensionMain.
        .executableTarget(
            name: "EdmundzQuickLook",
            dependencies: ["EdmundzCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"])]
        ),
        // Headless performance gates (task bench).
        .executableTarget(
            name: "EdmundzBench",
            dependencies: ["EdmundzKit", "EdmundzCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdmundzCoreTests",
            dependencies: ["EdmundzCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
