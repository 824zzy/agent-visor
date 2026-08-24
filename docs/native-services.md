# Native services

Electron, the TypeScript daemon, and the signed Swift helper divide macOS work by trust boundary.

## Settings

The daemon stores settings in Electron’s private application data directory as `settings.json`.

The directory uses mode `0700`. The file uses mode `0600` and is replaced through an atomic rename.

On first start, the daemon exports the released Swift application’s `UserDefaults` domain.

Known values migrate into typed settings. The complete source property list is also retained as base64, including unknown and future values.

A malformed existing settings file stops startup. Agent Visor does not overwrite it with defaults.

The migrated settings include:

- Appearance and content size.
- Session-pill and Codex-usage visibility.
- Window hotkey and migrated custom chord.
- Session shortcut modifiers.
- Notification sound.
- File-link editor preference.
- Observed session window.
- Launch at login.

Observed-session changes take effect without restarting the daemon. Session shortcuts re-register native hotkeys, while the application shortcut reconfigures the existing monitors.

Launch-at-login changes use Electron’s packaged application API. Development builds preserve the value without registering the Electron development binary.

## Permissions

The helper checks Accessibility with its stable signed identity.

Settings can request Accessibility or open the macOS Accessibility settings page. The daemon refreshes the state every 15 seconds.

Development helper builds use the existing `AgentVisor Dev` identity. Release builds continue to use `AgentVisor Release`.

## Notifications

The daemon detects transitions into Needs you and Ready to continue.

It sends bounded notification content and the allowlisted owner to Electron. Electron uses the native macOS notification API.

Clicking a notification uses the same serialized, allowlisted owner-activation path as menu items.

The Notifications settings action creates the application notification entry and opens macOS Notification settings for repair.

## Updates

The daemon checks the public appcast at startup and every six hours.

It accepts only three-part versions, HTTPS assets from the public Agent Visor GitHub release path, and structurally valid Ed25519 signatures.

A version must be newer than the running version. Equal or older entries are never offered, which prevents rollback.

The replacement does not perform an automatic in-place install. It opens the verified public release tag.

Existing release scripts remain responsible for archive signing, notarization, public identity continuity, hashes, and rollback-safe publication.

`scripts/package-electron.sh` prepares a separate release-signed 2.7.0 candidate. It does not change the public appcast or cask.

## Lifecycle

Closing the Sessions window hides it while the daemon and helper continue running. The Dock and application hotkey raise the retained window.

A real Quit closes the window and stops owned processes.

Electron owns only the daemon it starts. The daemon owns only its helper, hook socket, timers, and temporary Codex usage process.

Shutdown does not scan for or terminate provider processes. Independently started Pi, Claude Code, Codex, Cursor, Ghostty, Zed, and Auggie processes remain running.

## Checks

Run the native-service checks with:

```sh
npm run test:native-services
npm run test:native-helper
```
