cask "cursor-voice" do
  version "0.7.6"
  sha256 "329913bbe63afcd534858255e8a54fe7c41cff802cc7550064eb895b75a72306"

  url "https://github.com/cursorvoice/cursor-voice/releases/download/v#{version}/CursorVoice-#{version}.dmg"
  name "Cursor Voice"
  desc "Voice-driven macOS assistant powered by the OpenAI Realtime API"
  homepage "https://github.com/cursorvoice/cursor-voice"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "CursorVoice.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/CursorVoice.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/CursorVoice",
    "~/Library/Preferences/com.cursorvoice.app.plist",
    "~/Library/Caches/com.cursorvoice.app",
    "~/Library/HTTPStorages/com.cursorvoice.app",
    "~/Library/Saved Application State/com.cursorvoice.app.savedState",
  ]
end
