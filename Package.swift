// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Meowse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meowse", targets: ["Meowse"]),
        .executable(name: "MeowseSettings", targets: ["MeowseSettings"]),
        .executable(name: "MeowseLid", targets: ["MeowseLid"]),
    ],
    targets: [
        .target(name: "MeowseCore"),
        .executableTarget(
            name: "Meowse",
            dependencies: ["MeowseCore"]
        ),
        // The Settings window, a separate process that exits when it closes.
        .executableTarget(
            name: "MeowseSettings",
            dependencies: ["MeowseCore"],
            // Not on any hot path, so it's built for size: a smaller download.
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        // The lid helper, a root daemon that stops lid-close sleep while Meowse
        // holds it. It runs only while needed.
        .executableTarget(
            name: "MeowseLid",
            dependencies: ["MeowseCore"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .testTarget(
            name: "MeowseCoreTests",
            dependencies: ["MeowseCore"]
        ),
    ]
)
