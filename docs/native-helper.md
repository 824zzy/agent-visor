# Native macOS helper

The migration keeps one small Swift process for macOS-only operations.

The TypeScript daemon owns providers, sessions, transcripts, Chat, and settings. The helper does not parse provider data.

## Transport

The helper accepts framed JSON through a local Unix stream socket.

Each frame starts with a four-byte, unsigned, big-endian payload length. A payload cannot exceed 1 MiB.

The helper creates its parent directory with mode `0700` and its socket with mode `0600`. It accepts connections only from the current user.

Start it with:

```sh
AgentVisorNativeHelper --socket "$AGENT_VISOR_HELPER_SOCKET"
```

## Protocol

Every request contains protocol `version: 1`, a non-empty `id`, and one method:

- `screen_topology` returns screen names, built-in and main-screen roles, frames, visible frames, and scale factors.
- `accessibility_status` returns the current Accessibility trust state.
- `request_accessibility` asks macOS for Accessibility access.
- `open_accessibility_settings` opens the macOS repair destination.
- `notification_status` returns the modern notification permission state.
- `request_notifications` asks macOS for notification access.
- `reconcile_notifications` accepts bounded notices and removes resolved notices.
- `reconcile_pi_restoration` accepts bounded exact candidates, current live session IDs, candidate-removal IDs, and the clean-termination signal.
- `present_pills` accepts at most 64 active or recent physical pill descriptions and an optional `navigatorPills` catalog of at most 512 bounded rows, plus bounded optional inspector content, eight usage glances, session shortcuts, the window hotkey, pill-screen selection, and full-screen policy.
- Each optional navigator row may carry `defaultOverflowEligible`. Explicit `true` rows that are not physical candidates contribute to the default `+N`; explicit `false` rows remain searchable-only (the automation contract). An omitted field preserves old-wire helper behavior: it is not inferred from catalog membership, while a hidden physical `pills` row still contributes to `+N`.
- Each usage glance may include two bounded limit windows, fixed capsule width, per-window tone, reset times, reset-credit count, sync time, and stale state.
- `focus_terminal` selects one allowlisted terminal through its exact TTY.
- `prepare_terminal` prepares a Ghostty surface for an exact PID/start-token/TTY/directory tuple. Background preparation writes a unique OSC 7 directory locator as terminal metadata, finds one matching surface, and restores the directory metadata before publishing the route. It sends no input and does not focus or activate a window. The optional `conversationOnly` policy defaults to true for preparation: Claude needs a current conversation footer; generic terminal providers pass false. Prepared focus passes the same policy through `focus_terminal`, checks the live process, Ghostty instance, exact surface, title and directory, then uses Ghostty's native AppleEvent focus command and verifies the result. Claude additionally checks its footer before and after focus. Failed preparation or changed/overview evidence fails closed. Omitting the focus policy preserves the legacy terminal protocol for older callers.
- `prepare_ghostty_binding` captures a Herdr client-to-Ghostty capability while a unique title lease proves the association. It accepts at most four exact process identities: foreground client, provider, server and optional CLI wrapper. The helper captures precise kernel start times and TTYs, plus the Ghostty instance and surface ID. The daemon releases the temporary title lease before publishing the route. Prepared navigation validates that capability, fresh socket/client/target state, guarded pane selection, applied-navigation receipt and exact native focus. A helper restart or changed route permits one guarded recovery and rebuilds the capability for later clicks.
- `open_claude_attach` runs `claude attach <jobId>` in a new window of the running Ghostty. It needs an absolute working directory and executable, and an eight-character hexadecimal job ID. It clears `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` only for the new client, including its overview; it cannot change an existing background worker's title state. It never starts a second Ghostty, because that copy would take over Ghostty's AppleScript and break `focus_terminal`.
- `open_ghostty_resume` accepts one structured `claude_code` or `codex_cli` target: attempt and full session IDs, absolute executable and working-directory references, validated configuration/settings/profile references, profile state, and a one-shot nonce. It returns `ghostty_resume_dispatched` only after the existing Ghostty process and the created window, tab, terminal, process-start token, and nonce have been read back exactly. An explicit Resume may launch the canonical Ghostty application when it is not running, but never creates a second instance and never retries an uncertain creation.
- `read_process_provenance` accepts an exact PID, provider, process-start token, and home-directory reference. Its available response contains only sanitized canonical executable/configuration/profile/settings references, allowlisted setting sources and override names, argv completeness, observation time, and the one-shot resume nonce; an unavailable response carries a bounded reason. PID reuse, ambiguous argv, untrusted paths, or failed reads remain unavailable.
- `ghostty_terminal_views` returns current stable terminal identities, titles, and working directories. The optional `titleUpdatesEnabled: true` capability is minted only for helper-created, explicitly configured attachment surfaces and is scoped to the Ghostty process instance; closing a surface removes it. The same helper connection retains that ownership across view and focus requests. `focus_ghostty_terminal` rejects a claimed capability for an unowned surface. An unreadable, invalid, or changed application snapshot returns a failed response rather than a successful empty list. No running Ghostty or a valid empty terminal list returns an empty list.
- `send_terminal` sends bounded text to that exact terminal and optionally submits it.
- `focus` requires an exact process identifier and bundle identifier. A window identifier is optional.

