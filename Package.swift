// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "authreach",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .target(name: "AuthReachCore", path: "Sources/AuthReachCore"),
        .executableTarget(
            name: "AuthReach",
            dependencies: [
                "AuthReachCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/AuthReach"
        ),
        .testTarget(name: "AuthReachCoreTests", dependencies: ["AuthReachCore"], path: "Tests/AuthReachCoreTests"),
    ]
)
