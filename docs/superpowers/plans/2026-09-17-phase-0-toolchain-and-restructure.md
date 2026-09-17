# Phase 0: toolchain and restructure — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** prove the three unverified build assumptions, restructure the repo for three
targets, and migrate one module end-to-end through a C ABI so Phase 1 is mechanical repetition.

**Architecture:** a C++20 static/shared core (`nibcore`) exposing a flat `extern "C"` ABI over
UTF-16 strings. macOS SwiftUI links it; Windows C# WPF P/Invokes it. Vendored ICU so sentence
and word segmentation is byte-identical on both platforms. Behaviour is locked by goldens
captured from the currently-shipped Swift *before* any code moves.

**Tech Stack:** C++20, CMake 3.29, Catch2 v3, ICU 76, llvm-mingw (win-x64 + win-arm64),
Swift 6.2 (macOS), .NET 9 + WPF (Windows), WiX v5, Docker, GitHub Actions.

**Prerequisite:** Docker Desktop must be running. `docker info` currently fails — start it
before Task 2.

---

## File structure

Created in this phase:

| Path | Responsibility |
|---|---|
| `core/CMakeLists.txt` | core build: library, ICU, tests, both toolchains |
| `core/include/nib/nib_core.h` | the entire `extern "C"` ABI. One file, versioned |
| `core/include/nib/version.h` | `NIB_CORE_ABI_VERSION`, bumped on every ABI change |
| `core/src/text/utf16.hpp` | `u16view` — non-owning UTF-16 span, the core's string type |
| `core/src/text/word_tokenize.cpp` | `WordDiff.tokenize` port |
| `core/src/text/sentence_split.cpp` | `SentenceSplitter.sentences` port, ICU `BreakIterator` |
| `core/src/abi/abi_text.cpp` | ABI wrappers + result-buffer ownership for the above |
| `core/tests/test_word_tokenize.cpp` | Catch2, drives the goldens |
| `core/tests/test_sentence_split.cpp` | Catch2, drives the goldens |
| `core/tests/golden_loader.hpp` | reads `goldens/*.json` into test cases |
| `goldens/word-tokenize.json` | captured from shipped Swift, never hand-edited |
| `goldens/sentence-split.json` | captured from shipped Swift, never hand-edited |
| `macos/` | everything currently at repo root that is macOS-only |
| `macos/Sources/nib/Core/CoreBridge.swift` | Swift wrapper over the C ABI |
| `windows/` | .NET 9 solution (skeleton only this phase) |
| `docker/core-cross.Dockerfile` | llvm-mingw image, cross-compiles core for both arches |
| `docker/dotnet-win.Dockerfile` | .NET 9 SDK image, publishes WPF for both arches |
| `Scripts/capture-goldens.swift` | dumps goldens from the live Swift implementation |
| `Scripts/spike/` | throwaway proofs from Tasks 2–4, deleted at phase end |
| `.github/workflows/ci.yml` | rewritten: 3-runner matrix |

Moved, not rewritten: `Sources/` → `macos/Sources/`, `Tests/` → `macos/Tests/`,
`Package.swift` → `macos/Package.swift`, `Resources/`, `Casks/`, `vendor/` → `macos/vendor/`.

---

## Task 1: Audit Windows engine assets

No code. This is evidence gathering, and it gates Phase 4 scope. Do it first because a missing
ARM64 asset changes what we promise in the README.

**Files:**
- Create: `docs/windows-engine-assets.md`

- [ ] **Step 1: Check each upstream project for Windows x64 and ARM64 release assets**

For each of the five, record the exact asset filename or "must build from source":

```bash
gh release view --repo Automattic/harper v2.8.0 --json assets \
  --jq '.assets[].name' | grep -i windows
gh release list --repo ggml-org/llama.cpp --limit 1 --json tagName --jq '.[0].tagName'
gh release view --repo ggml-org/llama.cpp --json assets --jq '.assets[].name' | grep -i win
gh release view --repo ggml-org/whisper.cpp --json assets --jq '.assets[].name' | grep -i win
gh release view --repo microsoft/onnxruntime v1.29.0 --json assets \
  --jq '.assets[].name' | grep -i win
```

espeak-ng has no GitHub release binaries for ARM64 Windows; check PyPI for a wheel:

```bash
curl -s https://pypi.org/pypi/espeakng-loader/json \
  | python3 -c "import json,sys; print('\n'.join(f['filename'] for f in json.load(sys.stdin)['urls']))"
```

- [ ] **Step 2: Write the audit table**

`docs/windows-engine-assets.md` must contain one row per engine with: current macOS asset,
win-x64 asset, win-arm64 asset, and a verdict of `available` / `build from source` / `blocked`.
Any `build from source` row gets a one-line note on what building it needs.

- [ ] **Step 3: Commit**

```bash
git add docs/windows-engine-assets.md
git commit -m "Record which engines ship Windows x64 and ARM64 builds"
```

---

## Task 2: Spike — cross-compile C++ to win-x64 and win-arm64 from Docker

**Files:**
- Create: `Scripts/spike/hello.cpp`
- Create: `docker/core-cross.Dockerfile`

- [ ] **Step 1: Start Docker and confirm the daemon answers**

Run: `docker info >/dev/null 2>&1 && echo up || echo "start Docker Desktop"`
Expected: `up`. If not, open Docker Desktop and wait.

- [ ] **Step 2: Write the throwaway source**

`Scripts/spike/hello.cpp`:

```cpp
#include <cstdio>
#include <string>
int main() {
    std::string s = "nibcore cross-compile spike";
    std::printf("%s\n", s.c_str());
    return 0;
}
```

- [ ] **Step 3: Write the cross-compile image**

`docker/core-cross.Dockerfile`:

```dockerfile
# llvm-mingw gives one toolchain that targets both Windows arches, links a
# self-contained C++ runtime, and needs no Microsoft SDK download. The engines
# nib loads all expose a C ABI, so the MinGW/MSVC ABI split does not reach us.
FROM ubuntu:24.04

ARG LLVM_MINGW_VERSION=20250528
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils ca-certificates cmake ninja-build python3 git \
    && rm -rf /var/lib/apt/lists/*

# The release is published per build-host arch. This image runs under Docker on
# Apple silicon, so the aarch64 Linux host build is the one that exists.
RUN curl -fsSL -o /tmp/llvm-mingw.tar.xz \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-aarch64.tar.xz" \
    && mkdir -p /opt/llvm-mingw \
    && tar -xJf /tmp/llvm-mingw.tar.xz -C /opt/llvm-mingw --strip-components=1 \
    && rm /tmp/llvm-mingw.tar.xz

ENV PATH="/opt/llvm-mingw/bin:${PATH}"
WORKDIR /src
```

- [ ] **Step 4: Build the image**

Run: `docker build -f docker/core-cross.Dockerfile -t nib-core-cross .`
Expected: succeeds. If the llvm-mingw asset 404s, list real tags with
`gh release list --repo mstorsjo/llvm-mingw --limit 5` and update `LLVM_MINGW_VERSION`.

- [ ] **Step 5: Compile for both Windows architectures**

