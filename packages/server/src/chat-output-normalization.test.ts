import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { parseChatLines, readChatPage } from "./chat.js";

const citation = "<oai-mem-citation>\n<citation_entries>\nMEMORY.md:1-2|note=[prior context]\n</citation_entries>\n<rollout_ids>\n00000000-0000-4000-8000-000000000001\n</rollout_ids>\n</oai-mem-citation>";
const answer = "The answer.\n\nSources: [documentation](https://example.com/docs).";
const codex = (text: string, role = "assistant") => JSON.stringify({
  type: "response_item", timestamp: "2026-09-02T10:00:00Z",
  payload: { type: "message", id: "answer", role, content: [{ type: role === "user" ? "input_text" : "output_text", text }] },
});
const assistantText = (text: string) => parseChatLines("codex", [codex(text)])[0];

describe("assistant metadata at the provider boundary", () => {
  it.each([
    `${answer}\n\n${citation}`,
    `${answer} ${citation}`,
    `${answer}\n${citation}\n${citation}\n `,
    `${answer}\n${citation.replaceAll("\n", "\r\n")}`,
  ])("removes a recognized citation trailer without changing the answer or sources", (body) => {
    expect(assistantText(body)).toEqual({ id: "answer", kind: "assistant", text: answer, timestamp: "2026-09-02T10:00:00.000Z" });
  });

  it("preserves prose following a complete metadata block", () => {
    expect(assistantText(`Before.\n\n${citation}\n\nAfter.`)).toMatchObject({ text: "Before.\n\nAfter." });
  });

  it("does not flash a citation trailer while it is being written", () => {
    for (let length = "<oai-mem-citation>".length; length <= citation.length; length += 1) {
      expect(assistantText(`${answer}\n\n${citation.slice(0, length)}`), `prefix ${length}`).toMatchObject({ text: answer });
    }
  });

  it.each([
    `Explain \`${citation}\` literally.`,
    `Example:\n\`\`\`xml\n${citation}\n\`\`\``,
    `Example:\n~~~~xml\n${citation}\n~~~~`,
    citation.split("\n").map((line) => `> ${line}`).join("\n"),
    citation.split("\n").map((line) => `    ${line}`).join("\n"),
    "Mention `<oai-mem-citation>` without deleting the rest of the answer.",
    "An unknown <custom_metadata>value</custom_metadata> stays literal.",
    "<oai-mem-citation>This is an authored example, not citation metadata.</oai-mem-citation>",
    "<oai-mem-citation>unfinished authored example",
    "<oai-mem-citation><citation_entries>not a source row</citation_entries><rollout_ids>not an id</rollout_ids></oai-mem-citation>",
  ])("preserves quoted, unknown, and malformed content", (body) => {
    expect(assistantText(body)).toMatchObject({ text: body });
  });

  it("preserves a fenced example and removes only the real trailer after it", () => {
    const body = `Example:\n\`\`\`xml\n${citation}\n\`\`\``;
    expect(assistantText(`${body}\n\n${citation}`)).toMatchObject({ text: body });
  });

  it("handles citation sections split across provider content blocks", () => {
    const row = JSON.parse(codex(answer));
    row.payload.content.push({ type: "output_text", text: citation });
    expect(parseChatLines("codex", [JSON.stringify(row)])[0]).toMatchObject({ text: answer });
  });

  it("does not create an empty assistant item for metadata-only output", () => {
    expect(assistantText(citation)).toBeUndefined();
  });

  it("keeps a user-authored citation example and delivery identity intact", () => {
    expect(parseChatLines("codex", [codex(citation, "user")])[0]).toMatchObject({ kind: "user", text: citation });
  });

  it("presents a Codex inbox summary without its native directive syntax", () => {
    expect(assistantText('All done.\n\n::inbox-item{title="Checks passed" summary="Ready for review"}')).toMatchObject({ text: "All done.\n\n**Checks passed**\n\nReady for review" });
  });
  it("presents code-review findings and their location without executing a directive", () => {
    expect(assistantText('::code-comment{title="[P2] Missing guard" body="Validate the input." file="/tmp/app.ts" start=4 end=6 priority=2}')).toMatchObject({ text: "**[P2] Missing guard**\n\nValidate the input.\n\nLocation: /tmp/app.ts:4-6\nPriority: 2" });
  });
  it.each([
    '```\n::inbox-item{title="Example" summary="Keep this syntax"}\n```',
    'Explain `::inbox-item{title="Example" summary="Keep this syntax"}`.',
    '::inbox-item{title="Incomplete"}',
    '::inbox-item{title="One" title="Two" summary="Ambiguous"}',
    '::inbox-item{title="Unknown field" summary="Keep" action="delete"}',
    '::code-comment{title="Example" body="Keep" file="/tmp/a" start=-1}',
    '::unknown-action{action="delete"}',
  ])("preserves ambiguous, quoted, and unsupported directives", (body) => {
    expect(assistantText(body)).toMatchObject({ text: body });
  });

  it.each(["claude_code", "pi", "cursor"] as const)("does not apply Codex rules to %s assistant output", (provider) => {
    const row = { type: "message", role: "assistant", message: { role: "assistant", content: [{ type: "text", text: citation }] } };
    expect(parseChatLines(provider, [JSON.stringify(row)])[0]).toMatchObject({ kind: "assistant", text: citation });
  });

  it("normalizes a subagent result before it reaches activity accessibility", () => {
    const row = JSON.parse(codex("", "user"));
    row.payload.content[0].text = `<subagent_notification>${JSON.stringify({ status: { completed: `${answer}\n${citation}` } })}</subagent_notification>`;
    row.payload.internal_chat_message_metadata_passthrough = { content_item_kinds: ["multi_agent.subagent_notification"] };
    expect(parseChatLines("codex", [JSON.stringify(row)])[0]).toMatchObject({ kind: "activity", text: answer });
  });

  it("normalizes delegation output but preserves a delegated input example", () => {
    expect(parseChatLines("codex", [codex(`<codex_delegation><output>${answer}\n${citation}</output></codex_delegation>`, "user")])[0]).toMatchObject({ kind: "activity", text: answer });
    expect(parseChatLines("codex", [codex(`<codex_delegation><input>${citation}</input></codex_delegation>`, "user")])[0]).toMatchObject({ kind: "activity", text: citation });
  });

  it("keeps metadata-only pages out of visible paging and user evidence", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "visor-citation-page-"));
    try {
      const file = path.join(root, "transcript.jsonl");
      await writeFile(file, [codex(answer), codex(citation)].join("\n") + "\n");
      const page = await readChatPage({ id: "citation", provider: "codex", owner: "Codex", cwd: root, section: "history", updatedAt: "2026-09-02T10:00:00Z", canOpenOwner: true, chatPath: file }, undefined, 1);
      expect(page.items).toHaveLength(1);
      expect(page.items[0]).toMatchObject({ kind: "assistant", text: answer });
      expect(page.transcriptEvidence?.authoritative).toBe(false);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("normalizes both latest and earlier pages without losing prompts, answers, or identity", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "visor-citation-history-"));
    try {
      const file = path.join(root, "transcript.jsonl");
      const records = Array.from({ length: 8 }, (_, index) => [
        { ...JSON.parse(codex(`Prompt ${index}`, "user")), payload: { ...JSON.parse(codex(`Prompt ${index}`, "user")).payload, id: `prompt-${index}` } },
        { ...JSON.parse(codex(`Answer ${index}\n${citation}`)), payload: { ...JSON.parse(codex(`Answer ${index}\n${citation}`)).payload, id: `answer-${index}` } },
      ]).flat();
      await writeFile(file, records.map((record) => JSON.stringify(record)).join("\n") + "\n");
      const session = { id: "citation-history", provider: "codex" as const, owner: "Codex", cwd: root, section: "history" as const, updatedAt: "2026-09-02T10:00:00Z", canOpenOwner: true, chatPath: file };
      const seen = new Set<string>();
      let before: number | undefined;
      for (let count = 0; count < 8; count += 1) {
        const page = await readChatPage(session, before, 3);
        for (const item of page.items) {
          expect(item.kind === "user" || item.kind === "assistant").toBe(true);
          if (item.kind === "user" || item.kind === "assistant") expect(item.text).not.toContain("oai-mem-citation");
          expect(seen.has(item.id)).toBe(false);
          seen.add(item.id);
        }
        if (!page.hasMoreBefore) break;
        expect(page.nextBefore).toBeLessThan(before ?? Infinity);
        before = page.nextBefore;
      }
      expect(seen.size).toBe(16);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
});

