# Homebrew cask for nib. This file is the source; the copy Homebrew reads
# lives in kushagra1212/homebrew-tap and is written by the release workflow.
#
#   brew install --cask kushagra1212/tap/nib
#   xattr -dr com.apple.quarantine /Applications/nib.app
#
# Edit this file, not the one in the tap: the next release overwrites that one.
# The version and sha256 below are placeholders and are replaced with the real
# ones at release time, so they will look stale here. That is expected.
#
# The second line is not optional. Homebrew attaches the quarantine attribute
# like any other download, and nib is not notarised, so Gatekeeper refuses to
# open it and offers only "Move to Trash" -- which deletes the app while brew
# still records it as installed.
#
# Measured on Homebrew 6.0.20: --no-quarantine is not accepted by `install` or
# `reinstall`, so there is no flag to avoid this. Clearing the attribute
# afterwards is the only route.
#
# This cask does not strip it in a postflight. That would work, and it would
# disable Gatekeeper for the user without telling them, which is not a decision
# an install script should make on someone's behalf.
cask "nib" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_THE_RELEASE"

  url "https://github.com/kushagra1212/nib/releases/download/v#{version}/nib-#{version}.dmg"
  name "nib"
  desc "Offline writing assistant for macOS"
  homepage "https://github.com/kushagra1212/nib"

  # arm64 only: harper-ls ships an Apple silicon binary and the app is built
  # for arm64.
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "nib.app"

  uninstall quit: "com.kushagra.nib"

  zap trash: [
    "~/Library/Application Support/nib",
    "~/Library/Preferences/com.kushagra.nib.plist",
  ]

  caveats <<~EOS
    If nib will not open and macOS says it cannot be verified, it was
    installed with the quarantine flag. Clear it:
      xattr -dr com.apple.quarantine /Applications/nib.app

    nib needs Accessibility permission to read the text you are editing.
    Approve it in System Settings > Privacy & Security > Accessibility,
    then launch nib again.

    AI rewrite is optional and off until you add a .gguf model to
    ~/Library/Application Support/nib/models -- the engine that runs it
    is already inside the app. See:
      https://github.com/kushagra1212/nib#ai-rewrite-optional
  EOS
end
