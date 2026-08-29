#!/usr/bin/env bash
# Download llama-server and the libraries it loads into vendor/llama/.
#
# nib bundles this so the rewrite buttons work on a machine that has never
# heard of llama.cpp. Without it the user installs nib, presses Fix, and gets
# nothing -- the model is only half of what that button needs.
#
# The download is a mirror on nib's own releases, not upstream. llama.cpp keeps
# only about a hundred nightly builds, roughly nine days, so a pinned upstream
# URL stops resolving long before we stop shipping the version it points at.
# The mirrored tarball is byte-identical to upstream's; the release notes on
# llama-runtime-b10400 record where it came from and its checksum there.
#
# Why b10400 and not something newer: the RPC backend in b10679 and its
# neighbours links /usr/lib/librdma.dylib, which does not exist on macOS 15, so
# llama-server dies in dyld before main(). b10400 runs from a directory of its
# own with nothing but system frameworks behind it.
set -euo pipefail

BUILD="${LLAMA_BUILD:-b10400}"
SHA256="bb0172e886c7b6ece52edf04db03bc692ffc28e096728351c0343e4c75bb5374"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor/llama"
ARCH="$(uname -m)"

if [[ "$ARCH" != "arm64" ]]; then
  echo "unsupported arch: $ARCH (nib ships Apple silicon only)" >&2
  exit 1
fi

ASSET="llama-${BUILD}-bin-macos-arm64.tar.gz"
URL="https://github.com/kushagra1212/nib/releases/download/llama-runtime-${BUILD}/${ASSET}"

if [[ -x "$DEST/llama-server" ]] \
   && "$DEST/llama-server" --version 2>&1 | grep -q "build ${BUILD#b}"; then
  echo "llama-server $BUILD already present"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching llama-server $BUILD"
curl -fsSL -o "$WORK/$ASSET" "$URL"

# The checksum is the only thing standing between a redirected download and a
# binary we hand a code signature to.
ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "checksum mismatch for $ASSET" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $ACTUAL" >&2
  exit 1
fi

mkdir -p "$WORK/x"
tar -xzf "$WORK/$ASSET" -C "$WORK/x" --strip-components=1

# Take llama-server and the libraries it actually reaches, not the whole
# tarball: that is 61 files and most of them are other command-line tools.
#
# Walked with otool rather than listed by hand. A hand-written list is right
# until the day a build adds a dependency, and then it is wrong in the form of
# a dyld error on somebody else's machine.
python3 - "$WORK/x" "$DEST" <<'PY'
import os, re, shutil, subprocess, sys

src, dest = sys.argv[1], sys.argv[2]
seen, todo = set(), ["llama-server"]
while todo:
    name = todo.pop()
    if name in seen:
        continue
    seen.add(name)
    out = subprocess.run(["otool", "-L", os.path.join(src, name)],
                         capture_output=True, text=True).stdout
    for line in out.splitlines()[1:]:
        m = re.match(r"\s+@rpath/(\S+)", line)
        if m and os.path.exists(os.path.join(src, m.group(1))):
            todo.append(m.group(1))

os.makedirs(dest, exist_ok=True)
for stale in os.listdir(dest):
    os.remove(os.path.join(dest, stale))

total = 0
for name in sorted(seen):
    # copy2 follows the symlink and writes a real file under the linked-to
    # name, which is the name the loader asks for.
    shutil.copy2(os.path.join(src, name), os.path.join(dest, name))
    total += os.path.getsize(os.path.join(dest, name))
shutil.copy2(os.path.join(src, "LICENSE"), os.path.join(dest, "LICENSE"))
print(f"  {len(seen)} files, {total / 1e6:.1f} MB")
PY

chmod +x "$DEST/llama-server"
# Downloaded binaries carry a quarantine flag that blocks exec.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Prove it loads its libraries from beside itself. llama-server links them
# through @rpath with an rpath of @loader_path, so this works anywhere the
# directory is copied to -- including inside the app bundle.
"$DEST/llama-server" --version 2>&1 | head -1
