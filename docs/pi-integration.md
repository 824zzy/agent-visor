# Pi Integration Design

Status: Accepted
Last reviewed: 2026-08-02
Implementation status: Automatic prior-boot restoration of the exact interactive Pi sessions owned by Ghostty is implemented behind Agent Visor's launch lifecycle; deterministic policy, persistence, AppleScript compilation, and wiring validation are complete, while signed deployment and a real reboot acceptance remain pending. The restart-safe liveness-heartbeat amendment is implemented, signed-deployed, and user-validated with live Pi runtimes. Native-equivalent image path submission is implemented and signed-deployed; image-only and image-plus-text delivery are user-validated with readable Pi results, while the remaining edge-case matrix has automated coverage but has not been exercised live. Provider-isolated bottom-bar behavior is also signed-deployed and user-validated: Pi exposes no Claude permission-mode chip and Agent Visor reserves Claude mode probing and cycling for Claude Code. The bounded same-session live-runtime ownership guardrail is implemented and signed-deployed: Agent Visor keeps one live owner per durable Pi session, rejects competing runtime evidence while that owner remains alive, and keys Ready attention to the durable session rather than mutable attachment metadata. The bounded transcript-refresh performance amendment is implemented, signed-deployed, and passively validated against a naturally active 100+ MB transcript. The lost-completion recovery amendment is implemented: the heartbeat carries the runtime idle flag, `session_compact` reports the closing compaction boundary, and a Working row whose completion event never arrived resolves within one heartbeat interval.

## Purpose

Agent Visor supports interactive Pi coding-agent sessions as terminal-owned sessions. Pi support follows the same product model as Claude Code running in iTerm2: Agent Visor observes status and transcript evidence, returns the user to the exact terminal, and may submit text plus native-equivalent image paths without replacing Pi's native TUI.

This document defines the Pi-specific discovery, lifecycle, transcript, installation, and control contract. The shared surface contract remains [Product Surfaces](product-surfaces.md).

## Product Decisions

1. Pi support works without prior manual setup. Process and session-file observation provide the baseline.
2. When Pi is detected, Agent Visor automatically installs and maintains one bundled global Pi extension at `~/.pi/agent/extensions/agent-visor.ts`.
3. The extension is an enhancement, not a hard dependency. Removing it or failing to install it must not break discovery, history, or terminal navigation.
4. Agent Visor does not create `~/.pi` or install anything when Pi is not detected.
5. Settings always shows Pi. An unavailable installation appears as disabled `Pi — Not detected`.
6. Initial support covers existing interactive TUI sessions. Agent Visor does not launch arbitrary new Pi sessions. The only launch exception is one automatically claimed prior-boot restoration generation, where every process opens an exact previously live persisted session with `pi --session`.
7. Text and image-path submission to a terminal-owned Pi TUI are supported after terminal routing is verified. Agent Visor mirrors Pi's native clipboard-image convention without modifying Pi, mutating the system clipboard, or expanding the lifecycle extension protocol; source-specific interactive forms remain out of scope.
8. Pi receives `Needs attention` only from explicit evidence. Agent Visor does not infer it from silence, a long-running tool, or an extension dialog it cannot observe.
9. Pi's latest non-empty session name on the active transcript branch is authoritative. A rename replaces the previously displayed Pi name without requiring an Agent Visor restart; other agents retain their source-specific title precedence.
10. Agent Visor presents Pi as a prompt-bounded conversation, not a flat execution log. Work is grouped and collapsed by default while the final answer remains prominent; a user setting preserves access to the raw activity stream.
11. Restarting Agent Visor must not make a still-running interactive Pi session disappear. A Pi runtime that has loaded the current bundled extension periodically reasserts its exact live attachment; that signal proves liveness and routing metadata only, never new user or agent activity.
12. Agent Visor models one live runtime owner per durable Pi session ID. If an accidental second Pi TUI resumes the same session while the accepted owner PID remains alive, the existing owner stays pinned and every hook from the competing PID is ignored before it can alter phase, attachment, navigation, sending, or notification state. Ownership may transfer after the pinned owner exits. Independent concurrent branches and multiple pills for one Pi session remain out of scope.
13. Ready attention is identified by durable session ID. PID, TTY, terminal-host, or other attachment churn cannot by itself create another Ready episode, replay the completion sound, or bounce the menu-bar surface.
14. Transcript refresh work is bounded. Repeated hook and file-watcher signals may collapse into one running refresh plus one latest pending rerun, an unchanged file performs no read or UI replay, and an append decodes only newly added complete JSONL records. Large historical Pi files use a bounded summary path until the user or a live update requires full history.
15. Reboot restoration is exact-set and at-most-once. Agent Visor persists only accepted interactive Ghostty-owned Pi lifecycle metadata, freezes it for system power-off, removes intentionally ended sessions, gates launch on a different macOS boot identity, and never substitutes bare `pi`, `-c`, `-r`, CWD recency, or display names for the exact durable session path.
16. Lifecycle delivery is best-effort, so a lost completion event must not permanently misreport Working. The heartbeat carries the runtime's own idle flag, and an idle runtime resolves a row that Agent Visor still shows as Working. This is exact evidence from the reporting process, not an inference from silence, and it never promotes an Idle or Ready row to Working.
17. A compaction reports both of its boundaries. Manual `/compact` completes outside an agent run and therefore never reaches `agent_settled`, so the closing boundary — not the next user prompt — is what ends the Compacting state.

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

Zed-hosted Pi is the bounded processless exception. Zed runs `pi-acp` behind a Node worker that cannot be found by `pgrep -x pi`, but Zed's read-only thread store names the exact durable Pi session ID. While Zed is running, a non-archived `pi-acp` row joined to an existing Pi session file is source-confirmed live host evidence even though it has no per-session PID or TTY. It bootstraps Idle rather than Ended and remains read-only in Agent Visor; titles and navigation follow [Zed-Hosted Agent Integration](zed-integration.md). No title, path, or recency heuristic can manufacture this exception.

