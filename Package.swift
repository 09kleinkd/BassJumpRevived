// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BassJumpRevived",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "BassJumpRevived",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BassJumpRevived"
        ),
        .testTarget(
            name: "BassJumpRevivedTests",
            dependencies: ["BassJumpRevived"],
            path: "Tests/BassJumpRevivedTests"
        ),
    ]
)
