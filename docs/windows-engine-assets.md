# Windows engine assets

Audited 2026-09-17 for the Windows port. Phase 0, Task 1 of
`superpowers/plans/2026-09-17-phase-0-toolchain-and-restructure.md`.

The question this answers: for each of the five engines nib vendors, does an official Windows
x64 and ARM64 build exist, or must it be built from source? Answer: **all five exist for both
architectures.** Nothing here blocks feature parity.

| Engine | Version pinned | macOS asset today | win-x64 | win-arm64 | Verdict |
|---|---|---|---|---|---|
| harper-ls | 2.8.0 | `harper-ls-aarch64-apple-darwin.tar.gz` | `harper-ls-x86_64-pc-windows-msvc.zip` | not published standalone — ships inside `harper-win32-arm64-2.8.0.vsix` | available, arm64 needs extraction |
| llama.cpp | b10400 | `llama-b10400-bin-macos-arm64.tar.gz` | `llama-b<build>-bin-win-cpu-x64.zip` | `llama-b<build>-bin-win-cpu-arm64.zip` | available, must be mirrored |
| whisper.cpp | b5130 | `whisper-b<build>-xcframework.zip` | `whisper-bin-x64.zip` | `whisper-bin-win-cpu-arm64.zip` | available |
| ONNX Runtime | 1.29.0 | `onnxruntime-osx-arm64-1.29.0.tgz` | `onnxruntime-win-x64-1.29.0.zip` | `onnxruntime-win-arm64-1.29.0.zip` | available |
| espeak-ng | 0.2.4 (loader wheel) | `espeakng_loader-0.2.4-py3-none-macosx_11_0_arm64.whl` | `espeakng_loader-0.2.4-py3-none-win_amd64.whl` | `espeakng_loader-0.2.4-py3-none-win_arm64.whl` | available |

## Three things that need handling

**harper-ls has no standalone ARM64 Windows binary.** v2.8.0 publishes
`harper-ls-x86_64-pc-windows-msvc.zip` and nothing for `aarch64-pc-windows-msvc`. The ARM64
binary does exist — bundled inside the VS Code extension `harper-win32-arm64-2.8.0.vsix`, which
is an ordinary zip. `Scripts/fetch-espeak.sh` already pulls a library out of a Python wheel by
the same method, so the pattern is established rather than novel.

**llama.cpp prunes release assets within days.** Confirmed while auditing: build `b11019`
retains one Ubuntu CUDA tarball and nothing else, while `b11018` — one build older — still
carries the full set of thirteen Windows zips. `Scripts/fetch-llama.sh` already mirrors the
macOS tarball to nib's own `llama-runtime-b10400` release for exactly this reason. The two
Windows zips must be mirrored the same way, in the same release, or a fetch will 404 within the
week.

**whisper.cpp is linked, not run.** On macOS it is an XCFramework declared as a SwiftPM
`binaryTarget`. Windows has no such concept: the core links `whisper.dll` from
`whisper-bin-x64.zip` / `whisper-bin-win-cpu-arm64.zip` directly. This is the one engine whose
integration differs in kind between the platforms rather than in detail.

## Acceleration available, not yet decided

Recorded for Phase 4, not acted on now. macOS gets Metal through the XCFramework. Windows
equivalents that exist today:

- x64: `llama-b<build>-bin-win-vulkan-x64.zip` — broadest GPU coverage, no vendor lock
- ARM64: `llama-b<build>-bin-win-opencl-adreno-arm64.zip` — Snapdragon X only
- both: CUDA builds, NVIDIA only, and a separate `cudart-*` redistributable

The CPU builds are what Phase 0 through 3 assume. Shipping CPU-only first matches how nib
already treats speech on macOS — two threads, deliberately leaving the machine alone.

## Method

```sh
gh release view --repo Automattic/harper v2.8.0 --json assets --jq '.assets[].name'
gh release view --repo ggml-org/llama.cpp b11018 --json assets --jq '.assets[].name'
gh release view --repo ggml-org/whisper.cpp b5130 --json assets --jq '.assets[].name'
gh release view --repo microsoft/onnxruntime v1.29.0 --json assets --jq '.assets[].name'
curl -s https://pypi.org/pypi/espeakng-loader/json \
  | python3 -c "import json,sys; print('\n'.join(f['filename'] for f in json.load(sys.stdin)['urls']))"
```

Re-run before pinning versions in the fetch scripts. Upstream asset names drift, and
llama.cpp's disappear.

## Toolchain

Filled in by Task 2 (cross-compilation), Task 3 (MSI packaging) and Task 4 (managed build).
Each records its verdict here, pass or fail.
