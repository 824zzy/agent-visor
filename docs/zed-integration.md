# Zed-Hosted Agent Integration

Status: Accepted
Last reviewed: 2026-08-12
Implementation status: First-class identity, discovery, read-only Chat, and verified best-effort thread reveal are implemented for external ACP agents whose canonical transcripts Agent Visor already supports. Signed development deployment is complete; the full live acceptance matrix remains pending.

## Purpose

Zed can host Claude Code, Codex, and Pi through ACP. Those agents continue to write their canonical transcript files, but Zed owns the thread title, workspace, lifecycle surface, and composer the user sees. Agent Visor must therefore join the agent's durable session ID to Zed's read-only thread metadata instead of presenting the child as a terminal or as the agent's standalone desktop app.

This document defines the Zed-specific identity, discovery, liveness, navigation, and failure contract. Shared surface semantics remain in [Product Surfaces](product-surfaces.md); Pi transcript and lifecycle behavior remains in [Pi Integration](pi-integration.md).

## Product Decisions

1. Zed's non-archived `sidebar_threads` row is authoritative evidence that Zed hosts the external agent session ID.
2. The Zed title shown to the user, including `title_override`, owns the Agent Visor session name. Agent-derived names cannot replace it while Zed hosts the thread.
3. Zed-hosted sessions are read-only in Agent Visor Chat. Agent Visor does not inject prompts into Zed's ACP composer.
4. A normal pill or owner action returns to Zed. Agent Visor attempts an exact thread reveal only when the title query identifies one non-archived row and the user has not disabled Zed thread reveal.
5. Exact reveal uses Zed's documented default keyboard path because Zed exposes no existing-thread deep link, CLI flag, or accessible sidebar-row tree. The path must minimize visible transitions and must not type command-palette action names when direct shortcuts exist. Every attempt verifies the resulting persisted Agent Panel selection before claiming success.
6. Failure is honest and non-destructive. Agent Visor activates the correct Zed channel and worktree, then shows a thread-name toast when exact reveal is unavailable, ambiguous, remapped, or unverified.
7. Zed's SQLite stores are read-only implementation evidence. Agent Visor uses `/usr/bin/sqlite3 -readonly`, observes the WAL signature, never migrates or writes Zed state, and fails closed when the expected schema is unavailable.
8. Zed-native threads without a supported external transcript owner remain out of scope. Agent Visor does not fabricate mirrored history from Zed's private conversation storage.

## Channel And Database Resolution

Zed Stable, Preview, Nightly, and Dev have distinct bundle identifiers and database scopes under one Application Support directory. Agent Visor recognizes all four channels.

When one channel is running, its database wins over fresher databases from quit channels. If several channels run simultaneously, the freshest running database is the single observed source for that refresh. Stable ordering breaks exact freshness ties. Supporting simultaneous independent thread catalogs from multiple running channels is a future extension; Agent Visor must not merge rows heuristically across stores.

The selected database is watched through both `db.sqlite` and `db.sqlite-wal`. An unchanged signature reuses the cached snapshot. Empty or failed reads are not cached, allowing a later refresh to recover from a concurrent Zed commit or an older schema.

## Identity And Discovery

A Zed row joins to Agent Visor by the external agent's exact durable `session_id`; titles, paths, PIDs, and recency are never identity heuristics.

- Claude and Codex may already be discovered through their canonical stores or process trees. Reconciliation changes their host to Zed, removes borrowed/shared process metadata, and applies Zed's title.
- Pi ACP children are not visible to `pgrep -x pi`. While Zed is running, Pi discovery joins non-archived `pi-acp` rows to existing Pi session files by exact session ID and declares `.zed` as the live host.
- A source-confirmed Zed thread is live even without a meaningful per-session PID. The pid-zero historical sentinel does not mark it Ended.
- Archived rows are not live host evidence. Historical transcripts may remain available under their provider's ordinary history policy.

