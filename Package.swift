// swift-tools-version:5.9
import PackageDescription

// Cardinal's search engine is Rust (Vendor/cardinal, MIT). ./build-cardinal.sh builds it into
// CardinalBridge/target/release/libcardinal_bridge.a, which the CCardinal module links.
let cardinalLibDir = Context.packageDirectory + "/CardinalBridge/target/release"

let package = Package(
    name: "FileCommander",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Terminal emulator for the built-in terminal panel. Pinned to an exact release.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        .systemLibrary(name: "CCardinal", path: "Sources/CCardinal"),
        .executableTarget(
            name: "FileCommander",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), "CCardinal"],
            path: "Sources/FileCommander",
            linkerSettings: [.unsafeFlags(["-L", cardinalLibDir])]),
        .testTarget(name: "FileCommanderTests", dependencies: ["FileCommander"], path: "Tests/FileCommanderTests"),
    ]
)
