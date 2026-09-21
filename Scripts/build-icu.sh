#!/usr/bin/env bash
# Build ICU into macos/vendor/icu/.
#
# Built rather than fetched, which is the odd one out among these scripts, and
# the reason is the deployment target. Homebrew's icu4c@78 is compiled for
# macOS 15, nib supports Ventura 13, and a dylib built for a newer system links
# without complaint here and refuses to load there. There is no prebuilt ICU
# for macOS 13 to download, so this makes one.
#
# The version matches what docker/core-cross.Dockerfile builds for Windows.
# Sentence segmentation is ICU's, so two ICU versions would mean the two
# platforms disagreeing about where sentences end -- which is the drift the
# shared core exists to prevent. Change one and change the other.
#
# Static, unlike the Windows build. There the static route loses ICU's data to
# a stub, because --enable-static needs --disable-tools to link and pkgdata is
# one of the tools. That is a cross-compilation problem: building natively here
# keeps the tools, so the data is real. Static also means nib.app carries no
# loose ICU dylibs to copy, re-path and sign.
#
# ICU is under the Unicode licence, which is permissive and already listed in
# THIRD-PARTY-LICENSES.txt.
set -euo pipefail

VERSION="${ICU_VERSION:-78.3}"
ASSET="icu4c-${VERSION}-sources.tgz"
URL="https://github.com/unicode-org/icu/releases/download/release-${VERSION}/${ASSET}"
# nib supports Ventura. Passed to every compile and link, not just configure,
# because ICU's makefiles do not thread a single flag through on their own.
MIN_MACOS="13.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS="$ROOT/macos"
DEST="$MACOS/vendor/icu"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-icu.sh builds the macOS copy; Windows ICU is built by" >&2
  echo "docker/core-cross.Dockerfile" >&2
  exit 1
fi

if [[ -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$VERSION" ]] \
   && [[ -f "$DEST/lib/libicuuc.a" ]]; then
  echo "ICU $VERSION already built"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching ICU $VERSION"
curl -fsSL -o "$WORK/$ASSET" "$URL"

tar -xzf "$WORK/$ASSET" -C "$WORK"

mkdir -p "$WORK/build"
cd "$WORK/build"

echo "configuring for macOS $MIN_MACOS"
"$WORK/icu/source/configure" \
  --prefix="$DEST" \
  --enable-static --disable-shared \
  --disable-tests --disable-samples --disable-extras \
  CFLAGS="-mmacosx-version-min=$MIN_MACOS -O2" \
  CXXFLAGS="-mmacosx-version-min=$MIN_MACOS -O2" \
  LDFLAGS="-mmacosx-version-min=$MIN_MACOS" \
  >/dev/null

echo "building (this takes a few minutes)"
make -j"$(sysctl -n hw.ncpu)" >/dev/null
rm -rf "$DEST"
make install >/dev/null

# Refuse a stub.
#
# When ICU cannot run pkgdata it substitutes stubdata and says nothing: the
# libraries link, the build reports success, and every break iterator comes up
# empty at runtime. The real data library is tens of megabytes; the stub is
# under a kilobyte. Measured here so the failure is this script's rather than a
# user's.
DATA="$DEST/lib/libicudata.a"
if [[ ! -f "$DATA" ]]; then
  echo "no libicudata.a -- the install did not complete" >&2
  exit 1
fi
SIZE="$(stat -f%z "$DATA")"
if (( SIZE < 20000000 )); then
  echo "libicudata.a is only $SIZE bytes, so this is stub data rather than" >&2
  echo "ICU's. pkgdata did not run. The core would load with no" >&2
  echo "break-iterator rules and fail only when asked to split a sentence." >&2
  exit 1
fi

echo "$VERSION" > "$DEST/.version"
echo "ICU $VERSION built for macOS $MIN_MACOS ($(( SIZE / 1024 / 1024 ))MB of data)"
