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
        // Kokoro inference, kept in C.
        //
        // ONNX Runtime's C API is a struct of several hundred function
        // pointers. Restating that in Swift would make one member out of order
        // undefined behaviour rather than a compile error, so the headers stay
        // here and Swift sees four functions.
        //
        // The runtime itself is opened with dlopen, not linked, so this builds
        // wherever Scripts/fetch-onnx.sh has not been run.
        .target(
            name: "CKokoro",
            path: "Sources/CKokoro",
            exclude: ["onnxruntime/LICENSE"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "nib",
            dependencies: ["whisper", "CKokoro"],
            path: "Sources/nib"
        ),
        .testTarget(
            name: "nibTests",
            dependencies: ["nib"],
            path: "Tests/nibTests"
        ),
    ]
)
