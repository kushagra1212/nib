#!/usr/bin/env bash
# Download espeak-ng into vendor/espeak/.
#
# The phonemiser: it turns "quick" into kwˈɪk, which is what Kokoro is actually
# fed. No phonemiser, no speech -- the model has never seen a letter.
#
# Taken from the espeakng-loader wheel rather than built from source. That is
# the same binary the working Python setup runs, which matters: nib's phoneme
# fixtures were captured from espeak-ng 1.52.0 as shipped in this wheel, and a
# build with different dictionaries would phonemise differently while passing
# every test that does not load it.
#
# espeak-ng is GPL-3.0. So is nib, for this reason.
set -euo pipefail

VERSION="${ESPEAK_LOADER_VERSION:-0.2.4}"
WHEEL="espeakng_loader-${VERSION}-py3-none-macosx_11_0_arm64.whl"
URL="https://files.pythonhosted.org/packages/a8/26/258c0cd43b9bc1043301c5f61767d6a6c3b679df82790c9cb43a3277b865/${WHEEL}"
SHA256="d27cdca31112226e7299d8562e889d3e38a1e48055c9ee381b45d669072ee59f"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor/espeak"
LIB="$DEST/libespeak-ng.dylib"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "unsupported arch: $(uname -m) (nib ships Apple silicon only)" >&2
  exit 1
fi

if [[ -f "$LIB" && -d "$DEST/espeak-ng-data" ]] \
   && [[ -f "$DEST/.version" ]] \
   && [[ "$(cat "$DEST/.version")" == "$VERSION" ]]; then
  echo "espeak-ng $VERSION already present"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching espeakng-loader $VERSION"
curl -fsSL -o "$WORK/$WHEEL" "$URL"

ACTUAL="$(shasum -a 256 "$WORK/$WHEEL" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "checksum mismatch for $WHEEL" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $ACTUAL" >&2
  exit 1
fi

# A wheel is a zip.
unzip -q "$WORK/$WHEEL" -d "$WORK/x"
SRC="$WORK/x/espeakng_loader"
if [[ ! -f "$SRC/libespeak-ng.dylib" || ! -d "$SRC/espeak-ng-data" ]]; then
  echo "no dylib or data in $WHEEL -- upstream layout changed" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"

# One dylib, not the three. The wheel ships libespeak-ng.dylib alongside the
# versioned .1 and .1.52.0 names, which on macOS are copies rather than
# symlinks -- 9MB of the same library three times over.
cp "$SRC/libespeak-ng.dylib" "$LIB"
cp -R "$SRC/espeak-ng-data" "$DEST/espeak-ng-data"

# The licence travels with the binary, which GPL-3.0 requires and nib's own
# licence page lists.
for name in COPYING LICENSE LICENSE.txt; do
  [[ -f "$SRC/$name" ]] && cp "$SRC/$name" "$DEST/" && break
done

echo "$VERSION" > "$DEST/.version"
# Downloaded binaries carry a quarantine flag that blocks dlopen.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "  $(lipo -archs "$LIB")"
echo "  $(nm -gU "$LIB" | grep -c '_espeak_') espeak symbols"
du -sh "$LIB" | awk '{print "  library: " $1}'
du -sh "$DEST/espeak-ng-data" | awk '{print "  data:    " $1}'
