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
- `present_pills` accepts at most 64 validated pill descriptions.
- `focus` requires an exact process identifier and bundle identifier. A window identifier is optional.

Unknown methods, extra fields, oversized frames, invalid identifiers, and malformed JSON are rejected.

Pill presentation and exact-window focus remain disabled until their parity tickets implement the native behavior. The interface already rejects unsupported calls explicitly.

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

`FakeNativeHelper` implements the daemon adapter without starting native code. It records pill and focus calls and returns configured screen and Accessibility results.

Run the socket integration check with:

```sh
npm run test:native-helper
```
