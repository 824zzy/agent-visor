cask "agent-visor" do
  version "2.4.8"
  sha256 "9e1e7b4c4a5a85dfdf902db070ccf49a95a0a6e04470133dd89ebe02a9792f74"

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

  # Public releases use the pinned AgentVisor Release certificate. Remove
  # quarantine while preserving the distributed signature so macOS keeps the
  # same Accessibility identity across ordinary updates.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Agent Visor.app"]
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
