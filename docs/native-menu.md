# Native menu bar

The signed Swift helper presents Agent Visor’s macOS menu items.

## Ownership

The TypeScript daemon selects active sessions, assigns priority, reads provider usage, and sends a typed presentation.

The helper renders that presentation with native `NSStatusItem` controls. It does not read provider files or credentials.

macOS owns status-item placement, display changes, available-space packing, and click hit testing.

This removes Agent Visor’s captured global click rectangles. A detached, moved, or resized display cannot leave stale click geometry.

## Session items

Needs you items come first, then Ready to continue, then In progress. History stays in the Sessions browser.

Each item has a status dot and a title of at most 22 characters. Its native hover help shows the full title, state, source, project, and owner.

The status colors match the released roles:

- Yellow means Needs you.
- Green means Ready to continue.
- Orange means In progress.

## Shortcuts

The helper registers the selected modifier family with 1 through 9 for the first nine prioritized items.

The selected modifiers with 0 open Sessions. Off unregisters all session shortcuts.

A helper action travels back through the authenticated local helper connection. The daemon resolves the current session owner.

Electron serializes owner activations and rejects owners outside its application allowlist.

Exact session and window focus remains a cutover blocker. Owner activation stays source-first until a verified target route exists.

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

The helper emits `activate_pill` and `open_sessions` events over the same framed Unix connection.

Run the native checks with:

```sh
npm run test:native-helper
```
