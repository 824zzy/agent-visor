import { constants } from "node:fs";
import { access, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { runProcess } from "./machine.js";

export type ClaudeBackgroundTarget = {
  jobId: string;
  cwd: string;
  executable: string;
  application: "Ghostty" | "iTerm2" | "Terminal";
};

/** Shell command used by the Terminal launch boundary. */
export function claudeAttachCommand(target: ClaudeBackgroundTarget): string {
  // Enables the client's own titles; an existing worker keeps its launch state.
  return `/usr/bin/env -u CLAUDE_CODE_DISABLE_TERMINAL_TITLE ${shellQuote(target.executable)} attach ${shellQuote(target.jobId)}`;
}

/**
 * Open the exact Claude background job in a new Terminal.app window, leaving
 * its daemon running. Ghostty windows are opened by the native helper instead.
 */
export async function openClaudeBackgroundSession(target: ClaudeBackgroundTarget): Promise<void> {
  if (!/^[0-9a-f]{8}$/i.test(target.jobId)
    || !path.isAbsolute(target.cwd) || !path.isAbsolute(target.executable)) {
    throw new Error("The Claude background session has no valid attach route.");
  }
  if (!(await stat(target.cwd)).isDirectory()) throw new Error("The Claude project directory is unavailable.");
  await access(target.executable, constants.X_OK);

  // Terminal accepts a .command file without Apple Events permission. Keep
  // every value shell-quoted and have the script remove itself when it starts.
  const directory = await mkdtemp(path.join(os.tmpdir(), "agent-visor-claude-attach-"));
  const script = path.join(directory, "attach.command");
  try {
    await writeFile(script, [
      "#!/bin/zsh",
      'rm -f "$0"',
      'rmdir "$(dirname "$0")" 2>/dev/null || true',
      `cd ${shellQuote(target.cwd)} || exit 1`,
      `exec ${claudeAttachCommand(target)}`,
      "",
    ].join("\n"), { mode: 0o700, flag: "wx" });
    const opened = await runProcess("/usr/bin/open", ["-a", "Terminal.app", script], {
      deadlineMs: 5_000, maxOutputBytes: 4_096,
    });
    if (opened.status !== "success") throw new Error("The terminal could not open the Claude background session.");
  } catch (error) {
    await rm(directory, { recursive: true, force: true });
    throw error;
  }
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
