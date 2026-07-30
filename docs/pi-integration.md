# Pi Integration Design

Status: Accepted
Last reviewed: 2026-07-30
Implementation status: The restart-safe liveness-heartbeat amendment is implemented, signed-deployed, and user-validated with live Pi runtimes. Native-equivalent image path submission is implemented and signed-deployed; image-only and image-plus-text delivery are user-validated with readable Pi results, while the remaining edge-case matrix has automated coverage but has not been exercised live. Provider-isolated bottom-bar behavior is also signed-deployed and user-validated: Pi exposes no Claude permission-mode chip and Agent Visor reserves Claude mode probing and cycling for Claude Code.

## Purpose

Agent Visor supports interactive Pi coding-agent sessions as terminal-owned sessions. Pi support follows the same product model as Claude Code running in iTerm2: Agent Visor observes status and transcript evidence, returns the user to the exact terminal, and may submit text plus native-equivalent image paths without replacing Pi's native TUI.

This document defines the Pi-specific discovery, lifecycle, transcript, installation, and control contract. The shared surface contract remains [Product Surfaces](product-surfaces.md).

## Product Decisions

1. Pi support works without prior manual setup. Process and session-file observation provide the baseline.
2. When Pi is detected, Agent Visor automatically installs and maintains one bundled global Pi extension at `~/.pi/agent/extensions/agent-visor.ts`.
3. The extension is an enhancement, not a hard dependency. Removing it or failing to install it must not break discovery, history, or terminal navigation.
4. Agent Visor does not create `~/.pi` or install anything when Pi is not detected.
5. Settings always shows Pi. An unavailable installation appears as disabled `Pi — Not detected`.
6. Initial support covers existing interactive TUI sessions. Agent Visor does not launch new Pi sessions.
7. Text and image-path submission to a terminal-owned Pi TUI are supported after terminal routing is verified. Agent Visor mirrors Pi's native clipboard-image convention without modifying Pi, mutating the system clipboard, or expanding the lifecycle extension protocol; source-specific interactive forms remain out of scope.
8. Pi receives `Needs attention` only from explicit evidence. Agent Visor does not infer it from silence, a long-running tool, or an extension dialog it cannot observe.
9. Pi's latest non-empty session name on the active transcript branch is authoritative. A rename replaces the previously displayed Pi name without requiring an Agent Visor restart; other agents retain their source-specific title precedence.
10. Agent Visor presents Pi as a prompt-bounded conversation, not a flat execution log. Work is grouped and collapsed by default while the final answer remains prominent; a user setting preserves access to the raw activity stream.
11. Restarting Agent Visor must not make a still-running interactive Pi session disappear. A Pi runtime that has loaded the current bundled extension periodically reasserts its exact live attachment; that signal proves liveness and routing metadata only, never new user or agent activity.

## User-Visible States

The Pi connection row distinguishes capability from current activity:

- **Not detected**: no Pi executable, process, config root, or session store was found. The row is disabled and no Pi files are created.
- **Observing**: Pi was detected and baseline process/session-file observation is available, but no current extension heartbeat proves real-time lifecycle reporting.
- **Connected**: a Pi TUI session has reported through the bundled extension. Exact lifecycle evidence is available for that session.

A newly installed extension is not called Connected until a Pi process loads it. Pi processes already running when Agent Visor installs the file continue through the Observing fallback until `/reload` or the next Pi launch. Once a heartbeat-capable extension is loaded, a later Agent Visor restart requires no prompt, transcript write, terminal activation, or Pi reload to restore that live session.

## Baseline Discovery

Agent Visor scans `~/.pi/agent/sessions/*/*.jsonl` and reads the versioned session header:

- session UUID;
- creation timestamp;
- working directory;
- optional parent session.

It separately discovers live `pi` processes and records PID, process start time, CWD, and TTY. A process is paired with a session using normalized CWD and the closest creation time inside a narrow tolerance. Matching is one-to-one. Unmatched persisted sessions remain historical; unmatched processes do not manufacture session rows from CWD, title, recency, or other ambiguous evidence.

