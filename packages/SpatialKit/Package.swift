// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpatialKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "SpatialCore", targets: ["SpatialCore"]),
        .library(name: "SpatialApple", targets: ["SpatialApple"]),
    ],
    targets: [
        .target(name: "SpatialCore"),
        .target(name: "SpatialApple", dependencies: ["SpatialCore"], exclude: ["REFERENCES.md"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SpatialCoreTests", dependencies: ["SpatialCore"]),
        .testTarget(name: "SpatialAppleTests", dependencies: ["SpatialApple", "SpatialCore"], resources: [.copy("Resources")]),
        .testTarget(name: "PointingTests", dependencies: ["SpatialApple", "SpatialCore"]),
        .testTarget(name: "StorageTests", dependencies: ["SpatialApple", "SpatialCore"]),
    ],
    swiftLanguageModes: [.v6]
)
