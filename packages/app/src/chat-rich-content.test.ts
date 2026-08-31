import { describe, expect, it } from "vitest";
import type { ChatItem } from "@agent-visor/protocol";
import {
  chatToolPresentation,
  parseChatRichInline,
  parseChatRichText,
  presentChatMath,
  safeChatLink,
  tokenizeChatCode,
} from "./chat-rich-content.js";

describe("Chat rich content", () => {
  it("keeps block structure and fenced language metadata", () => {
    const document = parseChatRichText(
      "# Result\n\n- **ok**\n- ~~old~~\n\n```typescript\nconst answer = 42;\n```\n\n$$\nx^2\n$$",
    );
    expect(document.source).toContain("```typescript");
    expect(document.blocks).toEqual([
      { kind: "heading", level: 1, inlines: [{ kind: "text", text: "Result" }] },
      {
        kind: "list",
        ordered: false,
        items: [
          [{ kind: "strong", text: "ok" }],
          [{ kind: "strike", text: "old" }],
        ],
      },
      { kind: "code", language: "typescript", text: "const answer = 42;" },
      { kind: "math", text: "x^2" },
    ]);
  });

  it("parses safe inline links, emphasis, code, and inline math", () => {
    expect(parseChatRichInline("See [docs](https://example.com/docs), *now*, `x`, and $a+b$."))
      .toEqual([
        { kind: "text", text: "See " },
        { kind: "link", text: "docs", href: "https://example.com/docs" },
        { kind: "text", text: ", " },
        { kind: "emphasis", text: "now" },
        { kind: "text", text: ", " },
        { kind: "code", text: "x" },
        { kind: "text", text: ", and " },
        { kind: "math", text: "a+b" },
      { kind: "text", text: "." },
    ]);
    expect(parseChatRichInline("Inspecting ```text\nfiles\n```"))
      .toEqual([{ kind: "text", text: "Inspecting " }, { kind: "code", text: "files\n" }]);
    expect(parseChatRichText("Inspecting ```text\nfiles\n```").blocks)
      .toEqual([{ kind: "paragraph", inlines: [
        { kind: "text", text: "Inspecting " },
        { kind: "code", text: "files\n" },
      ] }]);
    expect(safeChatLink("javascript:alert(1)")).toBeUndefined();
    expect(safeChatLink("file:///tmp/private.txt")).toBeUndefined();
    expect(safeChatLink("https://example.com/docs")).toBe("https://example.com/docs");
  });

  it("retains table cells and renders malformed links as text", () => {
    const blocks = parseChatRichText("| Name | Value |\n| --- | --- |\n| **a** | `1` |").blocks;
    expect(blocks).toEqual([{
      kind: "table",
      header: [[{ kind: "text", text: "Name" }], [{ kind: "text", text: "Value" }]],
      rows: [[
        [{ kind: "strong", text: "a" }],
        [{ kind: "code", text: "1" }],
      ]],
    }]);
    expect(parseChatRichInline("[bad](javascript:alert(1))")).toEqual([
      { kind: "text", text: "[bad](javascript:alert(1))" },
    ]);
  });

  it("projects plan and edit tool payloads without changing the payload", () => {
    const plan: Extract<ChatItem, { kind: "tool" }> = {
      id: "plan",
      kind: "tool",
      name: "ExitPlanMode",
      family: "plan_mode",
      input: { plan: "# Plan\n\n1. Test" },
      status: "success",
    };
    const edit: Extract<ChatItem, { kind: "tool" }> = {
      id: "edit",
      kind: "tool",
      name: "Edit",
      family: "edit",
      input: { file_path: "src/App.tsx", old_string: "old", new_string: "new" },
      status: "success",
    };
    expect(chatToolPresentation(plan)).toEqual({
      kind: "plan", title: "ExitPlanMode", text: "# Plan\n\n1. Test",
    });
    expect(chatToolPresentation(edit)).toEqual({
      kind: "edit", filePath: "src/App.tsx", oldText: "old", newText: "new",
    });
  });

  it("tokenizes supported code languages while preserving literal fallback", () => {
    expect(tokenizeChatCode('const answer = "ok"; // done\nreturn 42;', "typescript")).toEqual([
      { kind: "keyword", text: "const" },
      { kind: "plain", text: " answer = " },
      { kind: "string", text: '"ok"' },
      { kind: "plain", text: "; " },
      { kind: "comment", text: "// done" },
      { kind: "plain", text: "\n" },
      { kind: "keyword", text: "return" },
      { kind: "plain", text: " " },
      { kind: "number", text: "42" },
      { kind: "plain", text: ";" },
    ]);
    expect(tokenizeChatCode('{"ok": true, "count": 2}', "json").map(({ kind }) => kind))
      .toEqual(["plain", "string", "plain", "keyword", "plain", "string", "plain", "number", "plain"]);
    expect(tokenizeChatCode("if ready:\n  # wait\n  return True", "python")
      .some(({ kind, text }) => kind === "comment" && text === "# wait")).toBe(true);
    expect(tokenizeChatCode("echo $HOME # shell", "bash")
      .some(({ kind, text }) => kind === "comment" && text === "# shell")).toBe(true);
    expect(tokenizeChatCode("<opaque>", "rust")).toEqual([{ kind: "literal", text: "<opaque>" }]);
  });

  it("converts the supported LaTeX subset to MathML and falls back literally", () => {
    const math = presentChatMath("\\frac{x^2}{\\sqrt{y}}", true);
    expect(math.source).toBe("\\frac{x^2}{\\sqrt{y}}");
    expect(math.mathML).toContain("<math");
    expect(math.mathML).toContain("<mfrac>");
    expect(math.mathML).toContain("<msup>");
    expect(math.mathML).toContain("<msqrt>");
    expect(presentChatMath("\\unsupported{x}").mathML).toBeUndefined();
    expect(presentChatMath("x".repeat(4_097)).mathML).toBeUndefined();
  });
});
