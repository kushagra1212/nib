// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nib",
    platforms: [.macOS(.v13)],
    targets: [
        // The speech engine, linked rather than run as a subprocess.
        //
        // Fetched by Scripts/fetch-whisper.sh, which trims the published
        // XCFramework to its macOS slice. The path has to exist before any
        // build resolves, so that script now runs before swift build -- see
        // the README and both workflows.
        .binaryTarget(
            name: "whisper",
            path: "vendor/whisper/whisper.xcframework"
        ),
        .executableTarget(
            name: "nib",
            dependencies: ["whisper"],
            path: "Sources/nib"
        ),
        .testTarget(
            name: "nibTests",
            dependencies: ["nib"],
            path: "Tests/nibTests"
        ),
    ]
)
