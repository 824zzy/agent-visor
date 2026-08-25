# Live session daemon

The TypeScript daemon now owns session discovery, normalized session summaries, hook phases, snapshot revisions, and local event delivery.

The Swift release remains production until the complete parity checklist passes.

## Provider boundaries

Each provider keeps a separate adapter and naming parser:

- Claude Code reads live per-process metadata and Claude JSONL title records.
- Codex reads the active thread database, session index titles, rollouts, CLI processes, and recent Codex app threads.
- Pi pairs exact transcript headers with live processes and follows Pi’s active record branch for names.
- Resumed Pi sessions use validated hook session IDs, process IDs, TTYs, working directories, and transcript paths to recover exact terminal targets.
- Cursor pairs CLI processes and recent IDE transcripts through Cursor’s project-key rules.
- Zed reads hosted thread identity, title authority, worktrees, and underlying provider identity from Zed’s database.
- Auggie remains hook-only because its transcript layout is not verified.

No generic title parser combines provider formats.

## State

`SessionRepository` normalizes provider rows and capabilities, applies hook phases, resolves host authority, and increments its revision only when visible content changes.

A transient provider failure retains that provider’s last complete rows. Empty Codex and Zed database reads do not replace a previous non-empty read.

Pi heartbeats update exact runtime identity without refreshing phase or activity. An idle heartbeat repairs only a Working row: recent transcript writes become Ready, while older or unreadable writes become History without attention.

A bounded, boot-scoped Pi runtime-link file preserves exact focus across daemon restarts. Fresh provider discovery must validate each link before use.

Connected clients receive later revisions automatically. A reconnect receives the current revision without rebuilding session identity.

## Machine work

Machine reads and transcript summaries use separate bounded work limits.

Every short-lived child process has a deadline, an output limit, and process-group cleanup. Retained output pipes cannot hold a read open after its deadline.

The live refresh interval is three seconds. Overlapping refreshes are skipped.

## Hook socket

The daemon can own `/tmp/agent-visor.sock`, which preserves the released hook path.

The socket has mode `0600`, validates payload size and shape, and refuses to unlink another active owner.

During parallel development, set `AGENT_VISOR_HOOK_SOCKET` to a separate path. The Swift release continues owning the public hook socket.

Permission responses remain with the Swift release until Chat parity moves approval handling. The Electron application is not a production replacement before then.

## Checks

```sh
npm test
npm run typecheck
npm run build
npm audit --omit=dev
```
