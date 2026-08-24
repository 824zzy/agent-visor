# Native macOS helper

The migration keeps one small Swift process for macOS-only operations.

The TypeScript daemon owns providers, sessions, transcripts, Chat, and settings. The helper does not parse provider data.

## Transport

The helper accepts framed JSON through a local Unix stream socket.

Each frame starts with a four-byte, unsigned, big-endian payload length. A payload cannot exceed 1 MiB.

The helper creates its parent directory with mode `0700` and its socket with mode `0600`. It accepts connections only from the current user.

Start it with:

```sh
AgentVisorNativeHelper --socket /absolute/private/path/helper.sock
```

## Protocol

Every request contains protocol `version: 1`, a non-empty `id`, and one method:

- `screen_topology` returns screen frames, visible frames, scale factors, and the main screen.
- `accessibility_status` returns the current Accessibility trust state.
- `request_accessibility` asks macOS for Accessibility access.
- `open_accessibility_settings` opens the macOS repair destination.
- `present_pills` accepts at most 64 active or recent pill descriptions, bounded optional inspector content, eight usage glances, session shortcuts, and the window hotkey.
- `focus_terminal` selects one allowlisted terminal through its exact TTY.
- `send_terminal` sends bounded text to that exact terminal and optionally submits it.
- `focus` requires an exact process identifier and bundle identifier. A window identifier is optional.

Unknown methods, extra fields, oversized frames, invalid identifiers, and malformed JSON are rejected.

Pill presentation uses click-sized AppKit panels and one stable VoiceOver status item. An optional bounded navigator catalog adds searchable rows without adding menu panels.

Optional inspector content is already display-safe. It can include runtime items, bounded detail rows, project path, activity time, and context usage. The helper never parses provider records.

Ghostty focus uses an OSC 7 marker written only to a validated `ttys` device. iTerm2 and Terminal use their native TTY properties.

Application focus still validates the process identifier against the expected bundle identifier.

The helper can emit `activate_pill`, `open_sessions`, `toggle_sessions`, and `open_settings` events on the same framed connection. Option-click adds the optional `chat` activation intent.

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

## Test seams

`FakeNativeHelper` implements the daemon adapter without starting native code. It records pill, usage, and focus calls.

`NativeHelperProcess` owns the signed helper lifecycle, framed requests, event delivery, deadlines, and temporary socket cleanup.

Run the socket integration check with:

```sh
npm run test:native-helper
```
