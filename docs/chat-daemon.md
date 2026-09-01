# Chat daemon

The TypeScript daemon owns Chat history reads and interactive hook responses.

The Swift-to-Electron UI behavior contract and public test seams are defined
in [Chat feature parity](chat-feature-parity.md).

## Provider records

Each provider keeps its own transcript path and parser.

- Claude Code parses user, assistant, thinking, tool-use, tool-result, and image blocks.
- Codex parses response items, reasoning, function calls, custom tools, outputs, and messages.
- Pi parses active-branch messages, reasoning, tool calls, tool results, and images.
- Cursor parses its separate message and tool format as read-only Chat.
- Zed-hosted records reuse the authoritative provider transcript and remain read-only.
- Auggie remains source-only because it has no verified transcript format.

Codex provider discovery also classifies the interaction origin separately from
the lifecycle phase: Desktop rows are `interactive`, live CLI rows are
`terminal`, and database rows with `source = exec` are `automation`. Automation
rows remain searchable in Sessions and the navigator as read-only records, but
they are excluded from physical menu-bar pills and ambient Ready attention.

Codex Desktop sessions with an available canonical transcript expose **Open Chat** in every section, including **History**, regardless of inactivity age. Reading a conversation is separate from controlling its provider: historical conversations remain read-only, and opening Chat does not grant send, cancel, or approval authority.

The provider's separate observed-session window, archive exclusions, and missing-transcript checks still bound discovery; this entry rule does not add older or undiscovered sessions to the list. Historical Pi records with valid conversation content remain readable. Unsupported providers do not gain Chat entry, and host-specific control restrictions remain unchanged.

## Authoritative metadata

The newest Chat page reads latest-turn metadata from the same bounded provider transcript. Earlier pages cannot replace newer metadata.

- Claude Code supplies model, reasoning effort, permission mode, and current input-context tokens.
- Codex supplies model, model provider, reasoning effort, sandbox policy, approval policy, context tokens, and context window.
- Pi supplies model, model provider, thinking level, and current input-context tokens.
- Cursor exposes no metadata fields because its transcript does not provide them.

Codex `models_cache.json` and Pi `models-store.json` supply read-only display names and context windows. Missing, synthetic, malformed, or contradictory values are omitted instead of inferred.

## Pagination

The daemon reads transcript suffixes through the bounded summary-work limit.

A page targets 500 items and starts at a user prompt when one exists. Pages contain at most 1,000 items and read at most 16 MiB.

The renderer groups reasoning and tool work under each prompt. Final assistant prose remains visible outside the disclosure.

## Visibility

Chat settings filter only rendered rows. Canonical transcript items remain unchanged.

All categories are visible by default. Users can independently control provider turn grouping, user and assistant messages, thinking, known tool families, MCP tools, unknown tools, interruptions, durations, recaps, compact boundaries, and local command output.

## Actions

Claude Code permission hooks keep their Unix connection open while the user decides.

The authenticated WebSocket client can allow, always allow, deny, or answer a question. The daemon returns the existing snake-case hook response.

Question answers use the question text as the dictionary key, matching Claude Code’s hook contract.

A failed client request is logged and isolated. A failed Chat read returns a bounded error page without stopping the daemon or native helper.

Verified active Claude Code and Pi terminal sessions accept text through the signed helper’s exact TTY route.

Claude image paths use private bracketed pastes. Pi receives one ordered prompt containing text and local image paths.

Codex resumes the exact thread through `codex app-server`, then starts a text and local-image turn.

The daemon keeps that app-server process until the turn completes. Command, file, permission, and question requests use the shared Chat response controls.

Cursor, Zed-hosted, historical, and sessions without verified control metadata remain read only.

The renderer reports that limit instead of exposing a composer that cannot deliver.

## Checks

Run protocol, daemon, renderer, and Electron Chat checks with:

```sh
npm test
npm run test:chat
```