Creation-time matching is fallback evidence for a freshly created session, not a restart-recovery mechanism for resumed or imported sessions. The bundled extension is authoritative after `/new`, `/resume`, `/fork`, or another in-process session replacement because process start time no longer identifies the active session. Its periodic live-attachment heartbeat is also the authoritative mapping after Agent Visor itself restarts.

Historical Pi sessions are included in the Sessions browser when their JSONL has a valid session header and renderable transcript evidence. They do not become menu-bar pills merely because a file exists.

Ephemeral `--no-session` runs have no durable identity and are ignored. Print, JSON, RPC, and SDK sessions may appear as saved history when persisted, but only interactive TUI sessions receive live pills and terminal navigation in the initial release.

## Restart Reattachment

Agent Visor's in-memory PID-to-session bindings are disposable. After the app relaunches, every still-running interactive Pi session that loaded the current bundled extension must reappear without waiting for transcript activity.

Reconciliation proceeds from strongest to weakest evidence:

1. An exact `SessionStart` received while Agent Visor is running attaches the reported session immediately, including same-PID `/new`, `/resume`, `/fork`, startup, and reload.
2. A periodic `SessionHeartbeat` reasserts the current session ID, PID, TTY, CWD, and session-file path. After Agent Visor restarts, an absent or historical row reattaches as live within one heartbeat interval.
3. Creation-time process matching remains the no-extension fallback for genuinely fresh sessions only.
4. Transcript growth may still recover a missed active turn, but user activity is not required for restart recovery.

A heartbeat is not phase or activity evidence. It must not refresh `lastActivity`, reorder an already tracked session, clear or create an approval, modify tool state, or change Working/Ready/Idle for a non-ended row. When it restores an absent or historical row, Agent Visor uses Idle as the conservative live phase and retains transcript-derived activity time. A later transcript or lifecycle event may refine that phase normally.

The ordinary same-PID late-event guard remains in force for heartbeats. A heartbeat may restore an Ended row only when the pre-merge attachment PID is absent or differs from the reporting PID. It also cannot evict a different non-ended session that already owns the same PID. These rules prevent an in-flight heartbeat from reviving a session after its matching `SessionEnd` or replacing a newer same-process session. Exact `SessionStart` remains the only Pi event allowed to transfer, replace, or reactivate an attachment under the same PID.

A live process using an older already-loaded copy of the extension cannot be upgraded invisibly. It continues through fallback behavior until the user runs `/reload` or starts Pi again; Agent Visor must not inject `/reload` or terminal input to force adoption.

## Bundled Extension

Agent Visor owns exactly one file:

```text
~/.pi/agent/extensions/agent-visor.ts
```

Installation is atomic and idempotent. Updates replace only that file. Existing Pi settings, packages, and extensions are never rewritten. If the file is removed, fallback observation continues and a later detection pass may restore Agent Visor's owned copy.

The extension:

- runs only as part of Pi's normal global-extension discovery;
- sends local metadata to `/tmp/agent-visor.sock`;
- reports session ID, session-file path, PID, CWD, TTY when available, and lifecycle state;
- sends no prompt text, assistant text, tool input, tool output, credentials, or environment contents;
- performs no network requests;
- does not register tools or commands;
- does not modify prompts, models, tool calls, results, permissions, or session data;
- starts at most one session-scoped, unreferenced heartbeat timer from `session_start`, never from the extension factory;
- reports `SessionHeartbeat` at a fixed 10-second cadence while that TUI runtime remains live;
- clears the timer unconditionally during `session_shutdown`, before reporting the shutdown;
- returns immediately when Agent Visor's socket is absent, retaining no queue or deferred retry;
- never blocks Pi on Agent Visor availability or keeps the Pi process alive.

Lifecycle mapping uses Pi's public extension events plus the bounded extension-local timer:

| Source | Agent Visor evidence |
| --- | --- |
| `session_start` | Exact live attachment; idle/recent until turn evidence arrives |
| 10-second extension timer | `SessionHeartbeat`: attachment liveness and routing metadata only |
| `agent_start` | Working |
| `tool_execution_start` | Working; optional tool name only |
| `tool_execution_end` | Working until the agent settles |
| `session_before_compact` | Working/compacting |
| `agent_settled` | Ready |
| `session_shutdown` | Ended for that live attachment |

