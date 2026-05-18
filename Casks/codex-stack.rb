cask "codex-stack" do
  version "0.0.7"
  sha256 "7c130ad8121cc83e8b1fe515ee504066a1c292369c584b885843e2e8533186dc"

  url "https://github.com/ocd0711/CodexStack/releases/download/v#{version}/codexStack-v#{version}-macos.zip"
  name "codexStack"
  desc "Native macOS menu bar app for managing local Codex sessions"
  homepage "https://github.com/ocd0711/CodexStack"

  livecheck do
    url "https://github.com/ocd0711/CodexStack"
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "codexStack.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/codexStack.app"],
                   sudo: false,
                   must_succeed: false,
                   print_stdout: false,
                   print_stderr: false
  end

  uninstall quit: "dev.codexstack.app"

  zap trash: [
    "~/Library/Preferences/dev.codexstack.app.plist",
    "~/Library/Saved Application State/dev.codexstack.app.savedState",
  ]
end
