#!/usr/bin/env bash
# Download ONNX Runtime into vendor/onnx/.
#
# The thing that actually runs Kokoro. Phonemes and a style vector go in, audio
# samples come out; everything else in Sources/nib/Speech exists to produce
# those inputs.
#
# 1.29.0 to match the working Python setup, which runs onnxruntime 1.29.0. The
# audio fixture was captured through it, and a different build can produce
# different samples for the same input -- so the version is pinned rather than
# tracked, and the engine reports what it loaded.
#
# ONNX Runtime is MIT. It is the one bundled dependency that does not push nib
# towards GPL; espeak-ng already did that.
set -euo pipefail

VERSION="${ONNXRUNTIME_VERSION:-1.29.0}"
ASSET="onnxruntime-osx-arm64-${VERSION}.tgz"
URL="https://github.com/microsoft/onnxruntime/releases/download/v${VERSION}/${ASSET}"
SHA256="d0706fc34f315d8c88639d0a8c81f2e09e815f282cabed3493c06a054352cf92"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor/onnx"
LIB="$DEST/libonnxruntime.dylib"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "unsupported arch: $(uname -m) (nib ships Apple silicon only)" >&2
  exit 1
fi

if [[ -f "$LIB" && -f "$DEST/.version" ]] \
   && [[ "$(cat "$DEST/.version")" == "$VERSION" ]]; then
  echo "onnxruntime $VERSION already present"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching onnxruntime $VERSION"
curl -fsSL -o "$WORK/$ASSET" "$URL"

ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "checksum mismatch for $ASSET" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $ACTUAL" >&2
  exit 1
fi

tar xzf "$WORK/$ASSET" -C "$WORK"
SRC="$WORK/onnxruntime-osx-arm64-${VERSION}"
if [[ ! -f "$SRC/lib/libonnxruntime.${VERSION}.dylib" ]]; then
  echo "no dylib in $ASSET -- upstream layout changed" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"

# The real library under the plain name. The archive ships three names and a
# dSYM: on macOS the extra names are copies rather than symlinks, and the dSYM
# is 40MB of debug symbols nib does not ship.
cp "$SRC/lib/libonnxruntime.${VERSION}.dylib" "$LIB"

# The install name still says libonnxruntime.1.29.0.dylib, which is what a
# loader would go looking for. Rewritten so the bundled copy is found beside
# the app rather than somewhere on the build machine.
install_name_tool -id "@rpath/libonnxruntime.dylib" "$LIB"

# And re-signed, because the rewrite above invalidated the signature.
#
# install_name_tool says so in a warning that is easy to read past. The
# consequence is not a warning: dlopen is killed by the kernel with SIGKILL and
# "Code Signature Invalid", which arrives as a test process that vanishes with
# no error and no output.
codesign --force --sign - --timestamp=none "$LIB"

cp "$SRC/LICENSE" "$DEST/LICENSE"
cp "$SRC/ThirdPartyNotices.txt" "$DEST/ThirdPartyNotices.txt"

echo "$VERSION" > "$DEST/.version"
# Downloaded binaries carry a quarantine flag that blocks dlopen.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "  $(lipo -archs "$LIB")"
echo "  $(otool -D "$LIB" | tail -1)"
du -sh "$LIB" | awk '{print "  size: " $1}'