`agent_settled`, rather than low-level `agent_end`, is the completion boundary because Pi may still retry, compact, or process queued follow-up messages after `agent_end`.

## Transcript Contract

Pi session files are version-3 tree-shaped JSONL. The parser must not treat the file as a flat conversation.

1. Decode the session header.
2. Index entries by `id` and retain append order.
3. Use the latest persisted entry as the leaf.
4. Follow `parentId` to reconstruct the active branch.
5. Render only that branch; abandoned branches remain in Pi and are not merged into one false transcript.
6. Preserve compaction and branch-summary boundaries without duplicating retained-tail messages.

Supported projections include:

- user and assistant text;
- images when represented in a supported local/data form;
- thinking blocks;
- tool calls and correlated tool results;
- local bash execution;
- compaction summaries and branch summaries;
- session names;
- model, reasoning level, usage, CWD, and activity timestamps when present.

Context usage follows Pi's own accounting: use the latest valid assistant `totalTokens` value when present, otherwise sum its usage components. Error and aborted responses do not replace the latest valid usage. Resolve the context-window denominator by provider plus model ID from Pi's local `~/.pi/agent/models-store.json`; if that metadata is unavailable, omit Pi context usage rather than applying another agent's generic model default.

The same provider-plus-model lookup supplies Pi's canonical human-facing model name without replacing the raw transcript identifier. For example, Pi's `openai-codex` catalog presents `gpt-5.6-sol` as `GPT-5.6 Sol`. Catalog reads are passive and read-only; missing or malformed catalog data falls back to the shared model-presentation policy and never disables transcript rendering.

Unknown entry and content-block types are ignored rather than failing the session. Corrupt individual lines do not hide otherwise valid history.

The latest non-empty `session_info.name` on the active branch is Pi's canonical session name. When the session file extends, Agent Visor reparses through the Pi provider and replaces any earlier Pi transcript name; a rename on an abandoned branch does not leak into the active session. This transcript authority is Pi-specific: process- or index-resolved names for other agents keep their existing precedence. Rename observation must use the existing provider-resolved file watcher and must not depend on a later lifecycle hook.

Agent Visor Chat is mirrored from Pi's transcript, remains secondary in authority to Pi's TUI, and may lag file writes. The Sessions browser enters this shared Chat by default while keeping **Open in <terminal>** visible; menu-bar pills and the `+N` popover remain original-terminal first.

## Chat Presentation

Pi Chat is conversation-first. Each user prompt opens one turn whose default top-level structure is:

```text
[user prompt]
[Worked/Working · N actions · optional duration]
[final answer, when complete]
```

The work disclosure is collapsed by default. `N actions` counts tool invocations only; thinking blocks and progress prose do not inflate it. The header summarizes canonical activity such as `Ran 6 commands · Read 4 files`, surfaces an error indicator when any folded action failed, and omits duration when timestamps are absent or unreliable. Failed, interrupted, and approval-blocked child rows remain visible as exceptions even while routine work is collapsed. A live grouped turn owns the Working indication, so Chat must not add a duplicate bottom-level processing row.

When expanded, work remains subordinate to the conversation:

- progress prose emitted before later actions is folded with the work;
- tools use Pi-aware canonical verbs and useful targets, such as `Read chat-history.png` or `Run python …`, rather than raw lowercase identifiers;
- adjacent repeated actions may be batched without losing access to their individual calls and results;
- failed or interrupted actions remain visibly marked;
- thinking is collected under a nested `Reasoning (N)` disclosure, collapsed by default and rendered as Markdown rather than literal `**` syntax.

For a completed turn, trailing assistant prose after the final work item is the final answer and remains top-level. While a Pi turn is still Working, assistant prose remains work detail until authoritative completion evidence arrives; this avoids promoting progress commentary into a false final answer. Pi assistant responses ending with `error` or `aborted` preserve that terminal state as interrupted work, so failed prose is not presented as a normal final answer.

`Group Pi turns` defaults on. Turning it off restores the raw chronological activity stream for diagnostics without changing the canonical transcript. Pagination aligns prompt-bounded sessions to whole turns when the turn fits the existing render safety cap; an exceptionally large single turn stays bounded rather than defeating the chat performance guardrail. Pi uses the shared responsive Chat content rail defined in [Sessions Browser UI Design](session-browser-ui.md); message roles do not introduce independent prose-width frames.

