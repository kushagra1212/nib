#!/usr/bin/env bash
# Assemble dist/nib.app from the SwiftPM build.
#
# A real bundle is not optional: macOS ties Accessibility permission to a
# bundle identity and code signature, and a bare executable re-prompts or
# silently fails to hold the grant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/nib.app"
BIN="$ROOT/.build/$CONFIG/nib"

if [[ ! -x "$BIN" ]]; then
  echo "no binary at $BIN -- run: swift build -c $CONFIG" >&2
  exit 1
fi

# Refuse to bundle a binary older than the sources.
#
# `swift build` defaults to debug while this script reads release, so building
# and then bundling silently ships whatever was in .build/release from before.
# A whole afternoon went into debugging behaviour that was never in the app.
NEWEST_SOURCE="$(find "$ROOT/Sources" -name '*.swift' -newer "$BIN" -print -quit)"
if [[ -n "$NEWEST_SOURCE" ]]; then
  echo "STALE: $BIN predates $(basename "$NEWEST_SOURCE")" >&2
  echo "  run: swift build -c $CONFIG" >&2
  exit 1
fi
if [[ ! -x "$ROOT/vendor/harper-ls" ]]; then
  echo "harper-ls missing -- run: Scripts/fetch-harper.sh" >&2
  exit 1
fi
if [[ ! -x "$ROOT/vendor/llama/llama-server" ]]; then
  echo "llama-server missing -- run: Scripts/fetch-llama.sh" >&2
  exit 1
fi
WHISPER="$ROOT/vendor/whisper/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
if [[ ! -d "$WHISPER" ]]; then
  echo "whisper.xcframework missing -- run: Scripts/fetch-whisper.sh" >&2
  exit 1
fi

# Stop it before deleting the bundle it is running from.
#
# rm -rf on a live .app does not stop the process, it removes the ground from
# under it: the app stays in the menu bar until it next touches a resource and
# then quits, or simply disappears with no message. Looking for a crash after
# that finds nothing, because there wasn't one.
if pgrep -x nib >/dev/null; then
  echo "  stopping the running nib first"
  pkill -x nib || true
  sleep 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/nib"

# The speech engine is a linked framework, not a subprocess, so it goes in
# Contents/Frameworks where macOS expects one.
#
# The binary asks for it as @rpath/whisper.framework/... and is built with an
# rpath of @loader_path -- correct in .build/release, where SwiftPM puts the
# framework beside the executable, and wrong in a bundle, where the executable
# is one directory deeper than Frameworks. The extra rpath is added here rather
# than at link time so Package.swift stays free of unsafeFlags.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$WHISPER" "$APP/Contents/Frameworks/whisper.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/nib" 2>/dev/null || true
cp "$ROOT/vendor/harper-ls" "$APP/Contents/Resources/harper-ls"

# Apache-2.0 section 4 requires shipping the licence with the binary, and
# harper-ls is Apache-2.0. Both licences travel inside the app, not only in
# the repository, because the app is what people actually receive.
cp "$ROOT/THIRD-PARTY-LICENSES.txt" "$APP/Contents/Resources/THIRD-PARTY-LICENSES.txt"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

# llama-server and its libraries, kept together in one directory.
#
# They have to stay together: llama-server finds the libraries through an
# rpath of @loader_path, which means "beside me". Move the binary out on its
# own and it fails in dyld before it reaches main().
cp -R "$ROOT/vendor/llama" "$APP/Contents/Resources/llama"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  no icon; run: swift Scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns"
fi

# Runs codesign with a deadline, reporting which way it ended.
#
# macOS ships no `timeout`, so the signing runs in the background with a
# watchdog beside it. Sets SIGN_FAILURE to whichever happened, because "it was
# refused" and "it never answered" call for different fixes: the first is a
# certificate problem, the second is a keychain waiting on a human.
sign_with_timeout () { # seconds identity app
  local seconds="$1" identity="$2" app="$3"
  codesign --force --deep --sign "$identity" "$app" 2>/dev/null &
  local signer=$!

  ( sleep "$seconds"; kill -TERM "$signer" 2>/dev/null ) &
  local watchdog=$!

  if wait "$signer" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return 0
  fi

  # Killed by the watchdog, or exited on its own with an error.
  if kill -0 "$watchdog" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null || true
    SIGN_FAILURE="identity refused"
  else
    SIGN_FAILURE="keychain did not answer in ${seconds}s"
  fi
  wait "$watchdog" 2>/dev/null || true
  return 1
}

# Sign with a real identity when the machine has one.
#
# An ad-hoc signature ("-") has no identity behind it, so macOS derives the
# designated requirement from the binary's own hash. Every rebuild changes that
# hash, the Accessibility grant no longer matches, and nib comes up blind while
# still listed and switched on in System Settings -- the toggle does nothing,
# because the entry points at a binary that no longer exists.
#
# A certificate makes the requirement "this bundle id, signed by this identity",
# which does not change when the code does. That is why ordinary apps keep their
# permissions across updates.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development|Developer ID Application/ { print $2; exit }'
)}"

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Bounded, because this can block forever rather than fail.
  #
  # Signing with a real identity needs the private key, and the keychain asks
  # permission for that with a dialog. Where no dialog can appear -- a CI
  # runner, a locked keychain, an editor's terminal -- codesign sits waiting
  # for an answer that will never come. It hung a build here for fifteen
  # minutes before anyone looked at the process list.
  #
  # Twenty seconds is far longer than signing takes when it is going to work.
  if sign_with_timeout 20 "$SIGN_IDENTITY" "$APP"; then
    SIGNED_WITH="identity $SIGN_IDENTITY"
  else
    codesign --force --deep --sign - "$APP" 2>/dev/null
    SIGNED_WITH="ad-hoc ($SIGN_FAILURE)"
  fi
else
  codesign --force --deep --sign - "$APP" 2>/dev/null
  SIGNED_WITH="ad-hoc (no certificate found)"
fi

echo "built $APP"
du -sh "$APP" | awk '{print "  size: " $1}'

# The failure this avoids is genuinely confusing: nib stays listed and switched
# on in Accessibility, but is no longer trusted, because the grant points at the
# previous binary. Toggling it does nothing; the entry has to be cleared.
if pgrep -x nib >/dev/null; then
  echo
  echo "  nib is running the OLD build. Restart it:"
  echo "    pkill -x nib && open $APP"
fi
echo "  signed: $SIGNED_WITH"

if [[ "$SIGNED_WITH" == ad-hoc* ]]; then
  echo
  echo "  Ad-hoc signed, so any existing Accessibility grant is now stale."
  echo "  Toggling nib in System Settings will not help -- clear it:"
  echo "    tccutil reset Accessibility com.kushagra.nib"
fi