Creation-time matching is fallback evidence for a freshly created session, not a restart-recovery mechanism for resumed or imported sessions. The bundled extension is authoritative after `/new`, `/resume`, `/fork`, or another in-process session replacement because process start time no longer identifies the active session. Its periodic live-attachment heartbeat is also the authoritative mapping after Agent Visor itself restarts.

A discovery-created row cannot claim a PID that a different non-ended session already owns. Fallback creation-time matching can only ever pair a live process with its startup transcript; after that process runs `/new`, `/resume`, or `/fork` in place, discovery keeps re-finding the stale startup transcript for the same PID. Admitting it would republish a ghost row, infer a false Ready state for it, and shadow the authoritative hook-tracked owner's heartbeats until the next prune removed the duplicate. Discovery therefore defers to the existing live owner: a Pi discovery match is admitted only when no different non-ended session already holds its PID. This mirrors the heartbeat rule that a competing runtime cannot evict a different non-ended session that already owns the same PID.

When a Pi hook attaches a live PID but no controlling TTY, Agent Visor resolves the TTY from the live process itself and stores it. The bundled extension resolves its controlling TTY once at load with a bounded probe; if that probe is unavailable or times out under load, the process reports no TTY for its lifetime, so a resumed session can attach with a live PID but `tty` absent. Exact-terminal navigation, terminal-host detection, and terminal origin all require that TTY, so a background PID-to-TTY resolution keeps them correct without modifying the extension. The resolution is bounded to Pi and only fills a missing value; a TTY reported by the extension is never overridden, and no other provider forks a process for this.

Historical Pi sessions are included in the Sessions browser when their JSONL has a valid session header and renderable transcript evidence. They do not become menu-bar pills merely because a file exists.

Ephemeral `--no-session` runs have no durable identity and are ignored. Print, JSON, RPC, and SDK sessions may appear as saved history when persisted, but only interactive TUI sessions receive live pills and terminal navigation in the initial release.

## Restart Reattachment

Agent Visor's in-memory PID-to-session bindings are disposable. After the app relaunches, every still-running interactive Pi session that loaded the current bundled extension must reappear without waiting for transcript activity.

Reconciliation proceeds from strongest to weakest evidence:

1. An exact `SessionStart` received while Agent Visor is running attaches the reported session immediately, including same-PID `/new`, `/resume`, `/fork`, startup, and reload.
2. A periodic `SessionHeartbeat` reasserts the current session ID, PID, TTY, CWD, and session-file path. After Agent Visor restarts, an absent or historical row reattaches as live within one heartbeat interval.
3. Creation-time process matching remains the no-extension fallback for genuinely fresh sessions only.
4. Transcript growth may still recover a missed active turn, but user activity is not required for restart recovery.

A heartbeat is not phase or activity evidence, with one bounded exception. It must not refresh `lastActivity`, reorder an already tracked session, clear or create an approval, modify tool state, or promote a row to Working. When it restores an absent or historical row, Agent Visor uses Idle as the conservative live phase and retains transcript-derived activity time. A later transcript or lifecycle event may refine that phase normally.

The exception is the runtime's own idle flag, and it exists because lifecycle delivery is best-effort: the extension writes one short-lived socket per event with a 100 ms budget, no acknowledgement, and no retry. Every other repair path is deliberately closed for a hook-tracked Pi row — transcript inference stops once hook evidence exists, and only Ready has a staleness ceiling — so a single dropped `Stop` used to pin a finished session to Working until the user's next prompt. When a heartbeat reports that no agent run, retry, auto-compaction, or queued continuation is in flight while Agent Visor still shows Working, that row resolves:

- a completion boundary inside a short freshness window publishes Ready normally, because the recovery is standing in for the event that was lost;
- an older or unreadable boundary clears to Idle silently, so recovery never rings a notification for a turn that finished long ago;
- the transcript's last write is the completion boundary, taken from the exact session-file path the heartbeat already reports;
- a runtime that reports no flag keeps the previous phase-neutral behavior, which covers a live process still running an older copy of the extension.

Recovery is one-directional by design. A heartbeat sampled just before a completion cannot resurrect Working after the real `Stop` landed, and an approval or Ended row is never touched.

The ordinary same-PID late-event guard remains in force for heartbeats. A heartbeat may restore an Ended row only when the pre-merge attachment PID is absent or differs from the reporting PID. It also cannot evict a different non-ended session that already owns the same PID. These rules prevent an in-flight heartbeat from reviving a session after its matching `SessionEnd` or replacing a newer same-process session. Exact `SessionStart` remains the only Pi event allowed to transfer, replace, or reactivate an attachment under the same PID.

A separate same-session ownership guard applies before heartbeat handling and before generic lifecycle mutation. Once a Pi row has an accepted positive PID whose process remains alive, a Pi hook with a different or missing PID is competing evidence and is discarded in full. It cannot replace PID/TTY/host/origin, mutate phase or activity, update tool state, redirect navigation or delivery, restart a watcher, or resolve and recreate attention. When the pinned PID is no longer alive, the next exact Pi event may establish the replacement attachment through the existing heartbeat or lifecycle rules. After an Agent Visor restart, the first accepted exact report may establish the owner; later competing reports cannot make ownership oscillate.

This guardrail deliberately does not infer Pi branch identity, add a leaf ID to the extension payload, merge concurrent runtime phases, or manufacture multiple runtime rows. Those semantics require a separate product decision if independently active duplicate resumes become a supported workflow.

A live process using an older already-loaded copy of the extension cannot be upgraded invisibly. It continues through fallback behavior until the user runs `/reload` or starts Pi again; Agent Visor must not inject `/reload` or terminal input to force adoption.

## Reboot Restoration

