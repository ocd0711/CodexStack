cask "codex-stack" do
  version "0.0.8"
  sha256 "36e12d76b04d6277497d152197a0e63926b5df66573ad8e7b9b56a259063e395"

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