## Session Phases

With extension evidence:

- `session_start` is exact live-attachment evidence for its session ID. It reactivates an Ended or historical Pi row as idle even when Pi reused the same PID for an in-process session replacement; ordinary same-PID events remain subject to the late-hook guard;
- `SessionHeartbeat` refreshes exact PID/TTY/host/origin attachment metadata but is phase-neutral for a non-ended row;
- `SessionHeartbeat` reattaches an absent or historical row conservatively as Idle when the pre-merge PID is absent or different, while a same-PID heartbeat after Ended remains rejected as potentially late;
- heartbeat handling does not update user-visible activity time or phase-evidence freshness and does not flow through generic lifecycle phase mapping;
- `agent_start` through `agent_settled` is Working;
- `agent_settled` is Ready;
- `session_shutdown` ends the live attachment;
- explicit future blocking evidence may produce Needs attention.

Without extension evidence, transcript inference may produce Working, Ready, or Recent using the latest active-branch role, unresolved tool calls, file quiescence, and the shared stale ceiling. It must not produce Needs attention.

Extension evidence wins over transcript inference while fresh. Stale extension evidence expires through the shared phase-evidence policy so a crashed process cannot remain permanently Working or Ready.

A best-effort lifecycle event must not permanently hide a Pi session that demonstrably continued. The bundled extension's exact `session_start` reattaches its reported session immediately; this is the idle-safe path for startup, reload, `/resume`, `/new`, and `/fork`, whose active transcript may predate the current process. After Agent Visor restarts, `SessionHeartbeat` restores the same exact attachment conservatively as Idle without requiring transcript growth. If neither exact signal is available, an Ended Pi session recovers to Working only when the attached process is still live and the same transcript records a new started-turn marker after the Ended observation. A completed or unchanged transcript alone does not recover through the transcript fallback, so session replacement and genuine shutdown do not resurrect abandoned attachments.

## Navigation And Input

A live Pi TUI session is terminal-owned:

- PID ancestry resolves Ghostty, iTerm2, Terminal, VS Code, Cursor, Zed, or another supported host;
- TTY identifies the exact pane where the host adapter supports exact routing;
- a normal pill or `+N` popover action opens that original terminal;
- a Chat-capable Sessions-browser row or Return enters the same in-window Chat used by other supported sources;
- Shift-Return and the always-visible **Open in <terminal>** action open the terminal, while the quiet disclosure chevron belongs to the row's Chat target rather than acting as a separate neighboring button.

Text submission reuses the terminal adapter and behaves as input typed into Pi. Agent Visor does not promise source-specific semantics for input submitted while Pi is busy; Pi's native queueing behavior remains authoritative.

Pi does not inherit Claude Code's `default`, `accept edits`, `plan`, `auto`, or `bypass` permission-mode surface. Pi assigns Shift-Tab to thinking-level cycling and has no built-in plan mode. Agent Visor therefore hides Claude mode metadata for Pi, does not run Claude's terminal mode probe against a Pi pane, and never sends Claude's mode-cycle keystroke from Pi Chat. Any future Pi thinking-level control requires its own explicit capability and design amendment.

### Image Path Submission

Pi's native TUI handles clipboard images by writing a local temporary image and inserting that path into the editor. Agent Visor Chat mirrors that established convention for a live, exactly routed Pi terminal session:

1. The shared composer recognizes the pasted image, writes an Agent Visor-owned UUID PNG under its existing temporary attachment directory, and shows the existing removable attachment thumbnail.
2. At send time, Pi uses a provider-aware `terminalPathPrompt` route. Ordered image paths are placed before optional user text with one space between every component, then the complete payload is submitted once through the same exact tmux, iTerm2, or Ghostty text route used by ordinary Pi input.
3. Agent Visor must not paste paths and text as separate terminal operations. Pi keeps paths as prompt text, unlike Claude Code's attachment-aware TUI, so separate operations can concatenate, race, or be cleared by later input preparation.
4. Pi attachment files remain available for 24 hours after submission so a queued Pi turn can consume them. Successful Claude/Codex attachment cleanup retains its existing shorter lifetime. Startup cleanup uses the longest active retention bound, and manually removing a composer attachment still deletes it immediately.
5. A failed Pi terminal delivery is logged and surfaced in Chat rather than silently presenting the image as sent. No image bytes or prompt content cross the lifecycle socket.

