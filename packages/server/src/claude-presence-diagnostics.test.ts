import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { expect, it } from "vitest";
import { ClaudePresenceDiagnostics } from "./claude-presence-diagnostics.js";

it("records presence changes privately without free-form data or unchanged polling noise", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-presence-"));
  try {
    const diagnostics = new ClaudePresenceDiagnostics(root);
    const report = {
      status: "read_failed" as const, parkedApplications: 1, terminalViews: 0,
      conversationTitles: 0, overviewTitles: 0, unrecognizedTitles: 0, matchedConversations: 0,
      title: "secret title", cwd: "/secret/path", error: "secret credential",
    };
    diagnostics.record(report);
    diagnostics.record(report);
    diagnostics.record({ ...report, status: "read_succeeded", terminalViews: 1, conversationTitles: 1, matchedConversations: 1 });
    await diagnostics.flush();
    const file = path.join(root, "diagnostics/claude-presence.jsonl");
    const content = await readFile(file, "utf8");
    const rows = content.trim().split("\n").map(line => JSON.parse(line));
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatchObject({ status: "read_failed", matchedConversations: 0 });
    expect(rows[1]).toMatchObject({ status: "read_succeeded", matchedConversations: 1 });
    expect(content).not.toMatch(/secret|title|cwd|error/);
    expect((await stat(file)).mode & 0o777).toBe(0o600);
  } finally { await rm(root, { recursive: true, force: true }); }
});
