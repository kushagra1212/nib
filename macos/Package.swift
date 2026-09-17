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
        // The shared C++ core, which Windows uses too.
        //
        // Built by CMake rather than SwiftPM -- it has to produce a Windows DLL
        // from a Linux container as well as a dylib here, and SwiftPM does
        // neither. Run before any swift build:
        //
        //   cmake -S core -B core/build -G Ninja \
        //         -DICU_ROOT="$(brew --prefix icu4c)"
        //   cmake --build core/build
        .systemLibrary(
            name: "CNibCore",
            path: "Sources/CNibCore"
        ),
        .executableTarget(
            name: "nib",
            dependencies: ["whisper", "CKokoro", "CNibCore"],
            path: "Sources/nib",
            linkerSettings: [
                // Relative to the package directory, which is macos/.
                // -Xlinker rather than -Wl: swiftc passes these through to ld
                // itself and rejects the comma-joined form.
                //
                // Two rpaths. The first is where bundle.sh puts the dylib
                // inside nib.app; the second is core/build, so a plain
                // `swift run` from a checkout finds it without bundling.
                .unsafeFlags([
                    "-L../core/build",
                    "-lnibcore",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../core/build",
                ])
            ]
        ),
        .testTarget(
            name: "nibTests",
            dependencies: ["nib"],
            path: "Tests/nibTests"
        ),
    ]
)
