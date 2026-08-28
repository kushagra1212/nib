// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nib",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "nib",
            path: "Sources/nib"
        ),
        .testTarget(
            name: "nibTests",
            dependencies: ["nib"],
            path: "Tests/nibTests"
        ),
    ]
)
