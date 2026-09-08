// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SceneLab",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../packages/SpatialKit")],
    targets: [.executableTarget(name: "SceneLab", dependencies: [
        .product(name: "SpatialCore", package: "SpatialKit")
    ])],
    swiftLanguageModes: [.v6]
)
