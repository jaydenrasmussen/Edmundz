// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spike",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark", branch: "gfm"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
    ],
    targets: [
        .executableTarget(name: "Spike", path: "Sources/Spike",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ParseSpike",
                          dependencies: [.product(name: "cmark-gfm", package: "swift-cmark"),
                                         .product(name: "cmark-gfm-extensions", package: "swift-cmark")],
                          path: "Sources/ParseSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MermaidSpike", path: "Sources/MermaidSpike",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MathSpike",
                          dependencies: [.product(name: "SwiftMath", package: "SwiftMath")],
                          path: "Sources/MathSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
