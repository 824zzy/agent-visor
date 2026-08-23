# Chat daemon

The TypeScript daemon owns Chat history reads and interactive hook responses.

## Provider records

Each provider keeps its own transcript path and parser.

- Claude Code parses user, assistant, thinking, tool-use, tool-result, and image blocks.
- Codex parses response items, reasoning, function calls, custom tools, outputs, and messages.
- Pi parses active-branch messages, reasoning, tool calls, tool results, and images.
- Cursor parses its separate message and tool format as read-only Chat.
- Zed-hosted records reuse the authoritative provider transcript and remain read-only.
- Auggie remains source-only because it has no verified transcript format.

Historical Codex rows older than the active window remain source-only. Historical Pi records with valid conversation content remain readable.

## Pagination

The daemon reads transcript suffixes through the bounded summary-work limit.

A page targets 500 items and starts at a user prompt when one exists. Pages contain at most 1,000 items and read at most 16 MiB.

The renderer groups reasoning and tool work under each prompt. Final assistant prose remains visible outside the disclosure.

## Actions

Claude Code permission hooks keep their Unix connection open while the user decides.

The authenticated WebSocket client can allow, always allow, deny, or answer a question. The daemon returns the existing snake-case hook response.

Question answers use the question text as the dictionary key, matching Claude Code’s hook contract.

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
