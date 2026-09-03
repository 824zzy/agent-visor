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

Provider-origin classification happens before canonical `ChatItem` creation and
is separate from renderer visibility settings. For Codex user messages, the
parser uses `internal_chat_message_metadata_passthrough.content_item_kinds`
only when it is a string array aligned one-for-one with `payload.content`.
Known internal origins (`environments.environment_context`,
`skills.selected_skill_instructions`, `goal.internal_context`,
`plugins.recommendations`, and `agents_md.instructions`) are excluded per
content block. A known `multi_agent.subagent_notification` becomes a typed
`activity` item rather than a user message or raw JSON dump.

The typed activity contract is `{ kind: "activity", activity: "subagent" |
"delegation", id, title, text, timestamp? }`. Titles are short status labels;
the text contains only bounded, meaningful status/result fields. Complete
legacy `codex_delegation` envelopes become delegation activities, and complete
allow-listed legacy context/browser wrappers are excluded using conservative
recognition. The observed Codex image-tag scaffold is normalized only when its
validated image block is present; a file preamble without an image keeps its
recognized path reference, preserving the actual request and attachment data.

Missing, malformed, misaligned, or unknown origin metadata uses a conservative
fallback: known legacy cases may be recognized, but mixed, quoted, incomplete,
or otherwise uncertain authored content remains visible. `user.text` is a
legacy label, not proof that content was typed by a person. Shared text
normalization trims surrounding whitespace only, so literal XML and other
quoted examples remain exact. Assistant messages, tools, approvals, questions,
actionable errors, interruptions, and compaction boundaries retain their
existing presentation.

Excluded records do not become user turns or delivery evidence and do not
consume the history page's visible-item budget. Activity records remain
available as collapsed work disclosure, but do not by themselves make a
transcript authoritative or imply that the main task is still live. Structured
model, usage, and permission metadata still comes from the separate metadata
parser. Source transcripts are never modified.

Renderer Chat settings filter canonical rendered rows; they do not change
provider-origin classification or transcript authority. Swift visibility rules
are a reference for the shared interaction contract, not a complete Codex
provenance policy. This boundary is a presentation/classification safeguard,
not DLP or a guarantee that user-authored content contains no sensitive data.

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