```bash
docker run --rm -v "$PWD:/src" nib-core-cross sh -c '
  x86_64-w64-mingw32-clang++   -std=c++20 -O2 Scripts/spike/hello.cpp -o /tmp/hello-x64.exe &&
  aarch64-w64-mingw32-clang++  -std=c++20 -O2 Scripts/spike/hello.cpp -o /tmp/hello-arm64.exe &&
  file /tmp/hello-x64.exe /tmp/hello-arm64.exe'
```

Expected: two lines, one reporting `PE32+ executable (console) x86-64`, the other
`PE32+ executable (console) Aarch64`.

- [ ] **Step 6: Record the verdict and commit**

If both arches produced PE binaries, the spike passed. Append the two `file` output lines to
`docs/windows-engine-assets.md` under a `## Toolchain` heading as the evidence.

```bash
git add docker/core-cross.Dockerfile Scripts/spike/hello.cpp docs/windows-engine-assets.md
git commit -m "Prove the core cross-compiles to Windows x64 and ARM64 from Docker"
```

---

## Task 3: Spike — build an MSI from Linux with WiX v5

**Files:**
- Create: `Scripts/spike/spike.wxs`
- Create: `docker/dotnet-win.Dockerfile`

- [ ] **Step 1: Write the .NET image that will serve both this task and Task 4**

`docker/dotnet-win.Dockerfile`:

```dockerfile
# One image for the Windows-targeting managed build: publishes the WPF app for
# both arches and packages the MSI. Neither step runs Windows code -- they only
# emit it.
FROM mcr.microsoft.com/dotnet/sdk:9.0

RUN dotnet tool install --global wix --version 5.0.2
ENV PATH="/root/.dotnet/tools:${PATH}"
WORKDIR /src
```

- [ ] **Step 2: Build the image**

Run: `docker build -f docker/dotnet-win.Dockerfile -t nib-dotnet-win .`
Expected: succeeds, and the `wix` tool installs. If the version 404s, run
`docker run --rm mcr.microsoft.com/dotnet/sdk:9.0 dotnet tool search wix` to find a real one.

- [ ] **Step 3: Write the minimal installer definition**

`Scripts/spike/spike.wxs`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- Throwaway. Proves only that WiX emits an MSI on Linux. -->
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="nib spike" Manufacturer="nib" Version="0.0.1"
           UpgradeCode="6f1d0e9c-8a44-4f1e-9f2b-7c3a5d1e4b20"
           Scope="perUser">
    <MajorUpgrade DowngradeErrorMessage="A newer version is already installed." />
    <StandardDirectory Id="LocalAppDataFolder">
      <Directory Id="INSTALLFOLDER" Name="nib" />
    </StandardDirectory>
    <ComponentGroup Id="Files" Directory="INSTALLFOLDER">
      <Component Id="ReadmeComponent" Guid="9a2b1c34-5d6e-4f70-8a91-2b3c4d5e6f70">
        <File Id="ReadmeFile" Source="Scripts/spike/spike.wxs" Name="readme.txt" />
      </Component>
    </ComponentGroup>
    <Feature Id="Main">
      <ComponentGroupRef Id="Files" />
    </Feature>
  </Package>
</Wix>
```

- [ ] **Step 4: Build the MSI**

```bash
docker run --rm -v "$PWD:/src" nib-dotnet-win sh -c '
  wix build Scripts/spike/spike.wxs -o /tmp/spike.msi && ls -l /tmp/spike.msi'
```

Expected: an MSI is written and listed with a non-zero size.

- [ ] **Step 5: Record the verdict**

Pass → MSI packaging stays in Docker. Fail → record the exact error in
`docs/windows-engine-assets.md` under `## Packaging`, and note that MSI packaging moves to the
`windows-latest` CI job. Either outcome is acceptable; only an unrecorded one is not.

- [ ] **Step 6: Commit**

```bash
git add docker/dotnet-win.Dockerfile Scripts/spike/spike.wxs docs/windows-engine-assets.md
git commit -m "Prove whether WiX builds an MSI on Linux"
```

---

## Task 4: Spike — publish a WPF app from Linux for both arches

**Files:**
- Create: `Scripts/spike/wpfspike/wpfspike.csproj`
- Create: `Scripts/spike/wpfspike/Program.cs`

- [ ] **Step 1: Write the project file**

`Scripts/spike/wpfspike/wpfspike.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net9.0-windows</TargetFramework>
    <UseWPF>true</UseWPF>
    <!-- Without this, the Windows Desktop SDK refuses to restore off-Windows. -->
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
    <RuntimeIdentifiers>win-x64;win-arm64</RuntimeIdentifiers>
    <SelfContained>true</SelfContained>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
```

- [ ] **Step 2: Write the entry point**

`Scripts/spike/wpfspike/Program.cs`:

```csharp
using System.Windows;

namespace WpfSpike;

// Proves the Windows Desktop SDK restores and publishes off-Windows. Never run.
public static class Program
{
    [System.STAThread]
    public static void Main()
    {
        var app = new Application();
        app.Run(new Window { Title = "nib spike", Width = 320, Height = 120 });
    }
}
```

- [ ] **Step 3: Publish for both architectures**

```bash
docker run --rm -v "$PWD:/src" nib-dotnet-win sh -c '
  cd Scripts/spike/wpfspike &&
  dotnet publish -c Release -r win-x64   -o /tmp/out-x64   &&
  dotnet publish -c Release -r win-arm64 -o /tmp/out-arm64 &&
  file /tmp/out-x64/wpfspike.exe /tmp/out-arm64/wpfspike.exe'
```

Expected: both publish, and `file` reports two PE binaries.

- [ ] **Step 4: Record the verdict**

Pass → the Windows UI iterates locally in Docker. Fail → record the error under
`## Managed build` and note that Windows UI builds are CI-only. This changes iteration speed,
not feasibility.

- [ ] **Step 5: Commit**

```bash
git add Scripts/spike/wpfspike docs/windows-engine-assets.md
git commit -m "Prove whether a WPF app publishes from Linux for both Windows arches"
```

---

## Task 5: Restructure the repo

One commit, mechanical, no behaviour change. Do it with `git mv` so history follows.

**Files:**
- Move: `Sources/` → `macos/Sources/`, `Tests/` → `macos/Tests/`,
  `Package.swift` → `macos/Package.swift`, `Resources/` → `macos/Resources/`,
  `vendor/` → `macos/vendor/`, `Casks/` → `macos/Casks/`
- Modify: `Scripts/*.sh` — every `$ROOT/vendor`, `$ROOT/Sources`, `.build/` path
- Modify: `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- Modify: `.gitignore`

- [ ] **Step 1: Confirm the tree is clean and tests pass before moving anything**

```bash
git status --porcelain          # expect empty
Scripts/fetch-harper.sh && Scripts/fetch-llama.sh && Scripts/fetch-whisper.sh
Scripts/fetch-espeak.sh && Scripts/fetch-onnx.sh
swift test 2>&1 | tail -5
```

Expected: tests pass. Record the pass count — it is the number Step 5 must reproduce.

- [ ] **Step 2: Move the macOS tree**

```bash
mkdir -p macos
git mv Sources macos/Sources
git mv Tests macos/Tests
git mv Package.swift macos/Package.swift
git mv Resources macos/Resources
git mv Casks macos/Casks
mkdir -p core/include/nib core/src core/tests goldens windows docker
```

`vendor/` and `.build/` are gitignored, so move them on disk rather than with git:

```bash
mv vendor macos/vendor 2>/dev/null || true
rm -rf .build macos/.build
```

- [ ] **Step 3: Repoint the scripts**

Every script computes `ROOT` as the parent of `Scripts/`. They now need the macOS subtree.
In each of `Scripts/bundle.sh`, `install.sh`, `make-dmg.sh`, `run.sh`, and all five
`fetch-*.sh`, change the `ROOT` line from:

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

to:

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS="$ROOT/macos"
```

