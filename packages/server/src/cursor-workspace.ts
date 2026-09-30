import { stat } from "node:fs/promises";
import path from "node:path";
import { runProcess } from "./machine.js";

/** Cursor's document handler opens/focuses the workspace, not a specific Agent chat. */
export async function openCursorWorkspace(cwd: string): Promise<void> {
  if (!path.isAbsolute(cwd) || cwd === "/" || cwd.includes("\0")) {
    throw new Error("This Cursor session has no workspace to open.");
  }
  if (!await stat(cwd).then(value => value.isDirectory(), () => false)) {
    throw new Error("This Cursor workspace is no longer available. You can still view its chat history in Agent Visor.");
  }
  // Use a document-open event with an explicit bundle ID. No prompt, shell,
  // --reuse-window, or guessed conversation URL is sent to Cursor.
  const opened = await runProcess("/usr/bin/open", ["-b", "com.todesktop.230313mzl4w4u92", cwd], {
    deadlineMs: 5_000, maxOutputBytes: 4_096,
  });
  if (opened.status !== "success") throw new Error("Cursor could not open this workspace.");
}
