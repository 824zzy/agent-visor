# Native menu bar

The signed Swift helper presents Agent Visor’s macOS menu items.

## Ownership

The TypeScript daemon selects active and recent sessions, assigns priority, reads provider usage, and sends a typed presentation.

The helper renders that presentation with click-sized AppKit panels. It does not read provider files or credentials.

Each panel contains one native button. Transparent menu-bar space has no Agent Visor window and cannot capture clicks.

Button actions and the Accessibility fallback use the live panel frames. No separate click-geometry cache can outlive its rendered capsule.

The helper measures the active application menus, system tray, display, and physical notch. The shared `PillBarPacker` selects the visible priority prefix and overflow.

Display and application changes trigger immediate layout. A bounded half-second refresh covers menu-title and system-tray changes without rebuilding visible pills.

## Display and full-screen behavior

Automatic placement prefers the built-in display, then the main display. A selected display matches its saved display ID, then its saved name after reconnection.

`Show on demand` is the default full-screen choice. Pills hide at rest and reveal at the selected screen’s top edge, while session modifiers are held, or while a native popover is open.

Pointer exit waits 650 milliseconds. Modifier release waits 350 milliseconds. `Always hide` ignores passive reveal, while `Always show` remains visible.

Hidden panels keep their frames and shortcut snapshot current. They have zero opacity, ignore direct mouse input, and are excluded from global hit routing.

Full-screen detection uses native `AXFullScreen` evidence on the selected display. A full-screen window on another display does not hide the pills.

## Session items

Needs you items come first, then unacknowledged Ready to continue, In progress, acknowledged Ready to continue, and source-backed recent History shortcuts.

A normal click acknowledges a Ready item and moves it behind In progress. Activity-only refreshes cannot move other pills while the user targets them.

An observed transition into Ready pulses its status dot for up to seven minutes. Initial snapshots do not invent completions, and acknowledgment stops the pulse.

Ready status color fades linearly from fresh green to muted gray over 42 minutes from the authoritative activity date. Acknowledgment does not reset this age. The helper updates the color every 30 seconds while pulse animation changes only opacity.

Each item matches the released 24-point dark capsule, six-point status dot, seven-point outer padding, and three-point dot-to-title spacing.

Hovering for 0.35 seconds opens a compact session inspector. Leaving the item dismisses it, while clicking keeps the normal source action.

The inspector matches Swift’s content order: title, phase badge, latest runtime, conditional detail rows, project path, conditional context, activity, and direct-open shortcut.

Reasoning, mode, access, model, and context appear only when the daemon has authoritative values. Missing provider data never creates placeholder claims.

The inspector retains Swift’s layout, typography, native arrow, and shadow. Semantic macOS colors provide a white light-mode card and a dark dark-mode card.

Chat-only transcript history remains in Sessions and does not crowd the menu bar.

Completed Codex history also remains in Sessions and More Sessions without keeping a physical pill. Active headless Codex jobs require a thread-catalog record and rollout before opening their exact `codex://threads/<id>` source. Hook-only internal tasks stay hidden.


Visible items retain their normal labels, up to 20 characters plus an ellipsis. Untitled Codex rows use `Codex · <project>` so distinct sessions do not share one fallback label. The helper uses `+N` instead of compact or tight labels.

Clicking `+N` opens a nonactivating More Sessions popover. Its initial rows are the exact sessions omitted by the current pill layout.

The popover freezes that layout while open. Search covers the complete bounded navigator catalog, including visible items and Chat-only History that does not enter menu packing.

Rows open the exact source session. Footer actions open Sessions or Settings, and a second `+N` activation closes the popover.

Phase and membership changes adopt the new priority order. Existing panels move or update in place without replacing their native buttons.

The status colors match the released sRGB roles:

- `#f4c114` means Needs you.
- `#a6e3a1` means fresh Ready to continue and fades toward `#7f849c` as activity ages.
- `#d97857` means In progress.
- Recent History uses the muted `#7f849c` role and lighter capsule treatment.

## Shortcuts

The helper registers the selected modifier family with 1 through 9 for the first nine visible items.

Holding those modifiers freezes the target snapshot and replaces status dots with numbered keycaps. The selected modifiers with 0 toggle More Sessions. Off unregisters all session shortcuts.

The independent application shortcut defaults to double Shift. Modifier taps use the released timing and chord-cancellation policy. A migrated custom chord remains usable.

The application shortcut hides an active Sessions window. Otherwise it raises Sessions above the current application.

A helper action travels back through the authenticated local helper connection. The daemon resolves current capabilities before acting.

A normal click opens only the exact source session. Failed exact focus does not launch a new owner window or fall back to Agent Visor Chat. Option-click opens Chat when supported. Electron serializes owner activations and rejects owners outside its application allowlist.

Pill actions use the provider-owned exact target when one exists.

Terminal sessions use exact TTY focus. Codex application sessions use their validated thread URL. Other rows use the strict source-application fallback.

## Accessibility

One stable square status item remains present when no sessions exist. It is named `Agent Visor sessions` and opens the Sessions browser.

Presentation-only session items remain hidden from accessibility. Usage capsules expose their detail action, while the stable item and Sessions browser retain session access.

The open More Sessions popover gives its search field, session rows, Sessions action, and Settings action explicit accessibility labels.

The Usage popover labels each provider, limit window, remaining percentage, reset time, and available reset-credit count.

## Usage

The daemon reads Codex rate limits through Codex’s documented local app-server protocol at startup, when details open, and every five minutes.

The helper receives only bounded display values, limit windows, reset times, reset-credit counts, and sync time. It never receives account tokens or raw provider responses.

Clicking any usage capsule toggles one shared, nonactivating detail popover. Hover keeps the standard delayed text tooltip.

A previous valid usage value remains visible after a temporary refresh failure, and the open detail popover marks it stale.

Claude usage remains disabled until the paused credential work has a documented supported route.

## Protocol

`present_pills` accepts detailed menu pills, an optional bounded navigator catalog, optional usage glances, pill-screen selection, and full-screen policy. Older version-one pill requests remain valid.

The helper emits `activate_pill`, `open_sessions`, `open_settings`, and `refresh_usage` events over the same framed Unix connection. `activate_pill` has an additive optional `chat` intent; standard version-one events remain unchanged.

Run the native checks with:

```sh
npm run test:native-helper
npm run test:native-helper-usage
```