then replace `$ROOT/vendor` with `$MACOS/vendor`, `$ROOT/Sources` with `$MACOS/Sources`,
and `$ROOT/.build` with `$MACOS/.build` throughout. `$ROOT/dist` stays at the repo root.

Find every site that needs changing:

```bash
grep -rn 'ROOT/\(vendor\|Sources\|\.build\)' Scripts/
```

Expected after editing: no matches.

- [ ] **Step 4: Update .gitignore**

Replace the `.build` and `vendor` entries with:

```
macos/.build/
macos/vendor/
core/build/
windows/**/bin/
windows/**/obj/
dist/
```

- [ ] **Step 5: Verify macOS still builds and tests identically**

```bash
cd macos && swift test 2>&1 | tail -5
```

Expected: the same pass count recorded in Step 1. Any difference means a path is wrong — fix
it before committing, do not proceed.

- [ ] **Step 6: Verify the app still bundles**

```bash
cd macos && swift build -c release && cd .. && Scripts/bundle.sh
```

Expected: `dist/nib.app` is written with no "missing" error from the vendor checks.

- [ ] **Step 7: Repoint both workflows**

In `.github/workflows/ci.yml` and `release.yml`, add a `defaults` block to the existing job so
Swift commands run in the subtree, leaving the `Scripts/` invocations at the root:

```yaml
jobs:
  macos:
    runs-on: macos-14
    defaults:
      run:
        working-directory: .
```

and change every bare `swift test` / `swift build -c release` to
`swift test --package-path macos` / `swift build -c release --package-path macos`. The
`iconutil` line becomes:

```yaml
          swift Scripts/make-icon.swift
          iconutil -c icns macos/Resources/AppIcon.iconset -o macos/Resources/AppIcon.icns
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Move the macOS app under macos/ and make room for core and windows"
```

---

## Task 6: Capture goldens from the shipped Swift

Goldens come out of the **current, working** implementation. They are a recording of what nib
does today, including behaviour no test asserts. Never hand-write or hand-edit them.

**Files:**
- Create: `Scripts/capture-goldens.swift`
- Create: `goldens/word-tokenize.json`
- Create: `goldens/sentence-split.json`

- [ ] **Step 1: Write the capture script**

`Scripts/capture-goldens.swift`:

```swift
// Records what the Swift implementation does, so the C++ port can be held to
// it exactly. Run before a module moves; the output is committed and then
// treated as read-only.
//
// Inputs are chosen to cover what the hand-written tests do not: surrogate
// pairs, combining marks, Indic viramas, abbreviations, decimals, dotted
// identifiers, and runs of whitespace.
import Foundation

let inputs: [String] = [
    "",
    "    \n  ",
    "The quick brown fox jumps over the dog.",
    "The quick brown fox jumps over it. Another long sentence follows here.",
    "The quick brown fox jumps here.    Second long sentence goes here.",
    "Thanks!",
    "Yes. No. Maybe.",
    "One two three.",
    "We tested e.g. the login flow and it worked well.",
    "The build takes 3.5 minutes on this machine now.",
    "We should check NSString.length before we index into it.",
    "this is a sentence without a full stop",
    "😀 The quick brown fox jumps over it.",
    "The first sentence lives here.\nThe second one lives here.",
    "don't split contractions or hyphen-joined words or snake_case names",
    "देवनागरी में लिखा गया एक वाक्य यहाँ है।",
    "café naïve résumé coöperate",
    "Dr. Smith arrived at 3.5 p.m. and left again.",
    "a\u{0301}ccent combining marks stay attached",
    "emoji 👨‍👩‍👧‍👦 family sequence splits on surrogates",
]

struct TokenRecord: Encodable {
    let text: String
    let location: Int
    let length: Int
}
struct SentenceRecord: Encodable {
    let text: String
    let location: Int
    let length: Int
}
struct TokenCase: Encodable {
    let input: String
    let tokens: [TokenRecord]
}
struct SentenceCase: Encodable {
    let input: String
    let minimumWords: Int
    let sentences: [SentenceRecord]
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

let tokenCases = inputs.map { input in
    TokenCase(input: input, tokens: WordDiff.tokenize(input).map {
        TokenRecord(text: $0.text, location: $0.range.location, length: $0.range.length)
    })
}

var sentenceCases: [SentenceCase] = []
for input in inputs {
    for minimum in [3, 5] {
        let found = SentenceSplitter.sentences(in: input, minimumWords: minimum)
        sentenceCases.append(SentenceCase(
            input: input,
            minimumWords: minimum,
            sentences: found.map {
                SentenceRecord(text: $0.text,
                               location: $0.range.location,
                               length: $0.range.length)
            }))
    }
}

try encoder.encode(tokenCases).write(to: URL(fileURLWithPath: "goldens/word-tokenize.json"))
try encoder.encode(sentenceCases).write(to: URL(fileURLWithPath: "goldens/sentence-split.json"))
FileHandle.standardError.write(
    "captured \(tokenCases.count) tokenize cases, \(sentenceCases.count) sentence cases\n"
        .data(using: .utf8)!)
```

- [ ] **Step 2: Make the capture script runnable against the package**

`WordDiff` and `SentenceSplitter` are internal to the `nib` target, so a loose script cannot
see them. Add a capture entry point to the existing executable instead. In
`macos/Sources/nib/main.swift`, find the argument dispatch and add a case alongside the
existing flags:

```swift
case "--capture-goldens":
    CaptureGoldens.run()
    exit(0)
```

Then move the body of Step 1's script into
`macos/Sources/nib/Support/CaptureGoldens.swift`, wrapped as:

```swift
enum CaptureGoldens {
    static func run() {
        // ... the inputs, structs and encoding from Step 1 ...
    }
}
```

Delete `Scripts/capture-goldens.swift` — the entry point replaces it.

- [ ] **Step 3: Capture**

```bash
cd macos && swift build -c release && cd ..
mkdir -p goldens
./macos/.build/release/nib --capture-goldens
```

Expected on stderr: `captured 20 tokenize cases, 40 sentence cases`

- [ ] **Step 4: Eyeball two entries, then stop editing them for ever**

```bash
python3 -c "
import json
d = json.load(open('goldens/word-tokenize.json'))
for c in d:
    if '👨' in c['input'] or 'देवनागरी' in c['input']:
        print(c['input']); print(' ', [t['text'] for t in c['tokens']])
"
```

Expected: the Devanagari sentence tokenises as whole words (combining marks held together),
and the family emoji splits — because `UnicodeScalar(unichar)` returns nil for a lone
surrogate, so surrogates count as separators. **That split is the behaviour to reproduce, not
a bug to fix.** If C++ "corrects" it, the golden fails and that is the point.

- [ ] **Step 5: Commit**

```bash
git add goldens macos/Sources/nib/Support/CaptureGoldens.swift macos/Sources/nib/main.swift
git commit -m "Record tokenizer and sentence splitter behaviour as goldens"
```

---