## Liveness

Zed pools or hides ACP workers, so PID ownership cannot decide per-thread liveness.

- Zed not running is conclusive host-death evidence for tracked Zed sessions.
- While Zed runs, a non-archived exact row remains the host authority.
- Transcript activity drives the existing observed-session retention window where no provider lifecycle event can prove closure.
- Provider lifecycle evidence may end a hosted session immediately.
- Several Zed threads may legitimately share one worker PID; PID deduplication must not collapse them.

## Navigation

Navigation proceeds as follows:

1. Resolve the running Zed channel and the thread's recorded worktree.
2. Open or raise that worktree through Launch Services.
3. Verify Zed is frontmost.
4. If exact reveal is enabled and the normalized 48-character title query is unique, use the command palette only as a transient non-sidebar focus anchor, then dispatch Zed's direct workspace-sidebar shortcut and filter by title.
5. Read the frontmost window's active workspace and Agent Panel selection from Zed's persisted state.
6. After verified selection, clear the sidebar filter and use Zed's direct Agent Panel shortcut to focus the active composer.
7. Report success only when the selected thread or session ID equals the target; otherwise show an actionable fallback toast.

The reveal must not type action names into a visible command palette. Deliberate cleanup waits stay bounded to 240 milliseconds under default settings. Focus is checked before every synthetic step so text cannot spill into another application. Users with remapped Zed keys can disable **Open exact Zed thread** in Settings; activation and the identifying toast remain available.

## Privacy And Security

Agent Visor reads only thread identity, title, worktree, archive state, timestamps, and the active Agent Panel selection needed for verification. It does not read Zed-native conversation content, write Zed's database, alter key bindings, send network requests, or inject prompts.

Synthetic keystrokes are limited to the user-visible reveal action after Zed is frontmost. No background discovery path sends keyboard input or activates Zed.

## Failure Behavior

- Missing Zed installation or database: no Zed-specific rows or mutation.
- Unsupported schema or transient SQLite failure: return an empty uncached snapshot and retry on a later refresh.
- Missing title: activate Zed and identify that the thread is not named yet.
- Duplicate reveal query: activate Zed and ask the user to select the named thread.
- Remapped or ignored keys: verification fails; Agent Visor does not claim exact navigation.
- Different thread selected: report the mismatch and leave Zed in control.
- Zed closes during the sequence: abort as soon as frontmost ownership is lost.

## Test Contract

Automated coverage must prove:

- all supported channel bundle IDs and database scopes resolve deterministically;
- running-channel selection outranks a stale quit channel and WAL freshness counts;
- exact session IDs map Zed rows to supported external agents;
- Zed title override wins and agent-derived names are suppressed;
- source-confirmed pid-zero Pi threads bootstrap live rather than Ended;
- Zed-hosted sessions skip shared-PID deduplication and provider-specific desktop attribution;
- reveal refuses empty and ambiguous queries;
- reveal planning orders focus, replacement, selection, and confirmation deterministically;
- reveal planning uses direct Zed shortcuts rather than typed action queries, and composer cleanup adds no more than 240 milliseconds of deliberate waits;
- verification accepts equivalent UUID/hex thread IDs and reports a different selection honestly;
- the Zed adapter never reports successful text delivery;
- terminal routing uses the dedicated Zed adapter and does not fall through to another host.

Manual release acceptance must cover:

1. Stable Zed with two Pi threads in one worktree;
2. generated titles and user renames updating Agent Visor without restart;
3. normal pill navigation revealing each exact thread;
4. duplicate titles producing the fallback rather than a false exact result;
5. reveal disabled in Settings;
6. remapped-key failure producing an honest fallback;
7. one Zed-hosted Claude and one Codex thread retaining Zed ownership;
8. archived/closed threads leaving the live surface;
9. quitting Zed removing live hosted rows;
10. one available non-stable channel, and a bounded check with two channels running.
