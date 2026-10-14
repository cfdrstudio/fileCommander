// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FileCommander",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Terminal emulator for the built-in terminal panel. Pinned to an exact release.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        .executableTarget(
            name: "FileCommander",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/FileCommander"),
        .testTarget(name: "FileCommanderTests", dependencies: ["FileCommander"], path: "Tests/FileCommanderTests"),
    ]
)