Agent Visor maintains one atomic, schema-versioned restoration snapshot under its Application Support directory. Only accepted, persisted, interactive Pi runtimes whose canonical terminal host is Ghostty enter it. Historical rows, fallback-unmatched processes, print/JSON/RPC/SDK invocations, ephemeral sessions, subagents, other terminal hosts, and competing live owners are excluded.

The snapshot is keyed by durable Pi session ID and records exact session-file path, working directory, optional display name, last accepted attachment evidence, and optional Ghostty window/tab/terminal topology. Topology includes Ghostty's stable object identities; numeric positions are retained only for deterministic ordering because inserting a window or tab renumbers later positions. The snapshot contains no prompt, response, tool input, credential, or transcript content. PID and TTY locate the current terminal for capture but are never treated as valid authority after reboot.

Lifecycle rules are:

- an accepted live Pi event adds or refreshes an eligible entry;
- an entry whose session path stops being a persisted regular file is removed on the next accepted event or snapshot load; no negative cache prevents a later real file from being accepted again;
- `/new`, `/resume`, and `/fork` replace the old same-process identity with the newly authoritative session;
- `SessionEnd` or conclusive process death removes an entry while the machine remains up;
- macOS `willPowerOff` freezes the current generation before teardown, so later shutdown-driven end events cannot erase it;
- an app crash or power loss leaves the latest atomic active generation intact;
- a clean Agent Visor termination outside system power-off invalidates the snapshot because later Pi lifecycle changes would be unobserved.

At Agent Visor launch, macOS `kern.bootsessionuuid` separates ordinary same-boot reattachment from a genuine reboot. Agent Visor reads it through `sysctlbyname`, accepts only a valid UUID, and persists its canonical form. The same strict canonicalizer validates schema-3 snapshot authority before any snapshot is sanitized or used; malformed authority is removed, while noncanonical UUID casing is atomically rewritten before load returns. There is no boot-time, wall-clock, or uptime fallback.

If the live UUID is unavailable or malformed, restoration and all restoration lifecycle recording are disabled for that app run, no in-memory coordinator is created, and Agent Visor attempts to remove existing persisted restoration authority before returning. If durable cleanup fails, stale bytes may remain on disk; the failure is logged and restoration remains disabled for the current run.

When startup creates a fresh schema-3 coordinator because no authorized snapshot loaded, its initial empty baseline must reach durable storage before that coordinator can claim a prior generation or accept lifecycle mutations. If the baseline save fails, Agent Visor revokes the in-memory coordinator, leaves the baseline requirement unresolved, and disables both restoration and restoration lifecycle recording for the current app run.

Schema version 3 introduces the boot-session UUID identity. Unshipped schema-2 snapshots containing decimal boot timestamps are discarded rather than migrated or compared.

Same-boot launches never start Pi. An active same-boot snapshot remains in the same generation; normal heartbeats remain authoritative. A different boot may claim one active or frozen prior generation. The claim reaches disk before any AppleScript or process launch, and the generation cannot be claimed twice.

Every candidate must still have a real session file and working directory. Every launch uses the resolved Pi executable plus exact `--session <path>`. Missing or invalid candidates are skipped; Agent Visor never falls back to a new session, most-recent session, or interactive selector and never replays a prompt or tool call.

Before a prior-boot generation is claimed, the hook socket starts and Agent Visor waits one complete 10-second Pi heartbeat interval plus bounded scheduling slack. Exact lifecycle reports observed during that preflight are excluded from the claim regardless of their current host. Agent Visor filters exact live owners again immediately before automation, closing the race between durable claim and launch. These are durable-session-ID checks from Pi's own extension evidence; process existence, CWD, title, and transcript recency cannot suppress a required restore or authorize a duplicate.

Ghostty's own AppKit restoration then receives a bounded settle window. Agent Visor first reuses a captured terminal only when its stable identity still exists and its working directory matches. It injects the exact resume command into that fresh restored shell. Unmatched sessions are reconstructed through Ghostty's supported AppleScript `new window` and `split` commands: each captured tab becomes one window, and its captured panes become splits. Missing topology degrades to one deterministic fallback window per session. This avoids Ghostty 1.3's preview `new tab` failure when native tabs are hidden, which can create a surface before reporting an error. Unrelated surfaces are never closed or repurposed.

The bundled Pi extension remains socket-only and metadata-only. It writes no restoration registry. Therefore exactness is guaranteed only while Agent Visor was actively tracking the relevant lifecycle; sessions that start or end while Agent Visor is unavailable are not guessed later.

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
- reports `SessionHeartbeat` at a fixed 10-second cadence while that TUI runtime remains live, carrying the runtime's idle flag as metadata;
- probes that flag defensively, reporting none when the runtime does not expose it or the extension context has gone stale;
- clears the timer unconditionally during `session_shutdown`, before reporting the shutdown;
- returns immediately when Agent Visor's socket is absent, retaining no queue or deferred retry;
- never blocks Pi on Agent Visor availability or keeps the Pi process alive.

Lifecycle mapping uses Pi's public extension events plus the bounded extension-local timer:

| Source | Agent Visor evidence |
| --- | --- |
| `session_start` | Exact live attachment; idle/recent until turn evidence arrives |
| 10-second extension timer | `SessionHeartbeat`: attachment liveness, routing metadata, and the runtime idle flag |
| `agent_start` | Working |
| `tool_execution_start` | Working; optional tool name only |
| `tool_execution_end` | Working until the agent settles |
| `session_before_compact` | Working/compacting |
| `session_compact` | `PostCompact`: Working while the runtime reports busy, otherwise Idle |
| `agent_settled` | Ready |
| `session_shutdown` | Ended for that live attachment |

`agent_settled`, rather than low-level `agent_end`, is the completion boundary because Pi may still retry, compact, or process queued follow-up messages after `agent_end`.

`session_compact` reports Idle rather than Ready: a compaction finishing is not a turn completion, so it clears Compacting without manufacturing a Ready episode. Auto compaction runs inside an agent run, where the runtime still reports busy and the turn's own events remain authoritative.

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

