cask "cursor-voice" do
  version "0.8.0.5"
  sha256 "db6dc5ec111774979aa55378ba2fb33903eaf70d059189e8b4c712bd1b6ca1a1"

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
