# Homebrew cask for the notarised Voice2Text menu-bar app. The repository is
# public, so the zip is a plain GitHub Release download. Homebrew 6 loads no
# third-party tap it has not been told to trust, hence the first line:
#   brew trust --tap lucharo/voice2text && brew trust --cask lucharo/voice2text/voice2text
#   brew tap lucharo/voice2text https://github.com/lucharo/voice2text.git
#   brew install --cask voice2text
# The app is only the native shell; the engine is `uv tool install voice2text`.
# `scripts/release-macos.sh --publish` rewrites version and sha256 on every
# release.
cask "voice2text" do
  version "0.5.9"
  sha256 "cd49a062c7ceceb8163c9abf5acf66a1740ee918cf36a4563407a582dda85c7b"

  url "https://github.com/lucharo/voice2text/releases/download/v#{version}/Voice2Text-#{version}.zip"
  name "Voice2Text"
  desc "Menu-bar app for v2t, local push-to-talk voice-to-text"
  homepage "https://github.com/lucharo/voice2text"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "Voice2Text.app"

  caveats <<~EOS
    Voice2Text.app is only the menu-bar shell. Install the engine once:
      uv tool install voice2text
    then start it from the menu bar and grant Microphone and Accessibility.
  EOS
end
