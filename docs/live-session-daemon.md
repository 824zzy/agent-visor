# Live session daemon

The TypeScript daemon now owns session discovery, normalized session summaries, hook phases, snapshot revisions, and local event delivery.

For the 2.7.0 stable Electron cutover, the daemon is the user-facing session
source for the Electron shell. The signed Swift helper remains the native
macOS boundary. The Swift v2.6.1 application is retained as the exact rollback
target.

The daemon always reads provider-owned transcripts, SQLite databases, hooks,
and session records in place. They are outside Electron profile migration.
Only the Agent Visor staging Electron profile can be copied into the stable
Electron profile. If staging is live, import waits, the source remains
untouched, and transient Electron lock markers are excluded from the copy.

## Provider boundaries

Each provider keeps a separate adapter and naming parser:

- Claude Code reads live per-process metadata and Claude JSONL title records. Non-terminal hooks require a matching provider row; terminal hooks retain immediate TTY identity.
- Codex reads the active thread database, session index titles, rollouts, CLI processes, and recent Codex app threads.
- Pi pairs exact transcript headers with live processes and follows Pi’s active record branch for names.
- Resumed Pi sessions use validated hook session IDs, process IDs, TTYs, working directories, and transcript paths to recover exact terminal targets.
- Cursor pairs CLI processes and recent IDE transcripts through Cursor’s project-key rules.
- Zed reads hosted thread identity, title authority, worktrees, and underlying provider identity from Zed’s database.
- Auggie remains hook-only because its transcript layout is not verified.

No generic title parser combines provider formats.

## State

`SessionRepository` normalizes provider rows and capabilities, applies hook phases, resolves host authority, and increments its revision only when visible content changes.

### Codex desktop lifecycle

Codex desktop status comes from its exact rollout's latest turn boundary, not
the last arriving hook. `task_started` means Working; `task_complete` and
`turn_aborted` mean Ready. Explicit terminal turn IDs must match the active turn;
older timestamps and duplicate starts cannot revive or finish a newer turn.
Legacy records without turn IDs use their ordered transcript boundaries.

This restores Swift's desktop transcript reconciliation. Once a boundary is
known, delayed Stop, SessionStart, and tool hooks cannot overwrite it. A current
approval hook still shows Needs you while that turn is open; a terminal marker
clears it. Registered Chat approvals retain their existing authority. Codex CLI
and the other providers keep their existing hook policies.

The reader retains at most 200 small checkpoints, reads only bounded line
prefixes, and resumes at the last complete newline. It recognizes the canonical
header even when a completion record embeds a large final answer. Unchanged
files are cached, failed/partial reads retry, and truncation or a replaced path
resets the checkpoint. The first read streams the existing transcript; later
refreshes scan only appended bytes. It never retains message or tool bodies.

Updates use the existing three-second discovery cycle, including when Chat is
closed or the daemon restarts. Recent completed turns show Ready for 30 minutes,
then History; this does not change the configurable observed-session window,
source navigation, or Open Chat. An open turn is not declared completed by an
inactivity timer.

### Provider recovery and clients

Unmatched Pi hooks wait for provider validation. A hook without a durable transcript cannot advertise an exact source action or become a physical pill.

A transient provider failure retains that provider’s last complete rows. Empty Codex and Zed database reads do not replace a previous non-empty read.

Pi heartbeats update exact runtime identity without refreshing phase or activity. An idle heartbeat repairs only a Working row: recent transcript writes become Ready, while older or unreadable writes become History without attention.

Pi Ready hook evidence expires after the shared 30-minute stale ceiling. Rediscovery then supplies the History presentation while preserving any live owner navigation.

A bounded, boot-scoped Pi runtime-link file preserves exact focus across daemon restarts. Fresh provider discovery must validate each link before use.

Connected clients receive later revisions automatically. A reconnect receives the current revision without rebuilding session identity.

Renderer clients treat both clean closes and socket errors as disconnected. They stop presenting the cached snapshot as live, retry the local daemon with capped backoff, and repeat each subscription after reconnecting.

## Machine work

Machine reads and transcript summaries use separate bounded work limits.

Every short-lived child process has a deadline, an output limit, and process-group cleanup. Retained output pipes cannot hold a read open after its deadline.

The live refresh interval is three seconds. Overlapping refreshes are skipped.

Scheduled work reports rejected operations without terminating the daemon or its signed helper.

## Hook socket

The daemon owns `/tmp/agent-visor.sock` in the stable Electron release, which
preserves the released hook path.

The socket has mode `0600`, validates payload size and shape, and refuses to unlink another active owner.

During parallel development, set `AGENT_VISOR_HOOK_SOCKET` to a separate path.
The Swift v2.6.1 rollback application uses the same public hook path after the
Electron process has exited.

Permission responses continue through the signed Swift helper. Electron owns
the daemon route and the user-facing Chat action in 2.7.0; provider-specific
capability checks still fail closed when an exact route is unavailable.

## Rollback

The exact rollback artifact is Agent Visor v2.6.1 build 53. Quit the Electron
application, install the verified
[v2.6.1 ZIP](https://github.com/824zzy/agent-visor/releases/download/v2.6.1/AgentVisor-v2.6.1.zip), and launch the Swift application from
`/Applications`. Keep the production Electron profile
(`~/Library/Application Support/Agent Visor`) for diagnosis; the staging
source (`~/Library/Application Support/Agent Visor Next`) remains untouched.
Do not run `brew uninstall --zap` while retaining diagnostic profiles, because
zap removes the application data paths. The rollback does not require moving
provider-owned live sources.

## Physical reboot acceptance

Same-boot and exact-runtime checks pass. Restoration after an actual macOS
reboot has not completed real-machine acceptance and is deferred from the
verified 2.7.0 release scope.

## Checks

```sh
npm test
npm run typecheck
npm run build
npm audit --omit=dev
```
