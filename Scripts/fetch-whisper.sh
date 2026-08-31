#!/usr/bin/env bash
# Download whisper.cpp's XCFramework into vendor/whisper/.
#
# This is the speech engine behind dictation. Unlike llama.cpp, whisper.cpp
# publishes no macOS command-line build -- its release assets are Linux,
# Windows, and this XCFramework -- so nib links the library directly instead of
# running a server beside it. That removes the subprocess, the port, the health
# check and the dylib closure the llama integration needs.
#
# Upstream is pinned and not mirrored. whisper.cpp publishes the XCFramework
# rarely and keeps it: 15 releases carry it, back to b2365 in March 2025. The
# llama runtime had to be mirrored because upstream prunes to about nine days;
# this one does not.
set -euo pipefail

BUILD="${WHISPER_BUILD:-b4938}"
SHA256="dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor/whisper"
FRAMEWORK="$DEST/whisper.xcframework"
SLICE="macos-arm64_x86_64"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "unsupported arch: $(uname -m) (nib ships Apple silicon only)" >&2
  exit 1
fi

if [[ -f "$FRAMEWORK/$SLICE/whisper.framework/whisper" ]] \
   && [[ -f "$DEST/.build-id" ]] \
   && [[ "$(cat "$DEST/.build-id")" == "$BUILD" ]]; then
  echo "whisper.xcframework $BUILD already present"
  exit 0
fi

ASSET="whisper-${BUILD}-xcframework.zip"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${BUILD}/${ASSET}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching whisper.cpp $BUILD"
curl -fsSL -o "$WORK/$ASSET" "$URL"

ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "checksum mismatch for $ASSET" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $ACTUAL" >&2
  exit 1
fi

unzip -q "$WORK/$ASSET" -d "$WORK/x"
SRC="$WORK/x/build-apple/whisper.xcframework"
if [[ ! -d "$SRC/$SLICE" ]]; then
  echo "no $SLICE slice in $ASSET -- upstream layout changed" >&2
  exit 1
fi

# Keep the macOS slice and drop the rest.
#
# The published XCFramework carries iOS, tvOS, visionOS and their simulators,
# plus dSYMs: 246MB unpacked, of which nib links 6MB. SwiftPM copies whatever
# it is pointed at, so trimming here keeps it out of every build directory.
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/$SLICE"
cp -R "$SRC/$SLICE/whisper.framework" "$FRAMEWORK/$SLICE/whisper.framework"

# The Info.plist still advertises the platforms that were just removed, and
# SwiftPM believes it. Rewritten from the original rather than authored from
# scratch, so the slice's own keys stay exactly as upstream set them.
python3 - "$SRC/Info.plist" "$FRAMEWORK/Info.plist" "$SLICE" <<'PY'
import plistlib, sys

source, destination, slice_id = sys.argv[1:4]
with open(source, "rb") as handle:
    plist = plistlib.load(handle)

kept = [lib for lib in plist.get("AvailableLibraries", [])
        if lib.get("LibraryIdentifier") == slice_id]
if not kept:
    raise SystemExit(f"{slice_id} is not in the framework's Info.plist")

plist["AvailableLibraries"] = kept
with open(destination, "wb") as handle:
    plistlib.dump(plist, handle)
PY

echo "$BUILD" > "$DEST/.build-id"
# Downloaded binaries carry a quarantine flag that blocks loading.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

BINARY="$FRAMEWORK/$SLICE/whisper.framework/whisper"
echo "  $(lipo -archs "$BINARY")"
echo "  $(nm -gU "$BINARY" | grep -c '_whisper_') whisper symbols, \
$(strings "$BINARY" | grep -c 'kernel void') Metal kernels"
du -sh "$FRAMEWORK" | awk '{print "  size: " $1}'
