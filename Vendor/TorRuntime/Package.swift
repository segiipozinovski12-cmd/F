// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmbeddedTor",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "EmbeddedTor", targets: ["EmbeddedTor"])
    ],
    targets: [
        // scripts/prepare_tor.py materializes and fixes this local XCFramework before Xcode opens.
        .binaryTarget(name: "tor", path: "tor.xcframework"),
        .target(
            name: "EmbeddedTor",
            dependencies: ["tor"],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("resolv"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
