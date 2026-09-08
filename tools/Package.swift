// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AstraTools",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SceneLab", targets: ["SceneLab"]),
        .executable(name: "PointingReplay", targets: ["PointingReplay"]),
    ],
    dependencies: [.package(path: "../framework")],
    targets: [
        .executableTarget(
            name: "SceneLab",
            dependencies: [.product(name: "SpatialCore", package: "framework")]
        ),
        .executableTarget(
            name: "PointingReplay",
            dependencies: [.product(name: "SpatialApple", package: "framework")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
