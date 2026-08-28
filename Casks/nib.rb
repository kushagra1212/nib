# Homebrew cask for nib.
#
# Copy this into a tap repository named homebrew-tap, at Casks/nib.rb, so users
# can run:
#
#   brew install --cask kushagra1212/tap/nib
#
# Homebrew clears the quarantine flag on install, which is why this route does
# not hit the "nib is damaged" warning that a hand-installed DMG does.
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
  depends_on macos: ">= :ventura"

  app "nib.app"

  uninstall quit: "com.kushagra.nib"

  zap trash: [
    "~/Library/Application Support/nib",
    "~/Library/Preferences/com.kushagra.nib.plist",
  ]

  caveats <<~EOS
    nib needs Accessibility permission to read the text you are editing.
    Approve it in System Settings > Privacy & Security > Accessibility,
    then launch nib again.

    AI rewrite is optional and off until you add a model. See:
      https://github.com/kushagra1212/nib#ai-rewrite-optional
  EOS
end
