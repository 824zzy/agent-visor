# Native menu bar

The signed Swift helper presents Agent Visor’s macOS menu items.

## Ownership

The TypeScript daemon selects active and recent sessions, assigns priority, reads provider usage, and sends a typed presentation.

The helper renders that presentation with click-sized AppKit panels. It does not read provider files or credentials.

Each panel contains one native button. Transparent menu-bar space has no Agent Visor window and cannot capture clicks.

Button actions and the Accessibility fallback use the live panel frames. No separate click-geometry cache can outlive its rendered capsule.

The helper measures the active application menus, system tray, display, and physical notch. The shared `PillBarPacker` selects the visible priority prefix and overflow.

Display and application changes trigger immediate layout. A bounded half-second refresh covers menu-title and system-tray changes without rebuilding visible pills.

## Session items

Needs you items come first, then unacknowledged Ready to continue, In progress, acknowledged Ready to continue, and source-backed recent History shortcuts.

A normal click acknowledges a Ready item and moves it behind In progress. Activity-only refreshes cannot move other pills while the user targets them.

Each item matches the released 24-point dark capsule, six-point status dot, seven-point outer padding, three-point dot-to-title spacing, and full hover help.

Chat-only transcript history remains in Sessions and does not crowd the menu bar.

Visible items retain their normal labels, up to 20 characters plus an ellipsis. The helper uses `+N` instead of compact or tight labels.

Phase and membership changes adopt the new priority order. Existing panels move or update in place without replacing their native buttons.

The status colors match the released sRGB roles:

- `#f4c114` means Needs you.
- `#a6e3a1` means Ready to continue.
- `#d97857` means In progress.
- Recent History uses the muted `#7f849c` role and lighter capsule treatment.

## Shortcuts

The helper registers the selected modifier family with 1 through 9 for the first nine visible items.

Holding those modifiers freezes the target snapshot and replaces status dots with numbered keycaps. The selected modifiers with 0 open Sessions. Off unregisters all session shortcuts.

A helper action travels back through the authenticated local helper connection. The daemon resolves current capabilities before acting.

A normal click opens only the source session and never falls back to Agent Visor Chat. Option-click opens Chat when supported. Electron serializes owner activations and rejects owners outside its application allowlist.

Pill actions use the provider-owned exact target when one exists.

Terminal sessions use exact TTY focus. Codex application sessions use their validated thread URL. Other rows use the strict source-application fallback.

## Accessibility

One stable square status item remains present when no sessions exist. It is named `Agent Visor sessions` and opens the Sessions browser.

Presentation-only session and usage items are hidden from accessibility. Their information remains available through the stable item and Sessions browser.

## Usage

The daemon reads Codex rate limits through Codex’s documented local app-server protocol every five minutes.

The helper receives only display text, detail text, and severity. It never receives account tokens or raw provider responses.

A previous valid usage value remains visible after a temporary refresh failure.

Claude usage remains disabled until the paused credential work has a documented supported route.

## Protocol

`present_pills` accepts detailed pill records and optional usage glances. Older version-one pill requests remain valid.

The helper emits `activate_pill` and `open_sessions` events over the same framed Unix connection. `activate_pill` has an additive optional `chat` intent; standard version-one events remain unchanged.

Run the native checks with:

```sh
npm run test:native-helper
```