## Transcript Refresh Performance

Pi lifecycle hooks and the provider-resolved file watcher are intentionally redundant evidence sources. Their redundancy must not become duplicate parsing work.

For each Pi session, SessionStore maintains a coalescing refresh state with at most one running refresh and one replaceable pending request. Signals received before a run starts reset the existing 100-millisecond quiescence window. Signals received while a run is active replace the pending request instead of starting or queueing another parse. Completion schedules only that latest pending request; continuous writes may produce later runs, but queue depth remains bounded at one pending request. Ending or removing a session cancels pending work and suppresses publication from an obsolete in-flight run.

The shared Pi conversation parser actor remains the global serialization boundary, so two Pi transcript parses never execute concurrently. Direct Chat history loads and file refreshes share the same per-session file cache. While mutating a cached parser, the actor temporarily removes it from the cache and restores it on every exit path; this preserves unique ownership of the typed tree index, avoids a copy-on-write clone after each append, and still retains the last good parser after a transient read failure.

Each cached file state records the resolved path, filesystem identity, byte count, and modification time:

- an identical signature returns unchanged without opening or replaying the transcript;
- growth of the same file identity reads exactly the byte range from the previous byte count to the captured new byte count;
- truncation, replacement, path change, or a same-size content modification discards the old index and performs one bounded rebuild;
- a failed read retains the last good state and is retried by later evidence rather than publishing an empty conversation.

The incremental parser retains a typed index of Pi entries by ID plus append order. It decodes only newly read complete JSONL records, preserves an incomplete trailing record until later bytes arrive, and reconstructs the latest active branch from the retained index after each accepted append. Unknown entry types remain parent-chain connectors but produce no visible content. The static whole-buffer parser delegates to the same accumulator so incremental and full parsing cannot drift semantically.

A changed active transcript may still publish a full canonical history to SessionStore; incremental UI deltas are not required by this amendment because Pi branch changes can replace the visible path. The expensive disk scan and JSON decoding are incremental. Exact duplicate signatures produce neither a replay nor a state publication.

Bootstrap metadata uses a separate bounded head-and-tail summary actor and signature cache. It must not enqueue a whole-file parse on the full-history actor merely to populate Sessions rows. Opening Chat or receiving a real live append may create the first full index for that session.

### Performance failure behavior

- A partial final JSONL record is withheld until complete; the prior valid conversation remains visible.
- Corrupt individual appended lines are ignored under the existing transcript contract.
- File replacement or truncation favors correctness through one rebuild rather than attempting to splice incompatible indexes.
- Coalescing never drops the latest file state: a signal observed during a run leaves one latest rerun pending.
- No lifecycle event, terminal route, completion boundary, active-branch rule, or provider model presentation changes as part of this work.

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
- every Pi hook first satisfies same-session runtime ownership: matching-owner events continue, competing events are ignored while the accepted owner process is alive, and a replacement PID is eligible only after owner loss;
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
- a competing live Pi runtime reporting the same session ID cannot replace the pinned PID or TTY and therefore cannot redirect navigation or terminal submission;
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

If multiple live Pi runtimes report the same durable session, Agent Visor retains the first accepted live owner and records rejected competing evidence diagnostically. It does not alternate the visible attachment or claim to represent both branches. Exiting the owner permits a remaining runtime to attach on its next exact report.

The initial release targets Pi's default `~/.pi/agent` directory. Custom `PI_CODING_AGENT_DIR` stores may be observed later when Agent Visor has explicit path evidence; Agent Visor must not guess shell-only environment overrides from a GUI launch context.

## Privacy And Security

The extension runs with the user's Pi process privileges, so its scope must remain auditable and minimal. Its local wire payload contains identifiers and lifecycle metadata only. Agent Visor already reads transcripts directly under Full Disk Access; duplicating conversation content over the socket is unnecessary and prohibited by this contract.

The socket's absence is a normal state. No busy retry loop, background daemon, remote telemetry, or external service is introduced for Pi integration. The only periodic extension work is one unreferenced, session-scoped 10-second timer. Each tick performs one socket-existence check and at most one bounded local connection attempt; failures are discarded without queueing, backoff state, disk writes, or user-visible errors.

## Initial Non-Goals

- Launching an arbitrary new Pi session from Agent Visor; only exact prior-boot restoration is allowed.
- Replacing Pi's TUI or exposing a second full composer workflow.
- Direct multimodal image-byte injection into a running Pi session or any modification of Pi's own package, settings, model catalog, or extension API.
- Pi account/provider usage aggregation.
- Generic detection of another extension's modal UI.
- Fabricating Needs attention without explicit evidence.
- Live pills for print, JSON, RPC, SDK, or ephemeral runs.
- Full support for custom Pi config roots in the first release.
- Independently representing multiple simultaneous Pi runtimes or transcript leaves that share one durable session ID.

## Test Contract

Core behavior tests must prove:

- active-branch reconstruction excludes abandoned Pi branches;
- transcript parsing maps messages, tools, results, compaction, model, and usage while tolerating unknown records;
- incremental chunks produce the same canonical transcript as a whole-buffer parse, including branch replacement and partial-line completion;
- an identical filesystem signature reads zero bytes, same-identity growth reads only the appended byte range, and truncation or replacement rebuilds once;
- repeated requests while a refresh is running retain only the latest pending request and never permit two runs at once;
- process/session matching uses CWD plus closest creation time and never assigns one session twice;
- unmatched processes do not fabricate sessions;
- baseline phase inference never fabricates Needs attention;
- an exact Pi `session_start` reattaches an Ended row even when its PID is unchanged, while an ordinary same-PID late hook does not;
- a Pi heartbeat reattaches a historical/Ended row when its pre-merge PID is absent or different, but cannot revive an Ended row under the same PID;
- a heartbeat cannot evict a different non-ended session already attached to its PID, while exact `SessionStart` can transfer that PID during an in-process replacement;
- a heartbeat preserves the phase, phase-evidence timestamp, last activity, approval state, and tool state of an already live row;
- a heartbeat-created or restored row retains transcript-derived activity time rather than appearing newly active merely because Agent Visor restarted;
- a matching PID may continue to update its Pi session, but a different or missing PID cannot alter an existing same-session attachment while the pinned owner process remains alive;
- after the pinned owner exits, an exact event from a replacement PID becomes eligible for the ordinary heartbeat or lifecycle path;
- Ready episode tracking uses durable session ID, so a metadata-only PID replacement cannot replay completion attention while the session remains continuously Ready, while a genuine leave-and-return to Ready remains eligible;
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
- SessionStore routes Pi signals through the one-running/one-latest coalescer and handles an unchanged provider outcome without publishing history;
- Pi full-history and live-refresh paths share the signature-aware incremental file parser, temporarily take the cached parser with guaranteed restoration to avoid copying its retained index, while bootstrap metadata uses the separate bounded summary path;
- Pi declares transcript session names authoritative and the shared metadata merge consumes that provider authority;
- window Chat enables Pi grouping by default, offers a raw-stream escape hatch, and suppresses the duplicate processing indicator when a live work header exists;
- Pi tool rows consume Pi-aware canonical names and grouped reasoning renders Markdown behind a nested disclosure;
- the bundled extension contains no network, prompt mutation, tool registration, or content-forwarding behavior;
- the heartbeat timer starts only after `session_start`, is unreferenced, has one instance per runtime, emits metadata only, and is cleared during every `session_shutdown` path;
- SessionStore evaluates same-session Pi runtime ownership before heartbeat disposition, PID deduplication, process-metadata merge, tool effects, or generic phase mutation;
- SessionStore handles `SessionHeartbeat` before generic lifecycle phase mutation and excludes it from user-activity refresh;
- the menu-bar completion sound and bounce track Ready session IDs rather than PID-bearing SwiftUI stable IDs;
- installation modifies only `agent-visor.ts` and is skipped when Pi is absent;
- reboot restoration accepts only exact interactive Ghostty-owned sessions, atomically claims a prior-boot generation before automation, and uses only `pi --session`;
- same-boot launch, sleep/wake, intentional Pi/Ghostty closure, missing files, and already-live exact owners produce no duplicate launch, including an owner reported during the bounded pre-claim heartbeat interval or the final pre-automation check;
- captured Ghostty surfaces are reused only when stable terminal identity and CWD agree, with unmatched sessions routed to the deterministic fallback layout;
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
16. a Pi runtime that loaded the pre-heartbeat extension remaining on documented fallback behavior until `/reload` or its next launch;
17. passive high-volume observation of a naturally active large Pi transcript, confirming bounded CPU bursts, no growing refresh backlog, and stable memory after the initial index build without submitting prompts solely for the test;
18. an explicitly authorized real machine restart with multiple Ghostty Pi sessions, including two exact sessions in one CWD and one intentionally closed session, confirming the pre-reboot eligible ID set equals the post-login restored ID set with no duplicate launches.

## TDD Implementation Plan — Bounded Transcript Refresh

Status: Implemented and signed-deployed on 2026-08-02. The captured regression was the signed Debug app repeatedly consuming approximately one CPU core while 40–105 MB Pi transcripts grew. An eight-second sample showed the main thread idle for most of the interval and background work repeatedly traversing `SessionStore.scheduleFileSync → PiAgentProvider.fileSync → PiConversationParser → PiTranscriptParser`, with a 1.4 GB observed peak footprint.

### Slice 1 — One running refresh plus one latest rerun

**RED:** Add pure coalescer examples proving that pre-run requests replace the pending value, requests during a run retain only the latest rerun, completion exposes at most that one rerun, and cancellation clears pending work. Add a SessionStore wiring regression requiring Pi to use this state before invoking the provider.

**GREEN:** Keep the existing debounce for the first/latest pending request, mark one latest request while a parse is running, and start it only after the active run completes. Preserve the existing scheduler for non-Pi providers unless shared extraction is proven behaviorally safe.

**REFACTOR:** Separate scheduling state from provider result application. Cancellation suppresses obsolete publication even when Foundation file or JSON APIs cannot be interrupted mid-call.

### Slice 2 — Signature-aware incremental file parsing

**RED:** Through a temporary real JSONL file, prove that the first read builds history, an unchanged signature reads zero bytes, an append reads exactly the appended byte count and preserves prior branch history, and truncation/replacement rebuilds. Add chunk tests for a JSON record split across appends and semantic equivalence with `PiTranscriptParser.parse(data:)`.

**GREEN:** Add a Core Pi transcript file parser that owns filesystem signatures, exact byte-range reads, a typed tree accumulator, and the last canonical transcript. Refactor the static parser to consume the same accumulator.

**REFACTOR:** Keep filesystem change policy, byte ingestion, typed entry projection, and active-branch materialization separate. Preserve unknown connectors and all existing parsed fields.

### Slice 3 — Provider cache and no-change propagation

**RED:** Add wiring coverage requiring Pi full-history and file-sync calls to share one parser cache and requiring exact duplicates to return an explicit no-change outcome that SessionStore ignores.

**GREEN:** Replace `PiConversationParser` whole-file reads with per-session incremental file states and one atomic projected-history result. A changed file continues through the existing canonical full-replay reducer path; unchanged evidence stops at the provider boundary.

**REFACTOR:** Remove multi-await cache assembly so messages, tools, results, marker, and conversation metadata always come from one parser snapshot. Take the cached parser out while mutating it and guarantee restoration on success and failure so appends do not trigger a copy-on-write clone of the retained tree index.

### Slice 4 — Bounded bootstrap summaries

**RED:** Add a large-file fixture whose active leaf and name live in the tail, and a wiring regression rejecting `loadConversationInfo → loadFullHistory` for Pi.