This route does not synthesize Pi's `Ctrl+V`, mutate or depend on the current system clipboard after capture, modify Pi's package or settings, or change `~/.pi/agent/extensions/agent-visor.ts`. Pi remains the owning execution environment and decides how the submitted path is read. Its transcript may preserve the path as user text and later record an image block when Pi's `read` tool consumes that file.

Pi support still does not answer extension-owned dialogs, manipulate `/tree`, change models, or create sessions.

## Availability And Failure Behavior

Pi detection considers, without creating files:

- live `pi` processes;
- an existing `~/.pi/agent` root or session store;
- common executable locations, including Homebrew, `~/.local/bin`, and NVM installations.

If Pi is absent, all other Agent Visor integrations continue normally. If extension installation fails, Settings reports Observing and baseline support remains active. If a transcript cannot be parsed, other sessions remain available and the failure does not block menu-bar updates.

The initial release targets Pi's default `~/.pi/agent` directory. Custom `PI_CODING_AGENT_DIR` stores may be observed later when Agent Visor has explicit path evidence; Agent Visor must not guess shell-only environment overrides from a GUI launch context.

## Privacy And Security

The extension runs with the user's Pi process privileges, so its scope must remain auditable and minimal. Its local wire payload contains identifiers and lifecycle metadata only. Agent Visor already reads transcripts directly under Full Disk Access; duplicating conversation content over the socket is unnecessary and prohibited by this contract.

The socket's absence is a normal state. No busy retry loop, background daemon, remote telemetry, or external service is introduced for Pi integration. The only periodic extension work is one unreferenced, session-scoped 10-second timer. Each tick performs one socket-existence check and at most one bounded local connection attempt; failures are discarded without queueing, backoff state, disk writes, or user-visible errors.

## Initial Non-Goals

- Launching a new Pi session from Agent Visor.
- Replacing Pi's TUI or exposing a second full composer workflow.
- Direct multimodal image-byte injection into a running Pi session or any modification of Pi's own package, settings, model catalog, or extension API.
- Pi account/provider usage aggregation.
- Generic detection of another extension's modal UI.
- Fabricating Needs attention without explicit evidence.
- Live pills for print, JSON, RPC, SDK, or ephemeral runs.
- Full support for custom Pi config roots in the first release.

## Test Contract

Core behavior tests must prove:

- active-branch reconstruction excludes abandoned Pi branches;
- transcript parsing maps messages, tools, results, compaction, model, and usage while tolerating unknown records;
- process/session matching uses CWD plus closest creation time and never assigns one session twice;
- unmatched processes do not fabricate sessions;
- baseline phase inference never fabricates Needs attention;
- an exact Pi `session_start` reattaches an Ended row even when its PID is unchanged, while an ordinary same-PID late hook does not;
- a Pi heartbeat reattaches a historical/Ended row when its pre-merge PID is absent or different, but cannot revive an Ended row under the same PID;
- a heartbeat cannot evict a different non-ended session already attached to its PID, while exact `SessionStart` can transfer that PID during an in-process replacement;
- a heartbeat preserves the phase, phase-evidence timestamp, last activity, approval state, and tool state of an already live row;
- a heartbeat-created or restored row retains transcript-derived activity time rather than appearing newly active merely because Agent Visor restarted;
- Pi availability does not create `~/.pi` when absent;
- a newer active-branch Pi session name replaces an earlier displayed Pi name, while a missing or abandoned-branch name does not;
- Pi prompt boundaries produce prompt → grouped work → final-answer order;
- Pi action counts include tools but exclude thinking and progress prose;
- failed, interrupted, and approval-blocked work remains visible when routine children are collapsed;
- prompt-aligned pagination preserves a complete turn when it fits the render safety cap;
- the image-submission policy selects Pi terminal-path prompts only for a sendable session with an exact TTY;
- Pi image prompt composition preserves attachment order, separates paths and optional text, and returns no payload for empty input;
- Pi attachment retention is 24 hours while existing Claude/Codex cleanup remains short-lived.

