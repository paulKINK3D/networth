// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworthCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NetworthCore",
            targets: ["NetworthCore"]
        )
    ],
    targets: [
        .target(
            name: "Money",
            path: "Sources/Money"
        ),
        .target(
            name: "Models",
            dependencies: ["Money"],
            path: "Sources/Models"
        ),
        .target(
            name: "Formatting",
            dependencies: ["Money", "Models"],
            path: "Sources/Formatting"
        ),
        .target(
            name: "APIDTOs",
            dependencies: ["Money", "Models"],
            path: "Sources/APIDTOs"
        ),
        .target(
            name: "Projections",
            dependencies: ["Money", "Models"],
            path: "Sources/Projections"
        ),
        .target(
            name: "NetworthCore",
            dependencies: ["Money", "Models", "Formatting", "APIDTOs", "Projections"],
            path: "Sources/NetworthCore"
        ),
        .testTarget(
            name: "NetworthCoreTests",
            dependencies: ["NetworthCore"],
            path: "Tests/NetworthCoreTests"
        )
    ]
)