**GREEN:** Use the existing bounded JSONL head-and-tail reader on a separate Pi summary actor with signature caching. Project only `ConversationInfo`; do not populate the full-history index during bootstrap.

**REFACTOR:** Share Pi transcript-to-conversation projection without coupling the summary actor to full-parser mutable state.

### Slice 5 — Validation and signed deployment

Run all focused coalescing, file-parser, Pi transcript, provider-wiring, lifecycle, and packing tests; the complete AgentVisorCore suite; `git diff --check`; and an unsigned Debug app build. Then run `scripts/dev-build.sh`, validate the signed app, socket ownership, Accessibility health, embedded runtime, and passive CPU/memory behavior. Do not manufacture transcript activity, alter a terminal, or recreate competing Pi runtimes solely for acceptance.

## TDD Implementation Record — Bounded Transcript Refresh

Status: Implemented and signed-deployed on 2026-08-02.

- **RED:** Pure coalescer tests first failed because `TranscriptSyncCoalescer` did not exist. Filesystem fixtures then failed until unchanged signatures, exact append ranges, partial-line buffering, and replacement/truncation rebuilds existed. Wiring audits failed until SessionStore used the bounded Pi path, provider calls shared one parser cache, bootstrap stopped loading full history, unchanged outcomes stopped publication, and cached-parser mutation guaranteed restoration without a retained-index copy.
- **GREEN:** SessionStore now permits one active Pi refresh plus one replaceable latest rerun. `PiIncrementalTranscriptFileParser` performs zero reads for exact duplicate signatures, reads only appended bytes for same-file growth, buffers an incomplete final record, and rebuilds for incompatible mutations. `PiTranscriptParser` full and incremental entry points share one typed accumulator. Pi history projection is atomic, unchanged results stop at the provider boundary, and bounded bootstrap summaries use separate head/tail reads.
- **REFACTOR:** `JSONLLineIterator` uses bounded newline scanning; the full-history actor serializes all Pi parsing; cached parsers are taken and restored around mutation to preserve copy-on-write uniqueness; filesystem policy, entry ingestion, active-branch materialization, and app projection remain separate. No lifecycle, routing, model, completion, or Chat semantics changed.
- **Automated validation:** Focused coalescing, filesystem, parser-equivalence, summary, provider, lifecycle, and packing suites passed. The complete AgentVisorCore suite passed **1,796/1,796**; `git diff --check`, the unsigned Debug app build, and the signed development build passed.
- **Packing result:** A representative 12-candidate pressure/headroom probe reduced actual overflow text measurements from 709 to 7 and measured approximately 2.14 ms per Debug pack. Because the remaining pure variant search was already bounded and retained all accepted geometry, it was deliberately not replaced.
- **Signed deployment:** `scripts/dev-build.sh` relaunched `/Applications/Agent Visor Dev.app` as one process at PID `3755`. It owns `/tmp/agent-visor.sock`, Accessibility is Ready, deep strict signature verification passes with identifier `com.824zzy.AgentVisor.Dev` and authority `AgentVisor Dev`, and the embedded Codex runtime bundle passes validation.
- **Passive performance acceptance:** The naturally active Pi transcript was `107,702,627` bytes. After the one-time index build, an eight-second sample at `/tmp/agentvisor-performance-final-sample.txt` showed a 439.3 MB physical footprint and 646.5 MB peak, versus the diagnosed 629–656 MB steady footprint and 1.4 GB peak. A natural append used the incremental path with no full `PiTranscriptParser.parse` or index copy-on-write stack; Pi refresh work was a bounded fraction of the sample rather than the former sustained near-one-core decode loop. No prompt, terminal input, duplicate runtime, or synthetic completion was created for acceptance.

## TDD Implementation Record — Competing Live Pi Runtime Guardrail

Status: Implemented and signed-deployed on 2026-08-01. Automated ownership and Ready-identity regressions are complete; live validation deliberately did not recreate a competing Pi runtime.

The captured regression used Pi session `019fa69e-0555-795d-a356-07ab09c44c38` concurrently reported by PID `58775` on `ttys010` and PID `78443` on `ttys022`. Their 10-second heartbeats repeatedly replaced the row's PID-bearing `stableId`; competing lifecycle events also resolved and recreated the same `sessionId|turn` completion attention. After the user acknowledged the finished task, Agent Visor replayed its completion sound and resumed visual attention even though no intended new turn had completed.

### Slice 1 — Pure runtime ownership

**RED:** Add focused Core examples proving that a matching Pi owner remains accepted, a different or missing runtime PID is rejected while the existing owner process is alive, non-Pi providers are unaffected, and a replacement Pi PID becomes eligible after the owner exits.

**GREEN:** Add one pure ownership policy with only the evidence SessionStore already has: provider, row existence, existing PID, existing-process liveness, and event PID.

**REFACTOR:** Name the outcomes around accepted ownership versus ignored competing evidence; do not add branch, leaf, terminal, or transcript policy to this seam.

### Slice 2 — Guard every Pi hook before mutation

**RED:** Add a production-wiring regression requiring ownership disposition and its early return to precede heartbeat arbitration, PID deduplication, metadata merge, watcher changes, tool effects, and generic phase mapping.

**GREEN:** Evaluate existing-owner process liveness once at the start of `processHookEvent(_:)` and discard a competing Pi event before session state changes. Matching-owner and owner-dead events continue through the existing paths unchanged.

**REFACTOR:** Keep the guard shared by `SessionHeartbeat`, `SessionStart`, Working, Ready, tool, and shutdown events so no lifecycle subtype can bypass ownership.

### Slice 3 — Session-stable Ready episodes

**RED:** Add focused Ready-episode examples proving that the first Ready observation is new, repeated Ready evidence for the same session is not new even when attachment metadata changed, and leaving Ready before returning creates a genuine later episode. Add a wiring regression that rejects PID-bearing `stableId` in the menu-bar Ready tracker and timestamp lookup.