Integration and source-wiring tests must prove:

- `AgentID.pi` is registered and rendered across shared surfaces;
- Pi file watching uses the provider's resolved transcript path rather than the Claude fallback;
- Pi declares transcript session names authoritative and the shared metadata merge consumes that provider authority;
- window Chat enables Pi grouping by default, offers a raw-stream escape hatch, and suppresses the duplicate processing indicator when a live work header exists;
- Pi tool rows consume Pi-aware canonical names and grouped reasoning renders Markdown behind a nested disclosure;
- the bundled extension contains no network, prompt mutation, tool registration, or content-forwarding behavior;
- the heartbeat timer starts only after `session_start`, is unreferenced, has one instance per runtime, emits metadata only, and is cleared during every `session_shutdown` path;
- SessionStore handles `SessionHeartbeat` before generic lifecycle phase mutation and excludes it from user-activity refresh;
- installation modifies only `agent-visor.ts` and is skipped when Pi is absent;
- `agent_settled` maps to Ready and low-level `agent_end` does not;
- terminal-owned Pi sessions route through the existing terminal adapter;
- both shared Chat composers admit Pi images through the provider-aware route instead of hard-coded Pi exclusions;
- SessionSender sends one composed Pi path prompt, leaves Claude terminal attachment and Codex local-image routes intact, and surfaces Pi delivery failure;
- Pi image submission introduces no change to the bundled lifecycle extension;
- Settings renders unavailable Pi as disabled `Not detected`.

Manual validation must cover:

1. no Pi installation;
2. Pi installed with no running session;
3. a fresh Pi TUI session in iTerm2;
4. Working to Ready transition;
5. plain-text submission;
6. image-only, text-plus-image, and ordered multi-image submission from Agent Visor Chat into an idle Pi TUI, plus one queued/busy turn, with the thumbnail visible before send, one exact-terminal prompt, a readable Pi image result, and no clipboard mutation;
7. image-delivery failure remaining visible rather than producing a false successful send;
8. exact pane navigation with multiple terminals;
9. Agent Visor absent while Pi runs;
10. extension installed after Pi is already running;
11. extension removal with fallback observation;
12. session replacement through `/new` or `/resume`;
13. an idle resumed or imported session surviving an Agent Visor quit/relaunch without prompt or transcript activity;
14. at least ten concurrent Pi TUIs across a relaunch, with every live attachment represented by a visible pill or the `+N` overflow count;
15. a delayed same-PID heartbeat after `SessionEnd` remaining unable to resurrect the ended row;
16. a Pi runtime that loaded the pre-heartbeat extension remaining on documented fallback behavior until `/reload` or its next launch.

## TDD Implementation Record — Native Image Path Submission

Status: Implemented and signed-deployed on 2026-07-29; image-only and image-plus-text delivery were live-accepted on 2026-07-30.

- **Slice 1 — route policy:** Added a provider-aware image route for direct Codex local images, Claude terminal attachments, Pi terminal path prompts, and unavailable sessions. Pi selects the path-prompt route only when the session is sendable and has an exact TTY.
- **Slice 2 — prompt composition:** Added deterministic one-shot Pi prompt composition. Ordered local image paths precede optional trimmed user text, with safe single-space separation; image-only, text-plus-image, multi-image, and empty-input cases are covered.
- **Slice 3 — retention:** Added a shared attachment-retention policy. Pi files remain available for 24 hours after submission; existing Claude/Codex cleanup remains 60 seconds; startup cleanup uses the longest supported bound.
- **Slice 4 — production wiring:** Removed the two hard-coded composer exclusions and sender-side Pi attachment discard. Both shared composers now use the route policy, and `SessionSender` submits each Pi path prompt once through the existing exact terminal route. Failed image delivery logs the failure and shows a Chat toast instead of silently reporting success.
- **Slice 5 — exact optimistic echo:** Pi's pending user echo uses the exact composed path prompt so Chat cannot imply that a different payload was submitted.
- **Validation:** 17 focused image-path tests and 123 nearby regressions passed; the complete AgentVisorCore suite passed 1,755 tests with zero failures; unsigned and signed app builds, `git diff --check`, touched-file whitespace checks, and source-scope audits passed. `/Applications/Agent Visor Dev.app` passed deep strict signature verification, relaunched as one process at PID `38261`, owned `/tmp/agent-visor.sock`, and reached Accessibility `ready`.
- **Pi boundary:** Bundled and installed `agent-visor.ts` SHA-256 values remain identical at `4191e1e3c2ac3681da6582ed6b1656a2fb15678cfa7abb70f8a8a4a25b080375`; this feature changed no Pi package, settings, model catalog, lifecycle payload, or extension content.
- **Live acceptance:** User-controlled image-plus-text and image-only prompts both reached Pi through Agent Visor-owned temporary paths, and Pi read the supplied PNGs successfully. Ordered multi-image delivery, queued-turn retention, failed-route behavior, and explicit clipboard-change measurement retain automated coverage but have not been exercised live. Agent Visor must not submit a test prompt or alter terminal focus solely for further acceptance without action-time approval.