const notification = "<task-notification>\n<task-id>task-1</task-id>\n<tool-use-id>tool-1</tool-use-id>\n<output-file>/tmp/task-output.txt</output-file>\n<status>completed</status>\n<summary>Background command finished.</summary>\n</task-notification>";
const claude = (body: string, array = false) => JSON.stringify({ type: "user", uuid: "claude-output", message: { role: "user", content: array ? [{ type: "text", text: body }] : body } });

describe("Claude output transported as user messages", () => {
  it.each([false, true])("classifies background-task results without inventing a user prompt (array=%s)", (array) => {
    expect(parseChatLines("claude_code", [claude(notification, array)])[0]).toMatchObject({ kind: "activity", activity: "background_task", title: "Background task completed", text: "Background command finished.\n\n[Output file](</tmp/task-output.txt>)" });
  });
  it.each(["stdout", "stderr"])("routes local-command-%s to command output", (stream) => {
    expect(parseChatLines("claude_code", [claude(`<local-command-${stream}>Reloaded settings.</local-command-${stream}>`)])[0]).toMatchObject({ kind: "system", category: "local_command_output", text: "Reloaded settings.", tone: stream === "stderr" ? "error" : "neutral" });
  });
  it("removes terminal controls while preserving output and ordinary escape examples", () => {
    const output = "\u001b[32mReloaded\u001b[0m \u001b]8;;https://example.com\u0007docs\u001b]8;;\u0007; literal \\u001b[32m";
    expect(parseChatLines("claude_code", [claude(`<local-command-stdout>${output}</local-command-stdout>`)])[0]).toMatchObject({ text: "Reloaded docs; literal \\u001b[32m" });
    const items = parseChatLines("codex", [
      JSON.stringify({ type: "response_item", payload: { type: "function_call", call_id: "color-tool", name: "exec_command", arguments: "{}" } }),
      JSON.stringify({ type: "response_item", payload: { type: "function_call_output", call_id: "color-tool", output } }),
    ]);
    expect(items[0]).toMatchObject({ kind: "tool", result: "Reloaded docs; literal \\u001b[32m" });
  });
  it("does not turn empty local-command output into a user prompt", () => {
    expect(parseChatLines("claude_code", [claude("<local-command-stdout>\n</local-command-stdout>")])).toEqual([]);
  });
  it.each([
    `Explain this:\n\`\`\`xml\n${notification}\n\`\`\``,
    `<task-notification><summary>user example</summary></task-notification>`,
    `<local-command-stdout>unterminated example`,
    `Keep prose.\n<local-command-stdout>Example</local-command-stdout>`,
    notification.replace("<task-id>task-1</task-id>", "<task-id>one</task-id><task-id>two</task-id>"),
  ])("preserves incomplete and authored examples", (body) => {
    expect(parseChatLines("claude_code", [claude(body)])[0]).toMatchObject({ kind: "user", text: body });
  });
});
