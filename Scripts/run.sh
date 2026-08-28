#!/usr/bin/env bash
# Restart the built app, with logging on.
#
# Exists because "pkill -x nib && open ..." silently does nothing when nib is
# not already running: pkill exits non-zero when it matches nothing, && skips
# the open, and neither command prints a word about it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/nib.app"

if [[ ! -d "$APP" ]]; then
  echo "no app at $APP -- run: swift build -c release && Scripts/bundle.sh" >&2
  exit 1
fi

pkill -x nib 2>/dev/null || true
sleep 1
open --env NIB_LOG=1 "$APP"
sleep 2

if ! pgrep -x nib >/dev/null; then
  echo "nib did not start. Try opening $APP from Finder for the error." >&2
  exit 1
fi

echo "nib running (pid $(pgrep -x nib))"
echo "log: ~/Library/Logs/nib.log"

# The Accessibility grant is bound to the code signature, so every rebuild
# invalidates it and nib comes up unable to see any text.
if head -1 ~/Library/Logs/nib.log 2>/dev/null | grep -q "trusted=false"; then
  echo
  echo "  NOT trusted for Accessibility -- approve the prompt, or:"
  echo "    System Settings > Privacy & Security > Accessibility"
fi