## TDD Fix Plan — Restart-Safe Pi Reattachment

Status: Implemented, signed-deployed, and live-accepted on 2026-07-29.

The captured regression is the July 29 signed-build relaunch: twelve Pi windows plus one Codex session existed, but the relaunched app supplied only eight candidates to packing and logged `hidden=0`. Five live Pi sessions were missing because their resumed/imported transcript creation times could not match current process starts inside the five-second fallback tolerance. Acceptance must reproduce the idle state before any prompt activity can self-heal it.

### Slice 1 — Pure heartbeat disposition

**RED:** Add focused Core tests for a Pi live-attachment heartbeat. Assert independently that an Ended/historical row with no prior PID becomes Idle, a different PID reattaches, a same-PID Ended row stays Ended, a heartbeat cannot evict a different live session already owning its PID, and a non-ended row preserves its phase and activity fields.

**GREEN:** Introduce the smallest pure Core disposition policy needed by SessionStore. Keep exact `SessionStart` stronger than heartbeat evidence and retain the ordinary same-PID late-event rule.

**REFACTOR:** Centralize event classification so Pi heartbeat, exact session start, and ordinary lifecycle events cannot drift across rebind and phase handling.

### Slice 2 — SessionStore phase-neutral reattachment

**RED:** Add production-wiring tests requiring `SessionHeartbeat` to bypass generic `determinePhase()`, avoid `lastActivity` and phase-evidence refresh, consume the pre-merge PID, refuse heartbeat-only PID ownership transfer, and restart the provider-resolved file watcher only when it restores a row.

**GREEN:** Route heartbeat through a dedicated metadata/rebind branch after safe PID/TTY merge and before tool or phase side effects. Apply its collision rule before generic PID dedup so a delayed old-runtime heartbeat cannot remove the newer live session. Publish only when attachment or visibility state actually changes; repeated unchanged heartbeats must not churn ordering or rendering.

**REFACTOR:** Share attachment metadata reconciliation with the existing hook path without duplicating terminal-host, origin, name, or PID-dedup rules.

### Slice 3 — One bounded extension heartbeat

**RED:** Extend the bundled-extension audit to require one 10-second timer created from `session_start`, an unreferenced timer handle, metadata-only `SessionHeartbeat`, and unconditional cleanup in `session_shutdown`. The audit must reject a factory-started timer, content fields, network APIs, persistent queues, and multiple active timers.

**GREEN:** Add the minimum timer lifecycle to `agent-visor-pi.ts.txt`: start after session initialization, send through the existing bounded `report` function, clear before shutdown reporting, and discard absent-socket failures.

**REFACTOR:** Keep heartbeat scheduling separate from lifecycle reporting so `/reload`, `/new`, `/resume`, and `/fork` each tear down the old runtime before the replacement runtime creates one timer, as required by Pi's documented extension lifecycle.

A runtime TypeScript unit harness is not currently part of this repository. The extension lifecycle therefore uses the existing source-wiring audit plus a real Pi acceptance check; the plan must not pretend a source-string assertion alone proves timer behavior.

### Slice 4 — Captured restart regression