## Task 7: Core skeleton — CMake, ICU, Catch2, ABI header

**Files:**
- Create: `core/CMakeLists.txt`, `core/include/nib/version.h`,
  `core/include/nib/nib_core.h`, `core/src/text/utf16.hpp`, `core/src/abi/abi_version.cpp`,
  `core/tests/test_abi_version.cpp`

- [ ] **Step 1: Write the failing test**

`core/tests/test_abi_version.cpp`:

```cpp
#include <catch2/catch_test_macros.hpp>
#include "nib/nib_core.h"

TEST_CASE("the ABI reports the version it was compiled with") {
    REQUIRE(nib_abi_version() == NIB_CORE_ABI_VERSION);
}

TEST_CASE("the ABI version starts at 1") {
    REQUIRE(nib_abi_version() == 1);
}
```

- [ ] **Step 2: Write the version header**

`core/include/nib/version.h`:

```c
#ifndef NIB_CORE_VERSION_H
#define NIB_CORE_VERSION_H

/* Bumped on every change to nib_core.h that is not source-compatible.
   Both bindings assert against it at load, so a stale DLL fails loudly
   instead of reading the wrong offsets out of a struct. */
#define NIB_CORE_ABI_VERSION 1

#endif
```

- [ ] **Step 3: Write the ABI header**

`core/include/nib/nib_core.h`:

```c
#ifndef NIB_CORE_H
#define NIB_CORE_H

#include <stddef.h>
#include <stdint.h>
#include "nib/version.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(NIB_CORE_BUILDING)
#    define NIB_API __declspec(dllexport)
#  else
#    define NIB_API __declspec(dllimport)
#  endif
#else
#  define NIB_API __attribute__((visibility("default")))
#endif

/* Every string crossing this boundary is UTF-16, because NSString, LSP
   positions and C# strings all are. Offsets are UTF-16 code units, never
   graphemes and never bytes. */
typedef struct {
    const uint16_t* data;
    int32_t         length;
} nib_str;

/* A half-open range in UTF-16 code units, matching NSRange. */
typedef struct {
    int32_t location;
    int32_t length;
} nib_range;

NIB_API int32_t nib_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 4: Write the implementation**

`core/src/abi/abi_version.cpp`:

```cpp
#include "nib/nib_core.h"

extern "C" int32_t nib_abi_version(void) {
    return NIB_CORE_ABI_VERSION;
}
```

- [ ] **Step 5: Write the UTF-16 view the rest of the core will use**

`core/src/text/utf16.hpp`:

```cpp
#pragma once
#include <cstdint>
#include <string>
#include "nib/nib_core.h"

namespace nib {

// Non-owning. The caller owns the buffer for the duration of the call, which
// is what both Swift's withExtendedLifetime and C#'s fixed() already give us.
struct u16view {
    const uint16_t* data = nullptr;
    int32_t         size = 0;

    u16view() = default;
    u16view(const uint16_t* d, int32_t n) : data(d), size(n) {}
    explicit u16view(nib_str s) : data(s.data), size(s.length) {}

    uint16_t operator[](int32_t i) const { return data[i]; }
    bool empty() const { return size <= 0; }

