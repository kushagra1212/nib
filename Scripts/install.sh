#!/usr/bin/env bash
# Build, install to /Applications, and leave exactly one nib on the machine.
#
#   Scripts/install.sh
#
# This exists because two copies of nib is a trap, not a convenience. macOS
# ties Accessibility permission to one specific app, identified by its code
# signature. With a build in dist/ and another in /Applications, launching the
# wrong one gives a nib that is listed and switched on in System Settings and
# still cannot read anything -- and the only visible symptom is the menu
# saying "Not working" for no apparent reason.
#
# That happened repeatedly during development: dist/nib.app was launched to
# look at the interface and never put back, so the granted copy was not the
# running one. The fix is not to be more careful. It is to not have a second
# copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="$ROOT/dist/nib.app"
INSTALLED="/Applications/nib.app"

if [[ ! -d "$BUILT" ]]; then
  echo "nothing to install -- run: Scripts/bundle.sh" >&2
  exit 1
fi

# What the grant is currently attached to, before anything moves.
previous=""
if [[ -d "$INSTALLED" ]]; then
  previous="$(codesign -dvvv "$INSTALLED" 2>&1 | awk -F= '/CDHash/ {print $2; exit}')"
fi
incoming="$(codesign -dvvv "$BUILT" 2>&1 | awk -F= '/CDHash/ {print $2; exit}')"

if pgrep -x nib >/dev/null; then
  pkill -x nib || true
  sleep 1
fi

rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"
# Homebrew and browsers both attach this, and Gatekeeper refuses an app that
# carries it because nib is not notarised.
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true

# The second copy goes. Anything that can be launched by accident eventually
# will be, and the failure it produces looks like a permissions bug rather
# than the wrong binary.
rm -rf "$BUILT"

open "$INSTALLED"
echo "installed $INSTALLED"
echo "  dist/nib.app removed -- there is now one nib"

if [[ -n "$previous" && "$previous" != "$incoming" ]]; then
  echo
  echo "  The code signature changed, so the Accessibility grant no longer"
  echo "  matches. macOS will leave nib switched on in System Settings while"
  echo "  it does nothing, which is not a state you can toggle your way out"
  echo "  of. Clear it and approve once:"
  echo
  echo "    tccutil reset Accessibility com.kushagra.nib"
  echo
  echo "  Signing with a real certificate is what ends this: the requirement"
  echo "  becomes the identity rather than the hash, and survives rebuilds."
fi