**RED:** Add a fixed regression fixture using the five observed resumed/imported identities (`019f48bc`, `019fa67d`, `019fa505`, `019faab0`, `019fa69e`) whose transcript creation times differ from their live process starts. Confirm creation-time matching alone leaves them unmatched and heartbeat dispositions restore the complete ordered pill-surface candidate set.

**GREEN:** Make only the integration adjustment exposed by that fixture. Do not loosen creation-time matching, infer identity from terminal titles, or fabricate sessions from CWD.

**REFACTOR:** Keep discovery completeness distinct from packing overflow: `hidden=0` means no supplied candidate overflowed, not that every operating-system Pi process was identified.

### Slice 5 — Full and signed live validation

Run each focused RED → GREEN loop separately, then the relevant Pi/lifecycle regression suites, the complete AgentVisorCore suite, `git diff --check`, and the signed development build through `scripts/dev-build.sh`.

For live acceptance, use a Pi runtime that has actually loaded the heartbeat-capable extension. Let a resumed session become idle, relaunch Agent Visor, and verify before any prompt or transcript write that:

1. the socket receives `SessionHeartbeat` within one 10-second interval;
2. the row reattaches with the exact PID, TTY, host, origin, and authoritative Pi name;
3. its prior activity timestamp and conservative phase are preserved;
4. its ID enters the pill-surface input, with width overflow represented only through the normal `+N` plan;
5. repeated heartbeats do not reorder pills or emit redundant render plans; and
6. closing Pi stops heartbeats and removes/ends the live attachment without resurrection.

Do not type `/reload`, launch or close a Pi TUI, or otherwise mutate a foreground terminal solely for acceptance without action-time approval. Existing Pi processes that loaded the old extension are not valid heartbeat acceptance subjects.

## TDD Implementation Record — 2026-07-29

- **Slice 1 RED:** `swift test --filter PiSessionHeartbeatPolicyTests` failed because `PiSessionHeartbeatPolicy` did not exist. GREEN added the pure disposition policy and heartbeat evidence classification; 17 focused policy tests passed.
- **Slice 2 RED:** the SessionStore wiring audit failed because no heartbeat disposition, pre-dedup collision check, or phase-neutral branch existed. GREEN added pre-merge collision protection, conservative Idle reattachment, stale phase-evidence clearing, transcript-derived activity retention, provider watcher restart, and no-op publish suppression. Focused lifecycle tests and unsigned app builds passed.
- **Slice 3 RED:** the bundled-extension audit failed all timer-lifecycle requirements. GREEN added one session-scoped 10-second timer, `.unref()`, metadata-only `SessionHeartbeat`, and unconditional shutdown cleanup. TypeScript syntax validation passed.
- **Slice 4 regression:** the fixed five-session July 29 fixture proves creation-time matching returns no matches while heartbeat evidence restores `019f48bc`, `019fa67d`, `019fa505`, `019faab0`, and `019fa69e`, producing the complete 13-session pill-surface input. The fixture was immediately green after Slices 1–3 and required no additional production adjustment.
- **Full validation:** 41 focused Pi/lifecycle tests passed; the complete AgentVisorCore suite passed 1,715 tests with zero failures; `git diff --check`, untracked-file whitespace checks, TypeScript syntax validation, and unsigned Xcode build passed.
- **Signed deployment:** `scripts/dev-build.sh` succeeded; `/Applications/Agent Visor Dev.app` passed deep strict signature verification, relaunched as one process, returned Accessibility to Ready, and installed byte-identical heartbeat-capable extension content. Source, bundled, and installed SHA-256 are `4191e1e3c2ac3681da6582ed6b1656a2fb15678cfa7abb70f8a8a4a25b080375`.
- **Live acceptance:** after loading and exercising the heartbeat-capable integration with live Pi runtimes, the user confirmed that restart reattachment works well. Passive post-test pill plans also showed the formerly missing resumed/imported session identities returning to the menu-bar candidate input. The old-runtime compatibility boundary remains: a Pi process must load the new extension through `/reload` or a future launch before it can emit heartbeats.

## Change Control

Changes that make the extension mandatory, add content to its wire payload, let heartbeat evidence mutate phase or activity, increase heartbeat frequency, introduce Needs attention inference, enable new-session launching, or broaden live support beyond interactive TUI require an explicit design update before implementation.