**GREEN:** Track Ready entry, checkmark timing, sound, and bounce by `sessionId`. Keep PID available only for the later terminal-focus decision.

**REFACTOR:** Concentrate the set transition in a small Core tracker instead of duplicating identity arithmetic in SwiftUI.

### Slice 4 — Validation and deployment

Run each focused RED → GREEN loop separately, then nearby Pi, lifecycle, attention, menu-bar, and source-wiring regressions; the complete AgentVisorCore suite; an unsigned app build; `git diff --check`; and `scripts/dev-build.sh`. Validate the signed development app, single-process/socket ownership, Accessibility readiness, and bundled runtime integrity without creating another Pi duplicate or submitting a prompt solely for testing.

### Validation record

- **Slice 1 RED:** `swift test --package-path AgentVisorCore --filter PiRuntimeOwnershipPolicyTests` failed because `PiRuntimeOwnershipPolicy` did not exist. GREEN added the pure first-live-owner policy; all six ownership examples passed.
- **Slice 2 RED:** the focused SessionStore wiring audit failed because no ownership guard existed. GREEN placed one early return before heartbeat disposition, PID deduplication, metadata merge, tool effects, and generic phase handling. Matching-owner and owner-dead evidence retain the existing paths.
- **Slice 3 RED:** the tracker tests first failed because `ReadySessionEpisodeTracker` did not exist; the production-wiring regression then failed nine assertions because `NotchView` still used PID-bearing `stableId`. GREEN moved entry detection, timestamps, checkmarks, sound, and bounce to durable `sessionId`; terminal-focus checking still receives the exact PID.
- **Refactor:** Ready set-transition arithmetic moved into the small Core tracker, and ownership outcomes remain isolated from transcript or branch semantics. The combined Pi ownership, heartbeat, notification, and Ready-attention suite passed 40 tests.
- **Full validation:** the complete AgentVisorCore suite passed 1,782 tests with zero failures; `git diff --check` and an unsigned Debug app build passed.
- **Signed deployment:** `scripts/dev-build.sh` succeeded and relaunched `/Applications/Agent Visor Dev.app` as one process at PID `77059`. The app owns `/tmp/agent-visor.sock`, Accessibility reached Ready, deep strict code-signature validation passed, and the embedded Codex runtime passed its bundle audit. Bundled and installed Pi extension SHA-256 values remain byte-identical at `4191e1e3c2ac3681da6582ed6b1656a2fb15678cfa7abb70f8a8a4a25b080375`.
- **Live boundary:** after the user removed the accidental duplicate, only PID `78443` remained attached to `intern-paper`. Agent Visor did not recreate a duplicate, submit a prompt, or mutate terminal state solely to exercise the rejection branch.

## TDD Implementation Record — Controlling TTY Backfill

Status: implemented on 2026-08-03 to restore navigation for a resumed Pi session that attached without a TTY.

The captured regression is Pi session `019fb500` (donut-failure-mode) resumed in live PID `11882` on `ttys001`. Its pill resolved correctly on click, but navigation failed with `ghostty focus … result=fail reason=noTTY` and `nav fallback=none reason=exactFocusFailed`, because the tracked session had `pid=11882 tty=none`. The bundled extension resolves the controlling TTY once at module load with a 100 ms `/usr/bin/tty` probe and swallows failures; PID `11882` started during the post-restart load spike, so its probe returned no TTY, and every hook for that process reported `tty` absent. `HookProcessMetadataPolicy.merge` keeps `reported.tty ?? existing.tty`, so the session never gained a TTY. This is a pre-existing fragility, not a regression from the discovery-ownership or window-activation work: the extension is byte-identical and the hook TTY-merge path was unchanged.

### Slice 1 — Pure backfill decision

**RED:** Add focused Core examples proving Agent Visor resolves a Pi runtime's TTY only when the provider is Pi, a positive PID is present, and the TTY is missing (nil or empty); a reported TTY is never overridden, and non-Pi providers never trigger a resolution.

**GREEN:** Add one pure `PiTtyBackfillPolicy.shouldResolveTTY` using only provider, PID, and current TTY.

**REFACTOR:** Keep the decision free of process I/O so the resolver stays a thin, replaceable side effect.

### Slice 2 — Resolve in the hook path before origin

**RED:** Add a production-wiring regression requiring the hook path to consult `PiTtyBackfillPolicy.shouldResolveTTY` after the PID/TTY merge and apply the resolved TTY before terminal-host detection and terminal-origin resolution, so a backfilled TTY promotes the session to terminal ownership rather than observed.

**GREEN:** After `HookProcessMetadataPolicy.merge`, resolve the controlling TTY from the live PID (`ps -p <pid> -o tty=`, normalized) when the policy allows, and use that resolved TTY for `session.tty`, the derived-metadata refresh test, and `originForHostedSession`. Resolution runs at most once per session because the resolved TTY then satisfies the merge on later heartbeats.

**REFACTOR:** Reuse the existing `ps`/`TTYNormalizer` pattern and leave the extension, heartbeat cadence, and merge rule unchanged.

### Validation record

- **Slice 1 RED/GREEN:** the policy tests failed to compile until `PiTtyBackfillPolicy` existed, then all examples passed.
- **Slice 2 RED/GREEN:** the hook wiring audit failed until the resolver and its ordering existed, then confirmed the merge → backfill → origin sequence.
- **Full validation and signed deployment:** recorded after the run below.

## TDD Implementation Record — Fallback Discovery Ownership

Status: implemented on 2026-08-02 to close a latent discovery/ownership gap observed live.