Unknown methods, extra fields, oversized frames, invalid identifiers, and malformed JSON are rejected.

Resume and provenance requests are intentionally narrow. The wire contract carries typed IDs, nonces, references, and exact receipts rather than shell text or provider content. Raw argv, environment values, prompts, credentials, transcript content, and command text are never returned, persisted, or logged; only structured identity fields, allowlisted names, and canonical path references may cross the helper boundary. Any failed or unknown identity result is reported to the daemon as unavailable, and the daemon keeps the resume row searchable while failing closed on launch or focus.

Pill presentation uses click-sized AppKit panels and one stable VoiceOver status item. An optional bounded navigator catalog adds searchable rows without adding menu panels.

Automatic screen selection prefers the built-in display, then the main display. A specific selection matches display ID, then name, before using that automatic fallback.

The helper detects native full-screen windows on the selected display through `AXFullScreen`. Hidden panels keep their layout but become transparent and ignore pointer actions.

Optional inspector content is already display-safe. It can include runtime items, bounded detail rows, project path, activity time, and context usage. The helper never parses provider records.

Legacy direct Ghostty callers retain the OSC 7 marker path. Policy-bound focus prepares a missing exact capability once and fails closed if preparation fails. Normal prepared focus uses native AppleEvents instead of launching an interpreter or waiting for a new locator. Process checks use kernel metadata, with the existing subprocess probes retained when that metadata is unavailable. iTerm2 and Terminal use their native TTY properties. Restoration AppleScript calls use the shared bounded app-command deadline.

Closed-session Resume remains daemon-owned and uses only a validated, exact provider capability. The helper does not infer a moved working directory, configuration home, account, or profile. Claude named-profile repair is unsupported because native provenance cannot read that selection back; Codex profile names and files must remain under the recorded configuration home. A relocation or profile change requires an explicit provider validation flow for that retained row. An ambiguous or unavailable warm Codex server/client read remains unknown and cannot authorize a new launch.

Claude discovery retains exact interactive routes in memory. An explicit click re-reads only the owning process's session metadata; parked, ended, changed or unreadable records require fresh discovery. Native guards remain authoritative at the action boundary. Background-job attachments still require fresh conversation-presence discovery; their exact-surface native focus no longer launches an interpreter. Preparation is serialized with session input/cancel actions. Herdr preparation admits at most 32 outstanding operations; native and daemon route caches each retain at most 128 entries.

The product target is less than 50 ms from click to the correct conversation visible and focused. Fixture tests establish exact routing and removal of redundant work, not live latency. Native pill activations carry their local timestamp. Diagnostics retain both daemon duration and native-activation-to-operation duration, distinguish prepared routes from recovery, measure session action queue wait and Herdr RPC/release/readback phases, and capture native helper request/reply boundaries. Native process validation remains inside the native request span. Logs contain no titles, directories, prompts or arguments. Neither operation duration proves when the compositor displayed the frame. Background helper contention and remaining fresh attachment discovery must be measured in candidate acceptance.

Application focus still validates the process identifier against the expected bundle identifier.

The helper can emit pill, window, usage, notification-permission, and exact notification-action events on the same framed connection.

Option-click adds the optional `chat` activation intent. Notification actions include the exact session and tool request identities.

Modifier double taps reuse `HotkeyDoubleTapDetector`. A separate key-down monitor cancels chords and supports a migrated custom shortcut.

## Signing

Build and sign the helper with the existing identity:

```sh
scripts/build-native-helper.sh
```

When the `AgentVisor Dev` identity is available, development uses it by default
so rebuilding the helper keeps the same Accessibility identity. Otherwise the
helper is signed ad hoc and may need Accessibility access again after a rebuild.
Set `AV_NATIVE_HELPER_SIGN_IDENTITY` to an empty string to request ad-hoc signing
explicitly. Release validation can select the existing public identity:

```sh
AV_NATIVE_HELPER_SIGN_IDENTITY='AgentVisor Release' scripts/build-native-helper.sh
```

The script never creates or rotates a certificate.

It packages the executable as a background helper application. This preserves its signed identity and gives modern notifications a valid bundle identity.

The daemon starts that application through Launch Services and retries once after 250 milliseconds if startup fails. A clean close first invalidates Pi restoration authority. An unexpected socket close preserves the latest atomic active snapshot. The helper freezes that snapshot when macOS announces system power-off.

## Test seams

`FakeNativeHelper` implements the daemon adapter without starting native code. It records pill, usage, notification, Pi restoration, and focus calls.

`NativeHelperProcess` owns the signed helper lifecycle, framed requests, event delivery, deadlines, and temporary socket cleanup.

Native subprocess probes close both pipe ends on success, launch failure, and timeout. Periodic terminal discovery must not retain descriptors between requests; otherwise it can exhaust the helper and block navigation for every provider.

Run the socket integration check with:

```sh
npm run test:native-helper
```
