cask "tend" do
  version "0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/schaffernation/tend/releases/download/v#{version}/Tend-#{version}.dmg"
  name "Tend"
  desc "Restores and manages long-running tmux sessions"
  homepage "https://tend.schaffernation.com"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on formula: "tmux"
  depends_on macos: :sonoma

  app "Tend.app"
  binary "#{appdir}/Tend.app/Contents/Resources/tend"

  uninstall quit: "com.schaffernation.tend"

  # Keeps ~/.config/tend, the session list you made.
  zap trash: [
    "~/Library/Caches/com.schaffernation.tend",
    "~/Library/HTTPStorages/com.schaffernation.tend",
    "~/Library/Preferences/com.schaffernation.tend.plist",
    "~/Library/Saved Application State/com.schaffernation.tend.savedState",
  ]
end