    u16view slice(int32_t location, int32_t length) const {
        return u16view(data + location, length);
    }
    std::u16string to_string() const {
        return std::u16string(reinterpret_cast<const char16_t*>(data),
                              static_cast<size_t>(size));
    }
};

inline bool is_high_surrogate(uint16_t u) { return u >= 0xD800 && u <= 0xDBFF; }
inline bool is_low_surrogate(uint16_t u)  { return u >= 0xDC00 && u <= 0xDFFF; }

}  // namespace nib
```

- [ ] **Step 6: Write the build file**

`core/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.24)
project(nibcore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(nibcore SHARED
    src/abi/abi_version.cpp
)
target_include_directories(nibcore
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_definitions(nibcore PRIVATE NIB_CORE_BUILDING)

# Tests are host-native and never cross-compiled: they exist to check the
# logic, which is identical on every target.
option(NIB_CORE_TESTS "Build the core test suite" ON)
if(NIB_CORE_TESTS AND NOT CMAKE_CROSSCOMPILING)
    include(FetchContent)
    FetchContent_Declare(Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG        v3.7.1)
    FetchContent_MakeAvailable(Catch2)

    add_executable(nibcore_tests
        tests/test_abi_version.cpp
    )
    target_link_libraries(nibcore_tests PRIVATE nibcore Catch2::Catch2WithMain)
    target_include_directories(nibcore_tests
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
                ${CMAKE_CURRENT_SOURCE_DIR}/tests)

    include(CTest)
    include(Catch)
    catch_discover_tests(nibcore_tests)
endif()
```

- [ ] **Step 7: Run the tests and watch them pass**

```bash
cmake -S core -B core/build -G Ninja
cmake --build core/build
./core/build/nibcore_tests
```

Expected: `All tests passed (2 assertions in 2 test cases)`

- [ ] **Step 8: Confirm the shared library cross-compiles for both Windows arches**

```bash
docker run --rm -v "$PWD:/src" nib-core-cross sh -c '
  for arch in x86_64 aarch64; do
    cmake -S core -B /tmp/b-$arch -G Ninja -DNIB_CORE_TESTS=OFF \
      -DCMAKE_SYSTEM_NAME=Windows \
      -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
      -DCMAKE_CXX_COMPILER=$arch-w64-mingw32-clang++ \
      -DCMAKE_RC_COMPILER=$arch-w64-mingw32-windres &&
    cmake --build /tmp/b-$arch || exit 1
  done
  file /tmp/b-x86_64/libnibcore.dll /tmp/b-aarch64/libnibcore.dll'
```

Expected: two PE DLLs, one x86-64 and one Aarch64.

- [ ] **Step 9: Commit**

```bash
git add core
git commit -m "Add the core skeleton with a versioned C ABI"
```

---

## Task 8: Port the word tokenizer to C++

The tokenizer is `SentenceSplitter`'s dependency, so it moves first.

**Files:**
- Create: `core/src/text/word_tokenize.hpp`, `core/src/text/word_tokenize.cpp`
- Create: `core/tests/golden_loader.hpp`, `core/tests/test_word_tokenize.cpp`
- Modify: `core/CMakeLists.txt`

- [ ] **Step 1: Write the golden loader**

`core/tests/golden_loader.hpp`:

```cpp
#pragma once
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <nlohmann/json.hpp>

// Goldens live at the repo root, tests run from core/build. NIB_GOLDEN_DIR is
// set by CMake so the path does not depend on the working directory.
inline nlohmann::json load_golden(const std::string& name) {
    const std::string path = std::string(NIB_GOLDEN_DIR) + "/" + name;
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open golden: " + path);
    return nlohmann::json::parse(in);
}

// Goldens store JSON strings; the core works in UTF-16. std::u16string
// conversion goes through UTF-8 rather than codecvt, which is deprecated.
std::u16string utf8_to_utf16(const std::string& in);
```

Add the conversion to a new `core/tests/golden_loader.cpp`:

```cpp
#include "golden_loader.hpp"
#include <unicode/unistr.h>

std::u16string utf8_to_utf16(const std::string& in) {
    icu::UnicodeString u = icu::UnicodeString::fromUTF8(in);
    return std::u16string(reinterpret_cast<const char16_t*>(u.getBuffer()),
                          static_cast<size_t>(u.length()));
}
```

- [ ] **Step 2: Write the failing test**

`core/tests/test_word_tokenize.cpp`:

```cpp
#include <catch2/catch_test_macros.hpp>
#include "golden_loader.hpp"
#include "text/word_tokenize.hpp"

// Every case in the golden was produced by the shipped Swift. A failure here
// means the C++ disagrees with what nib does today -- which is the only
// question this test asks. It does not ask whether the behaviour is good.
TEST_CASE("tokenize matches the Swift goldens") {
    auto golden = load_golden("word-tokenize.json");
    REQUIRE(golden.size() > 0);

    for (const auto& c : golden) {
        const std::u16string input = utf8_to_utf16(c["input"].get<std::string>());
        const auto tokens = nib::tokenize(nib::u16view(
            reinterpret_cast<const uint16_t*>(input.data()),
            static_cast<int32_t>(input.size())));

        INFO("input: " << c["input"].get<std::string>());
        REQUIRE(tokens.size() == c["tokens"].size());

        for (size_t i = 0; i < tokens.size(); ++i) {
            INFO("token " << i);
            CHECK(tokens[i].range.location == c["tokens"][i]["location"].get<int32_t>());
            CHECK(tokens[i].range.length   == c["tokens"][i]["length"].get<int32_t>());
            CHECK(tokens[i].text == utf8_to_utf16(c["tokens"][i]["text"].get<std::string>()));
        }
    }
}
```

- [ ] **Step 3: Write the header**

`core/src/text/word_tokenize.hpp`:

```cpp
#pragma once
#include <string>
#include <vector>
#include "nib/nib_core.h"
#include "text/utf16.hpp"

namespace nib {

struct Token {
    std::u16string text;
    nib_range      range;
};

// Port of WordDiff.tokenize. Separators are skipped for matching, but their
// offsets survive in the ranges.
std::vector<Token> tokenize(u16view text);

}  // namespace nib
```

- [ ] **Step 4: Run the test and watch it fail**

```bash
cmake --build core/build 2>&1 | tail -20
```

Expected: a link or compile error naming `nib::tokenize` as undefined. That is the failure to
fix.

- [ ] **Step 5: Write the implementation**

`core/src/text/word_tokenize.cpp`:

```cpp
#include "text/word_tokenize.hpp"
#include <unicode/uchar.h>

namespace nib {
namespace {

// Mirrors the Swift exactly, including its limits.
//
// The Swift builds a UnicodeScalar from one UTF-16 code unit, which returns
// nil for a lone surrogate -- so a surrogate is a separator and an emoji
// splits a word. Reproduced deliberately: the goldens record it, and changing
// it here would move behaviour that macOS ships today.
bool is_word_character(uint16_t unit) {
    if (is_high_surrogate(unit) || is_low_surrogate(unit)) return false;

    const UChar32 c = static_cast<UChar32>(unit);

    // CharacterSet.nonBaseCharacters -- combining marks belong to the letter
    // they attach to. Indic viramas and vowel signs sit mid-word, and treating
    // them as separators gives every piece its own underline.
    if (u_hasBinaryProperty(c, UCHAR_GRAPHEME_EXTEND)) return true;
    const int8_t category = static_cast<int8_t>(u_charType(c));
    if (category == U_NON_SPACING_MARK || category == U_COMBINING_SPACING_MARK
        || category == U_ENCLOSING_MARK) {
        return true;
    }

    if (u_isalpha(c) || u_isdigit(c)) return true;

    return c == u'\'' || c == u'’' || c == u'-' || c == u'_';
}

}  // namespace

std::vector<Token> tokenize(u16view text) {
    std::vector<Token> tokens;
    int32_t start = -1;
    int32_t index = 0;

    auto push = [&](int32_t from, int32_t to) {
        nib_range r{from, to - from};
        tokens.push_back(Token{text.slice(r.location, r.length).to_string(), r});
    };

    while (index < text.size) {
        if (is_word_character(text[index])) {
            if (start < 0) start = index;
        } else if (start >= 0) {
            push(start, index);
            start = -1;
        }
        ++index;
    }
    if (start >= 0) push(start, text.size);

    return tokens;
}

}  // namespace nib
```

- [ ] **Step 6: Wire ICU and nlohmann into the build**

Replace the `add_library` and test blocks in `core/CMakeLists.txt`:

```cmake
include(FetchContent)

# ICU is vendored, not taken from the system. Windows ships its own icu.dll
# whose version segments differently from the one macOS Foundation uses, and
# that difference would show up as nib underlining different sentences on the
# two platforms. One copy, one answer.
find_package(ICU 76 COMPONENTS uc i18n data QUIET)
if(NOT ICU_FOUND)
    message(FATAL_ERROR
        "ICU 76+ not found. macOS: brew install icu4c and set "
        "ICU_ROOT=$(brew --prefix icu4c). Container: apt-get install libicu-dev.")
endif()

add_library(nibcore SHARED
    src/abi/abi_version.cpp
    src/text/word_tokenize.cpp
)
target_link_libraries(nibcore PRIVATE ICU::uc ICU::i18n ICU::data)
```

and in the test block:

```cmake
    FetchContent_Declare(nlohmann_json
        GIT_REPOSITORY https://github.com/nlohmann/json.git
        GIT_TAG        v3.11.3)
    FetchContent_MakeAvailable(nlohmann_json)

    add_executable(nibcore_tests
        tests/test_abi_version.cpp
        tests/golden_loader.cpp
        tests/test_word_tokenize.cpp
    )
    target_link_libraries(nibcore_tests
        PRIVATE nibcore Catch2::Catch2WithMain nlohmann_json::nlohmann_json
                ICU::uc ICU::i18n ICU::data)
    target_compile_definitions(nibcore_tests
        PRIVATE NIB_GOLDEN_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../goldens")
```

- [ ] **Step 7: Install ICU and rebuild**

```bash
brew install icu4c
cmake -S core -B core/build -G Ninja -DICU_ROOT="$(brew --prefix icu4c)"
cmake --build core/build
./core/build/nibcore_tests
```

Expected: all tests pass, including the 20 golden tokenize cases.

- [ ] **Step 8: Break it on purpose to prove the golden bites**

Temporarily change `is_word_character` to return `true` for surrogates, rebuild, and run.
Expected: the family-emoji case fails with a token-count mismatch. Revert the change and
confirm green again. A golden that cannot fail is not protecting anything.

- [ ] **Step 9: Commit**

```bash
git add core
git commit -m "Port the word tokenizer to C++ against the Swift goldens"
```

---

## Task 9: Port the sentence splitter to C++

**Files:**
- Create: `core/src/text/sentence_split.hpp`, `core/src/text/sentence_split.cpp`
- Create: `core/tests/test_sentence_split.cpp`
- Modify: `core/CMakeLists.txt`

- [ ] **Step 1: Write the failing test**

`core/tests/test_sentence_split.cpp`:

```cpp
#include <catch2/catch_test_macros.hpp>
#include "golden_loader.hpp"
#include "text/sentence_split.hpp"

TEST_CASE("sentence splitting matches the Swift goldens") {
    auto golden = load_golden("sentence-split.json");
    REQUIRE(golden.size() > 0);

    for (const auto& c : golden) {
        const std::u16string input = utf8_to_utf16(c["input"].get<std::string>());
        const int32_t minimum = c["minimumWords"].get<int32_t>();

        const auto found = nib::sentences(
            nib::u16view(reinterpret_cast<const uint16_t*>(input.data()),
                         static_cast<int32_t>(input.size())),
            minimum);

        INFO("input: " << c["input"].get<std::string>()
             << " minimumWords: " << minimum);
        REQUIRE(found.size() == c["sentences"].size());

        for (size_t i = 0; i < found.size(); ++i) {
            INFO("sentence " << i);
            CHECK(found[i].range.location == c["sentences"][i]["location"].get<int32_t>());
            CHECK(found[i].range.length   == c["sentences"][i]["length"].get<int32_t>());
            CHECK(found[i].text == utf8_to_utf16(c["sentences"][i]["text"].get<std::string>()));
        }
    }
}
```

- [ ] **Step 2: Write the header**

`core/src/text/sentence_split.hpp`:

```cpp
#pragma once
#include <string>
#include <vector>
#include "nib/nib_core.h"
#include "text/utf16.hpp"

namespace nib {

struct Sentence {
    std::u16string text;
    nib_range      range;  // UTF-16 offsets into the source
};

// Port of SentenceSplitter.sentences. Fragments shorter than minimumWords are
// dropped -- the model has nothing useful to say about "Thanks!".
std::vector<Sentence> sentences(u16view text, int32_t minimum_words = 5);

}  // namespace nib
```

- [ ] **Step 3: Run the test and watch it fail**

```bash
cmake --build core/build 2>&1 | tail -20
```

Expected: undefined reference to `nib::sentences`.

- [ ] **Step 4: Write the implementation**

`core/src/text/sentence_split.cpp`:

```cpp
#include "text/sentence_split.hpp"
#include <memory>
#include <unicode/brkiter.h>
#include <unicode/uchar.h>
#include "text/word_tokenize.hpp"

namespace nib {
namespace {

// enumerateSubstrings(.bySentences, .localized) is ICU's sentence
// BreakIterator underneath. Using it directly is what keeps "e.g.", "3.5" and
// "NSString.length" from splitting a sentence -- the behaviour the Swift
// comment calls out and the goldens record.
bool is_whitespace(uint16_t unit) {
    const UChar32 c = static_cast<UChar32>(unit);
    return u_isUWhiteSpace(c) || c == u'\n' || c == u'\r';
}

// Shrinks a range to exclude leading and trailing whitespace, so a clarity
// mark does not extend across the blank space after a sentence.
bool tighten(u16view text, int32_t location, int32_t length, nib_range* out) {
    int32_t start = location;
    int32_t end = location + length;
    while (start < end && is_whitespace(text[start])) ++start;
    while (end > start && is_whitespace(text[end - 1])) --end;
    if (end <= start) return false;
    *out = nib_range{start, end - start};
    return true;
}

}  // namespace

std::vector<Sentence> sentences(u16view text, int32_t minimum_words) {
    std::vector<Sentence> found;
    if (text.empty()) return found;

    UErrorCode status = U_ZERO_ERROR;
    std::unique_ptr<icu::BreakIterator> it(
        icu::BreakIterator::createSentenceInstance(icu::Locale::getDefault(), status));
    if (U_FAILURE(status) || !it) return found;

    icu::UnicodeString u(reinterpret_cast<const char16_t*>(text.data), text.size);
    it->setText(u);

    for (int32_t start = it->first(), end = it->next();
         end != icu::BreakIterator::DONE;
         start = end, end = it->next()) {
        nib_range tight{};
        if (!tighten(text, start, end - start, &tight)) continue;

        const u16view slice = text.slice(tight.location, tight.length);
        if (static_cast<int32_t>(tokenize(slice).size()) < minimum_words) continue;

        found.push_back(Sentence{slice.to_string(), tight});
    }
    return found;
}

}  // namespace nib
```

- [ ] **Step 5: Add both files to the build**

In `core/CMakeLists.txt`, add `src/text/sentence_split.cpp` to the `add_library` sources and
`tests/test_sentence_split.cpp` to the `add_executable` sources.

- [ ] **Step 6: Run the tests**

```bash
cmake --build core/build && ./core/build/nibcore_tests
```

Expected: all pass, including the 40 golden sentence cases.

If the locale-dependent cases disagree, the Swift used `.localized` — the *user's* locale, not
the root locale. Set the same one explicitly rather than guessing:
`icu::Locale::createFromName("en_US")` and re-capture the goldens under `LANG=en_US.UTF-8` so
both sides state their locale instead of inheriting it. Record whichever you chose as a
comment in the file.

- [ ] **Step 7: Commit**

```bash
git add core
git commit -m "Port the sentence splitter to C++ using ICU sentence breaks"
```

---

## Task 10: Expose the splitter through the ABI

**Files:**
- Modify: `core/include/nib/nib_core.h`
- Create: `core/src/abi/abi_text.cpp`
- Create: `core/tests/test_abi_text.cpp`
- Modify: `core/CMakeLists.txt`

- [ ] **Step 1: Write the failing test**

`core/tests/test_abi_text.cpp`:

```cpp
#include <catch2/catch_test_macros.hpp>
#include <string>
#include "nib/nib_core.h"

// The ABI hands back an opaque handle the caller drains and then frees. This
// avoids the two traps: returning a pointer into a C++ container that moves,
// and making the caller guess a buffer size up front.
TEST_CASE("the ABI returns sentences and frees them") {
    const std::u16string text =
        u"The quick brown fox jumps over it. Another long sentence follows here.";
    nib_str in{reinterpret_cast<const uint16_t*>(text.data()),
               static_cast<int32_t>(text.size())};

    nib_sentence_list* list = nib_sentences(in, 5);
    REQUIRE(list != nullptr);
    REQUIRE(nib_sentence_count(list) == 2);

    nib_range first = nib_sentence_range(list, 0);
    CHECK(first.location == 0);
    CHECK(first.length == 34);

    nib_range second = nib_sentence_range(list, 1);
    CHECK(second.location > first.location + first.length - 1);

    nib_sentence_list_free(list);
}

TEST_CASE("an out-of-bounds index returns an empty range rather than crashing") {
    const std::u16string text = u"The quick brown fox jumps over it.";
    nib_str in{reinterpret_cast<const uint16_t*>(text.data()),
               static_cast<int32_t>(text.size())};

    nib_sentence_list* list = nib_sentences(in, 5);
    nib_range out = nib_sentence_range(list, 99);
    CHECK(out.location == 0);
    CHECK(out.length == 0);
    nib_sentence_list_free(list);
}

TEST_CASE("freeing null is safe") {
    nib_sentence_list_free(nullptr);
    SUCCEED();
}
```

- [ ] **Step 2: Extend the ABI header**

Add to `core/include/nib/nib_core.h`, before the closing `extern "C"` brace:

```c
/* Opaque. The caller drains it with the accessors below, then frees it.
   Never dereference, never copy. */
typedef struct nib_sentence_list nib_sentence_list;

/* Splits text into sentences worth a clarity suggestion. Never returns NULL.
   The returned list borrows nothing from `text` -- it owns its own copies, so
   the caller may free `text` immediately. */
NIB_API nib_sentence_list* nib_sentences(nib_str text, int32_t minimum_words);

NIB_API int32_t   nib_sentence_count(const nib_sentence_list* list);
NIB_API nib_range nib_sentence_range(const nib_sentence_list* list, int32_t index);

/* Copies sentence `index` into `buffer`, writing at most `capacity` UTF-16
   units. Returns the full length, which may exceed `capacity` -- call with
   capacity 0 first to size the buffer. */
NIB_API int32_t nib_sentence_text(const nib_sentence_list* list, int32_t index,
                                  uint16_t* buffer, int32_t capacity);

/* Safe on NULL. */
NIB_API void nib_sentence_list_free(nib_sentence_list* list);
```

- [ ] **Step 3: Write the implementation**

`core/src/abi/abi_text.cpp`:

```cpp
#include <algorithm>
#include <cstring>
#include <vector>
#include "nib/nib_core.h"
#include "text/sentence_split.hpp"

// The handle owns its sentences outright. Returning pointers into a vector
// that the caller might outlive is the classic way to make an ABI crash three
// calls later in someone else's code.
struct nib_sentence_list {
    std::vector<nib::Sentence> items;
};

extern "C" {

nib_sentence_list* nib_sentences(nib_str text, int32_t minimum_words) {
    auto* list = new nib_sentence_list();
    if (text.data != nullptr && text.length > 0) {
        list->items = nib::sentences(nib::u16view(text), minimum_words);
    }
    return list;
}

int32_t nib_sentence_count(const nib_sentence_list* list) {
    return list ? static_cast<int32_t>(list->items.size()) : 0;
}

nib_range nib_sentence_range(const nib_sentence_list* list, int32_t index) {
    if (!list || index < 0 || index >= static_cast<int32_t>(list->items.size())) {
        return nib_range{0, 0};
    }
    return list->items[static_cast<size_t>(index)].range;
}

int32_t nib_sentence_text(const nib_sentence_list* list, int32_t index,
                          uint16_t* buffer, int32_t capacity) {
    if (!list || index < 0 || index >= static_cast<int32_t>(list->items.size())) {
        return 0;
    }
    const auto& text = list->items[static_cast<size_t>(index)].text;
    const int32_t length = static_cast<int32_t>(text.size());
    if (buffer && capacity > 0) {
        const int32_t n = std::min(length, capacity);
        std::memcpy(buffer, text.data(), static_cast<size_t>(n) * sizeof(uint16_t));
    }
    return length;
}

void nib_sentence_list_free(nib_sentence_list* list) {
    delete list;
}

}  // extern "C"
```

- [ ] **Step 4: Add to the build and run**

Add `src/abi/abi_text.cpp` to `add_library` and `tests/test_abi_text.cpp` to
`add_executable`, then:

```bash
cmake --build core/build && ./core/build/nibcore_tests
```

Expected: all pass.

- [ ] **Step 5: Confirm it still cross-compiles**

Re-run the Task 7 Step 8 command. Expected: two PE DLLs again. ICU must be present in the
cross image — if the link fails on ICU symbols, add to `docker/core-cross.Dockerfile` a stage
that builds ICU for both Windows arches with the same llvm-mingw toolchain, and record the
recipe in `docs/windows-engine-assets.md`.

- [ ] **Step 6: Commit**

```bash
git add core
git commit -m "Expose sentence splitting through the C ABI"
```

---

## Task 11: Swap the macOS app onto the core

This is the step that proves the whole design. The Swift `SentenceSplitter` is deleted and its
callers reach the C++ instead — with the existing XCTest suite unchanged as the judge.

**Files:**
- Create: `macos/Sources/CNibCore/module.modulemap`
- Create: `macos/Sources/nib/Core/CoreBridge.swift`
- Delete: `macos/Sources/nib/Lint/SentenceSplitter.swift`
- Modify: `macos/Package.swift`

- [ ] **Step 1: Find every caller**

```bash
grep -rn 'SentenceSplitter' macos/Sources macos/Tests
```

Record the list. Every one of them must compile unchanged after this task — the bridge keeps
the same name and shape deliberately, so the diff is one file, not twenty.

- [ ] **Step 2: Add the C target to the package**

`macos/Sources/CNibCore/module.modulemap`:

```
module CNibCore {
    header "../../../core/include/nib/nib_core.h"
    export *
}
```

In `macos/Package.swift`, add the target and the dependency:

```swift
        .systemLibrary(
            name: "CNibCore",
            path: "Sources/CNibCore"
        ),
```

and add `"CNibCore"` to the `nib` executable target's `dependencies`, plus the link flags:

```swift
        .executableTarget(
            name: "nib",
            dependencies: ["whisper", "CKokoro", "CNibCore"],
            path: "Sources/nib",
            linkerSettings: [
                .unsafeFlags(["-L../core/build", "-lnibcore",
                              "-Wl,-rpath,@executable_path/../Frameworks"])
            ]
        ),
```

- [ ] **Step 3: Write the bridge with the identical public shape**

`macos/Sources/nib/Core/CoreBridge.swift`:

```swift
import CNibCore
import Foundation

/// Swift's view of the C++ core.
///
/// The shape matches the Swift this replaced, so callers do not change. That
/// is deliberate: one file moves, and the existing tests judge the move.
enum SentenceSplitter {
    struct Sentence: Equatable {
        let text: String
        /// Range in the source, in UTF-16 offsets.
        let range: NSRange
    }

    static func sentences(in text: String, minimumWords: Int = 5) -> [Sentence] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        return units.withUnsafeBufferPointer { buffer -> [Sentence] in
            let input = nib_str(data: buffer.baseAddress,
                                length: Int32(buffer.count))
            guard let list = nib_sentences(input, Int32(minimumWords)) else { return [] }
            defer { nib_sentence_list_free(list) }

            let count = Int(nib_sentence_count(list))
            var found: [Sentence] = []
            found.reserveCapacity(count)

            for index in 0..<count {
                let range = nib_sentence_range(list, Int32(index))
                let length = Int(nib_sentence_text(list, Int32(index), nil, 0))
                var scratch = [UInt16](repeating: 0, count: length)
                _ = scratch.withUnsafeMutableBufferPointer {
                    nib_sentence_text(list, Int32(index), $0.baseAddress, Int32(length))
                }
                found.append(Sentence(
                    text: String(decoding: scratch, as: UTF16.self),
                    range: NSRange(location: Int(range.location),
                                   length: Int(range.length))))
            }
            return found
        }
    }
}
```

- [ ] **Step 4: Delete the Swift implementation**

```bash
git rm macos/Sources/nib/Lint/SentenceSplitter.swift
```

- [ ] **Step 5: Build the core for macOS, then run the existing test suite unchanged**

```bash
cmake -S core -B core/build -G Ninja -DICU_ROOT="$(brew --prefix icu4c)"
cmake --build core/build
cd macos && swift test --filter SentenceSplitterTests 2>&1 | tail -20
```

Expected: all 13 `SentenceSplitterTests` cases pass against the C++ implementation, with the
test file untouched. If `testRangesAreCorrectAfterAnEmoji` or
`testAbbreviationsDoNotSplitTheSentence` fails, the ICU locale differs — see Task 9 Step 6.

- [ ] **Step 6: Run the whole suite**

```bash
cd macos && swift test 2>&1 | tail -5
```

Expected: the same pass count as Task 5 Step 1, minus nothing.

- [ ] **Step 7: Confirm the app still runs**

```bash
cd macos && swift build -c release && cd ..
./macos/.build/release/nib --lint "Their is many erors in this sentence right here."
```

Expected: suggestions print, exactly as before. The clarity path now runs through C++.

- [ ] **Step 8: Teach bundle.sh to ship the dylib**

`Scripts/bundle.sh` must copy `core/build/libnibcore.dylib` into
`dist/nib.app/Contents/Frameworks/` alongside the existing vendored libraries, and add a
guard matching the others:

```bash
if [[ ! -f "$ROOT/core/build/libnibcore.dylib" ]]; then
  echo "libnibcore missing -- run: cmake --build core/build" >&2
  exit 1
fi
```

Verify:

```bash
Scripts/bundle.sh && otool -L dist/nib.app/Contents/MacOS/nib | grep nibcore
```

Expected: an `@rpath/libnibcore.dylib` entry.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Move sentence splitting out of Swift and into the shared core"
```

---

## Task 12: CI across three runners

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Rewrite the workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  # The core's logic is identical on every target, so it is tested once on the
  # cheapest runner rather than three times.
  core:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: Install ICU and Ninja
        run: sudo apt-get update && sudo apt-get install -y libicu-dev ninja-build
      - name: Configure
        run: cmake -S core -B core/build -G Ninja
      - name: Build
        run: cmake --build core/build
      - name: Test
        run: ./core/build/nibcore_tests

  # Proves the core still produces a DLL for both Windows arches. Does not run
  # it -- that is what the windows jobs are for.
  core-cross:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: Build the cross image
        run: docker build -f docker/core-cross.Dockerfile -t nib-core-cross .
      - name: Cross-compile for win-x64 and win-arm64
        run: |
          docker run --rm -v "$PWD:/src" nib-core-cross sh -c '
            for arch in x86_64 aarch64; do
              cmake -S core -B /tmp/b-$arch -G Ninja -DNIB_CORE_TESTS=OFF \
                -DCMAKE_SYSTEM_NAME=Windows \
                -DCMAKE_C_COMPILER=$arch-w64-mingw32-clang \
                -DCMAKE_CXX_COMPILER=$arch-w64-mingw32-clang++ \
                -DCMAKE_RC_COMPILER=$arch-w64-mingw32-windres || exit 1
              cmake --build /tmp/b-$arch || exit 1
            done
            file /tmp/b-x86_64/libnibcore.dll /tmp/b-aarch64/libnibcore.dll'

  # The core cross image is built for a Linux aarch64 host in Task 2 because
  # Docker on Apple silicon runs aarch64. GitHub's ubuntu-24.04 runner is
  # x86_64, so the Dockerfile must select the llvm-mingw asset by host arch.
  # If core-cross fails here with a 404, that is the cause.

  macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Install ICU and Ninja
        run: brew install icu4c ninja
      - name: Build the core
        run: |
          cmake -S core -B core/build -G Ninja -DICU_ROOT="$(brew --prefix icu4c)"
          cmake --build core/build
      - name: Core tests
        run: ./core/build/nibcore_tests
      - name: Fetch harper-ls
        run: Scripts/fetch-harper.sh
      - name: Fetch llama-server
        run: Scripts/fetch-llama.sh
      - name: Fetch whisper
        run: Scripts/fetch-whisper.sh
      - name: Fetch espeak-ng
        run: Scripts/fetch-espeak.sh
      - name: Fetch ONNX Runtime
        run: Scripts/fetch-onnx.sh
      - name: Test
        run: swift test --package-path macos
      - name: Build release
        run: swift build -c release --package-path macos
      - name: Package
        run: |
          swift Scripts/make-icon.swift
          iconutil -c icns macos/Resources/AppIcon.iconset -o macos/Resources/AppIcon.icns
          Scripts/bundle.sh
          Scripts/make-dmg.sh

  # Real Windows. This phase only proves the DLL loads and reports its ABI
  # version; Phase 2 grows it into the app's test suite.
  windows:
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: windows-latest
            arch: x64
          - runner: windows-11-arm
            arch: arm64
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: lukka/get-cmake@latest
      - name: Build the core natively
        run: |
          cmake -S core -B core/build -DNIB_CORE_TESTS=OFF
          cmake --build core/build --config Release
      - name: Confirm the DLL loads and answers
        shell: pwsh
        run: |
          $dll = Get-ChildItem -Recurse -Filter nibcore.dll core/build |
                 Select-Object -First 1
          if (-not $dll) { throw "nibcore.dll was not built" }
          Add-Type -TypeDefinition @"
            using System;
            using System.Runtime.InteropServices;
            public static class Probe {
              [DllImport("$($dll.FullName.Replace('\','\\'))")]
              public static extern int nib_abi_version();
            }
"@
          $version = [Probe]::nib_abi_version()
          if ($version -ne 1) { throw "expected ABI version 1, got $version" }
          Write-Host "nibcore.dll on ${{ matrix.arch }} reports ABI version $version"
```

- [ ] **Step 2: Push the branch and watch all five jobs**

```bash
git add .github/workflows/ci.yml
git commit -m "Run CI across the core, both cross targets, macOS and both Windows arches"
git push -u origin HEAD
gh run watch
```

Expected: `core`, `core-cross`, `macos`, `windows (x64)` and `windows (arm64)` all green.

If `windows-11-arm` is unavailable to the repository, record that in the roadmap's Risks
section and drop that matrix entry rather than leaving a permanently red job — an ignored red
job is worse than an absent one.

- [ ] **Step 3: Delete the spikes**

They proved their point and should not rot:

```bash
git rm -r Scripts/spike
git commit -m "Remove the toolchain spikes now that CI proves the same things"
```

---

## Phase 0 exit criteria

All of these must hold before Phase 1 starts:

- [ ] `docs/windows-engine-assets.md` names a Windows x64 and ARM64 answer for all five engines
- [ ] `nibcore.dll` cross-compiles for win-x64 and win-arm64 from Docker on your Mac
- [ ] The WiX and WPF spike verdicts are recorded, pass or fail
- [ ] `macos/`, `core/`, `windows/`, `docker/`, `goldens/` exist and the repo builds from each
- [ ] `swift test --package-path macos` passes with the same count as before the restructure
- [ ] `SentenceSplitter` exists only in C++; the Swift file is deleted and its 13 XCTests pass
- [ ] Deliberately breaking the C++ makes a golden fail (proven in Task 8 Step 8)
- [ ] CI is green on ubuntu, macos-14, windows-latest and windows-11-arm
- [ ] `dist/nib.app` runs and `--lint` still prints suggestions

---

## Self-review notes

Checked against the roadmap:

- Every roadmap Phase 0 commitment has a task: spikes (2, 3, 4), restructure (5), CI (12),
  tracer module (6, 8, 9, 10, 11), engine audit (1).
- No placeholders: every code step carries the full file or the exact edit.
- Type consistency: `nib_str`, `nib_range`, `nib_sentence_list`, `nib::u16view`, `nib::Token`,
  `nib::Sentence` are defined once and used with those exact names throughout. The Swift
  `SentenceSplitter.Sentence` keeps `text` and `range` so callers are untouched.
- Known gap carried forward deliberately: ICU for the Windows cross build is handled reactively
  in Task 10 Step 5 rather than up front, because whether llvm-mingw's sysroot already supplies
  it is unknown until Task 2 runs. If it does not, that step writes the recipe.
