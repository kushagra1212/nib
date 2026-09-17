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

### Cross-compilation — PASS

llvm-mingw 20250528 in a Linux container, on Docker for Mac on Apple silicon, produces real PE
binaries for both Windows architectures:

```
/tmp/hello-x64.exe:   PE32+ AMD64 (x64)  (86,528 bytes)
/tmp/hello-arm64.exe: PE32+ ARM64        (84,480 bytes)
```

The machine type is read out of the PE header rather than taken from `file`, and rather than
trusted from the output filename — a toolchain that silently fell back to building for the host
would still write a file where it was asked to.

`file` is not installed in the image; the check uses Python, which is. The image selects its
llvm-mingw asset by `uname -m`, so the same Dockerfile works on Apple silicon locally and on
GitHub's x86_64 Ubuntu runners.

### MSI packaging — FAIL

WiX v5.0.2 installs as a dotnet tool in the Linux container and runs, but refuses to build:

```
wix.exe : warning WIX0000: The WiX Toolset only supports Windows. If you would like to
          help bring WiX to other platforms, join us at https://wixtoolset.org.
          All behavior after this point is undefined.
spike.wxs(9) : error WIX0389: The Directory/@Name attribute's value, 'nib', is not a
               relative path.
```

`nib` is plainly a relative path. Retried with a different name (`nibspike`) and the error is
identical, so this is not the name or the construct — WiX's path validation does not work
off-Windows, exactly as its own warning says.

**Consequence: MSI packaging happens on the `windows-latest` CI runner, not in Docker.** This
costs nothing at release time, because packaging was always going to run in CI. What it costs
is local iteration — the installer cannot be built or inspected from this Mac, so changes to
the `.wxs` are verified by pushing.

Not worth working around. The alternative is Wine, which would put an unsupported toolset on
an unsupported platform and call the result an installer.

### Managed build — PASS

.NET 9 with `EnableWindowsTargeting` publishes a self-contained WPF application from the Linux
container for both architectures:

```
bin/Release/net9.0-windows/win-x64/wpfspike.exe:   PE32+ AMD64 (x64) (156,160 bytes)
bin/Release/net9.0-windows/win-arm64/wpfspike.exe: PE32+ ARM64       (137,216 bytes)
```

The published output carries the full desktop stack — `Accessibility.dll`,
`DirectWriteForwarder.dll`, `coreclr.dll` — so this is a real WPF publish rather than a restore
that happened not to fail.

`python3` is absent from the .NET SDK image, so the PE check runs on the host against the
build output under `bin/`, which the bind mount leaves behind.

**Consequence: the Windows UI iterates locally.** Only the MSI has to wait for CI.

### ICU for Windows — PASS, after three wrong turns

ICU is the core's one hard dependency and there is no Windows package for this toolchain, so
the image builds it: a native Linux build first (its tools are needed and it is never
installed), then a cross build per architecture with `--with-cross-build`.

Three failures worth recording, because each looked like success:

1. **`--enable-static` does not link.** ICU builds its own Windows-side tools and links them
   against short names the static build never produces:
   `lld: error: unable to find library -licuin`, failing `makeconv.exe`.
2. **`--disable-tools` gets past that and silently destroys the data.** `pkgdata` is one of the
   tools, and it is what assembles ICU's data. The build substitutes stub data without saying
   so: `libsicudt.a` came out at **800 bytes** containing one object, `stubdata.ao`. The DLL
   linked, looked right at 1.6MB, and would have reached a Windows machine before anyone
   discovered it had no break-iterator rules in it. A build that fails is better than this.
3. **`make install` stops before copying anything.** ICU puts the data library in
   `$prefix/bin` for Windows targets and does not create the directory.

Shared linkage is what works, and the data is then real: `icudt78.dll` is 33MB rather than
800 bytes.

```
libnibcore.dll  PE32+ AMD64 (x64)  461,312 bytes
libnibcore.dll  PE32+ ARM64        455,680 bytes
imports (both): KERNEL32.dll, api-ms-win-crt-*.dll, icuuc78.dll
```

llvm-mingw's C++ runtime is linked statically, so the imports are only Windows' own UCRT and
ICU — no `libc++.dll` or `libunwind.dll` for the installer to carry.

**The MSI ships three files for the core:** `libnibcore.dll`, `icuuc78.dll`, and `icudt78.dll`
(33MB, loaded by icuuc at runtime).

### Still open: ICU for macOS

The same problem, unsolved on the other side. Homebrew's `icu4c@78` is built for **macOS 15.0**
and nib supports **Ventura 13**, so the bundled app works on a modern Mac and would fail on the
oldest one the README promises. `bundle.sh` copies the three dylibs and rewrites their paths,
which is correct mechanically and does not fix the deployment target.

The fix is to build ICU for macOS the way this image builds it for Windows, with
`CMAKE_OSX_DEPLOYMENT_TARGET=13.0`. One recipe would then serve all three targets.

## Verdicts

| Spike | Result | Consequence |
|---|---|---|
| C++ cross-compile, both arches | PASS | core builds and iterates locally |
| WiX MSI on Linux | FAIL | installer is built on `windows-latest` only |
| WPF publish on Linux, both arches | PASS | Windows UI iterates locally |
