#!/usr/bin/env bash
# Download the prebuilt harper-ls binary into vendor/.
# Prebuilt because this machine has no Rust toolchain, and harper-ls is the
# grammar engine — we do not reimplement it.
set -euo pipefail

VERSION="${HARPER_VERSION:-2.8.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor"
ARCH="$(uname -m)"

case "$ARCH" in
  arm64) TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

URL="https://github.com/Automattic/harper/releases/download/v${VERSION}/harper-ls-${TRIPLE}.tar.gz"

mkdir -p "$DEST"
if [[ -x "$DEST/harper-ls" ]] && "$DEST/harper-ls" --version 2>/dev/null | grep -q "$VERSION"; then
  echo "harper-ls $VERSION already present"
  exit 0
fi

echo "fetching harper-ls $VERSION for $TRIPLE"
curl -fsSL -o "$DEST/harper-ls.tar.gz" "$URL"
tar -xzf "$DEST/harper-ls.tar.gz" -C "$DEST"
rm -f "$DEST/harper-ls.tar.gz"
chmod +x "$DEST/harper-ls"
# Downloaded binaries carry a quarantine flag that blocks exec.
xattr -d com.apple.quarantine "$DEST/harper-ls" 2>/dev/null || true

"$DEST/harper-ls" --version