The captured regression is one Pi process (PID `70934`, `ttys012`, `/Users/zhengyuanz/Codes`) started at `22:34:52`, whose startup transcript `019fc61e-2ab1-769a-82c0-0b570eae1751` was created 1.6 seconds later and then abandoned after an in-process `/resume wayfinder`. The process continued in the pre-existing `wayfinder` session `019fbe8b-bd10-74d6-8e73-661c799ca465`, which is tracked through hooks. Fallback creation-time discovery kept re-matching PID `70934` to the abandoned startup transcript. Every ~30-second rediscovery re-inserted a nameless `Codes` row, inferred a false `waitingForInput` for it, emitted Ready attention, and briefly caused `wayfinder` heartbeats to be ignored, before the ~3-second prune removed the duplicate PID row. Across the sampled window this produced 54 flicker cycles at roughly 36-second spacing.

### Slice 1 — Pure discovery ownership

**RED:** Add focused Core examples proving a Pi discovery match is rejected when its PID already belongs to a different non-ended session, is admitted when the PID is unowned, is always admitted when the discovered row is historical (no PID), and never gates non-Pi providers that intentionally share a host process.

**GREEN:** Add one pure `admitsDiscoveredSession` decision reusing the existing accept / ignore-competing-runtime outcome and only the evidence the store already computes: provider, discovered PID, and whether that PID is owned by a different live session.

**REFACTOR:** Keep the discovery seam free of branch, leaf, terminal, or transcript inference; it only defers fallback discovery to an existing live owner.

### Slice 2 — Guard bootstrap before insertion

**RED:** Add a production-wiring regression requiring the ownership guard to run after the hidden-row filter and before both the existing-row merge and any new-row insertion inside `bootstrapSessions`.

**GREEN:** Compute `pidOwnedByOtherLiveSession` inline the same way the heartbeat path computes its PID-collision evidence, then continue past a rejected Pi discovery without creating, refreshing, watching, or publishing a row.

**REFACTOR:** Leave the fresh-session, historical, Codex, and Cursor discovery paths unchanged; only a Pi row whose live PID is already owned is skipped.

### Validation record

- **Slice 1 RED:** `PiRuntimeOwnershipPolicyTests` failed to compile because `admitsDiscoveredSession` did not exist. GREEN added the pure decision; the four new discovery-ownership examples passed.
- **Slice 2 RED:** the bootstrap wiring audit failed because no guard existed. GREEN placed one `continue` guard after the hidden filter and before the merge and insert paths. The audit then confirmed ordering and evidence.
- **Full validation:** the complete AgentVisorCore suite passed 1,801 tests with zero failures; `git diff --check` passed; the change touches exactly five paths (the policy, its two test files, `SessionStore.swift`, and this doc).
- **Signed deployment:** `scripts/dev-build.sh` built and relaunched `/Applications/Agent Visor Dev.app` as one process at PID `25797`. It owns `/tmp/agent-visor.sock`, Accessibility transitioned `needsAccessibility → verifying → ready`, deep strict signature verification passed with identifier `com.824zzy.AgentVisor.Dev` and authority `AgentVisor Dev`, and the embedded Codex runtime bundle passed. Bundled, source, and installed `agent-visor.ts` SHA-256 remain byte-identical at `4191e1e3c2ac3681da6582ed6b1656a2fb15678cfa7abb70f8a8a4a25b080375`.
- **Live boundary:** the machine restart cleared the original ghost (PID `70934` / transcript `019fc61e`), so the exact flicker was not reproducible after deployment and no competing Pi runtime was manufactured to force the rejection branch. The guard is deployed and stays quiet until a resume ghost recurs, at which point it logs `Ignoring Pi discovery for …`.

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

Changes that make the extension mandatory, add content beyond exact lifecycle metadata to its wire payload, let heartbeat evidence mutate activity or promote a row to Working, increase heartbeat frequency, introduce Needs attention inference, enable arbitrary new-session launching, broaden reboot restoration beyond exact interactive Ghostty-owned sessions, weaken boot/claim/identity gates, independently represent multiple live Pi runtimes or branches under one durable session ID, or trade active-branch correctness for a flat/tail-only live transcript require an explicit design update before implementation.

The one accepted phase exception is the runtime idle flag clearing a stale Working row, bounded as described in [Restart Reattachment](#restart-reattachment). Widening it — promoting phases from a heartbeat, treating silence as idle, or inferring attention — requires a new design decision.

## TDD Implementation Record — 2026-08-05 (Lost Completion Recovery)

Observed regression: a Pi session whose turn ended at 18:07:45 still rendered the orange Working dot at 18:28. The runtime did emit `agent_settled` — an unrelated extension listening to the same event posted its request at 18:07:45.264 — but Agent Visor's row never left `.processing`, and the discovery log contained no phase line for that session at all. Delivery was lost on the best-effort socket, and no repair path existed: transcript inference is disabled once hook evidence exists, heartbeats were phase-neutral, and `HookReadyExpirationPolicy` expires only Ready.

- **Slice 1 — pure recovery policy:** `PiIdleHeartbeatRecoveryPolicy` decides whether an idle heartbeat clears a Working row and whether the repaired completion is fresh enough to still publish Ready. `shouldResolveCompletionBoundary` keeps a phase-neutral heartbeat off the filesystem. 10 focused tests cover the missing flag, the busy runtime, both freshness sides, an unreadable boundary, clock skew, and the one-directional scope guard.
- **Slice 2 — SessionStore seam:** `recoverStuckPiWork` applies the outcome inside the existing phase-neutral heartbeat branch, respects the phase state machine, keeps hook evidence so the Ready ceiling still applies, schedules the file sync the dropped event would have carried, and logs `[Phase] pi … (idle heartbeat, was …)` so the next regression is diagnosable from the same log that exposed this one.
- **Slice 3 — compaction boundary:** the extension subscribes to `session_compact` and reports `PostCompact`, which the existing lifecycle policy maps from the reported status. This closes the deterministic sibling defect: manual `/compact` never reaches `agent_settled`, so Compacting previously persisted until the next prompt.
- **Validation:** the complete AgentVisorCore suite passed 1,852 tests with zero failures; the bundled extension passed a strict TypeScript check against Pi's own type definitions and a transpile check.
