cask "agent-visor" do
  version "2.4.7"
  sha256 "29879067af632d04adffd312107a75da3fd29aa15027e2645adf8f2378358734"

  url "https://github.com/824zzy/agent-visor/releases/download/v#{version}/AgentVisor-v#{version}.zip"
  name "Agent Visor"
  desc "Monitor and return to coding-agent sessions from the menu bar"
  homepage "https://github.com/824zzy/agent-visor"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Agent Visor.app"

  # Version 2.4.7 is the one-time ad-hoc updater bridge. Preserve the historical
  # install behavior for this release; 2.4.8 switches to the stable release
  # identity and removes this re-signing step.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Agent Visor.app"]
    system_command "/usr/bin/codesign",
                   args: ["--force", "--deep", "--sign", "-",
                          "--preserve-metadata=entitlements,flags",
                          "#{appdir}/Agent Visor.app"]
  end

  # The hook file at ~/.claude/hooks/agent-visor-state.py is deliberately
  # excluded from zap. It lives in Claude Code's shared hooks directory
  # alongside other tools' hooks, and removing it would require surgically
  # editing settings.json which is also shared. Users who want to fully
  # remove the hook should delete the file manually and clean up any
  # agent-visor-state.py entries in ~/.claude/settings.json.
  zap trash: [
    "~/Library/Application Support/agent-visor",
    "~/Library/Caches/com.824zzy.AgentVisor",
    "~/Library/HTTPStorages/com.824zzy.AgentVisor",
    "~/Library/Logs/AgentVisor",
    "~/Library/Preferences/com.824zzy.AgentVisor.plist",
  ]

  caveats <<~EOS
    On macOS 15 Sequoia or later, Agent Visor needs Full Disk Access to read
    coding-agent session transcripts in ~/.claude/projects/, ~/.codex/, and
    ~/.cursor/projects/. Without it the sidebar stays empty with no error.

      System Settings → Privacy & Security → Full Disk Access → add Agent Visor.

    Accessibility is also required (Agent Visor prompts for it on first launch).
  EOS
end
