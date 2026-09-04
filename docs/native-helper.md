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
- `send_terminal` sends bounded text to that exact terminal and optionally submits it.
- `focus` requires an exact process identifier and bundle identifier. A window identifier is optional.

Unknown methods, extra fields, oversized frames, invalid identifiers, and malformed JSON are rejected.

Pill presentation uses click-sized AppKit panels and one stable VoiceOver status item. An optional bounded navigator catalog adds searchable rows without adding menu panels.

Automatic screen selection prefers the built-in display, then the main display. A specific selection matches display ID, then name, before using that automatic fallback.

The helper detects native full-screen windows on the selected display through `AXFullScreen`. Hidden panels keep their layout but become transparent and ignore pointer actions.

Optional inspector content is already display-safe. It can include runtime items, bounded detail rows, project path, activity time, and context usage. The helper never parses provider records.

Ghostty focus uses an OSC 7 marker written only to a validated `ttys` device. iTerm2 and Terminal use their native TTY properties. Restoration AppleScript calls use the shared bounded app-command deadline.

Application focus still validates the process identifier against the expected bundle identifier.

The helper can emit pill, window, usage, notification-permission, and exact notification-action events on the same framed connection.

Option-click adds the optional `chat` activation intent. Notification actions include the exact session and tool request identities.

Modifier double taps reuse `HotkeyDoubleTapDetector`. A separate key-down monitor cancels chords and supports a migrated custom shortcut.

## Signing

Build and sign the helper with the existing identity:

```sh
scripts/build-native-helper.sh
```

Development uses `AgentVisor Dev`. Release validation can select the existing public identity:

```sh
AV_NATIVE_HELPER_SIGN_IDENTITY='AgentVisor Release' scripts/build-native-helper.sh
```

The script never creates or rotates a certificate.

It packages the executable as a background helper application. This preserves its signed identity and gives modern notifications a valid bundle identity.

The daemon starts that application through Launch Services and retries once after 250 milliseconds if startup fails. A clean close first invalidates Pi restoration authority. An unexpected socket close preserves the latest atomic active snapshot. The helper freezes that snapshot when macOS announces system power-off.

## Test seams

`FakeNativeHelper` implements the daemon adapter without starting native code. It records pill, usage, notification, Pi restoration, and focus calls.

`NativeHelperProcess` owns the signed helper lifecycle, framed requests, event delivery, deadlines, and temporary socket cleanup.

Run the socket integration check with:

```sh
npm run test:native-helper
```
