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

### Pill-surface selection contract

Provider discovery owns observed-session recency. Codex, Cursor, and Zed use the configured observed-agent window, which defaults to 42 hours. The menu selector does not apply a second clock or a provider-specific History ban.

Needs you, Ready, and Working rows are active pill candidates. A History row with an exact source action is a recent-shortcut candidate. A History row that has only Chat remains navigator-only because it has no safe physical-pill action.

The daemon sends active candidates first and recent shortcuts second. The helper renders recent shortcuts with the muted History treatment and packs the complete ordered physical list into the available menu-bar space.

`+N` counts every bounded, default-overflow-eligible navigator row that is not visible. This includes physical candidates that do not fit and eligible navigator-only rows; searchable-only automation is excluded. The helper reserves space for that total before it places physical pills, so a complete navigator remains reachable even when all physical candidates fit.

Ponytail: a change to the observed window, History eligibility, or overflow count must update the provider, menu-presentation, packer, and overflow-snapshot tests together. Do not restore a source-specific History exclusion at the presentation seam.

A normal click acknowledges a Ready item and moves it behind In progress. Activity-only refreshes cannot move other pills while the user targets them.

An observed transition into Ready pulses its status dot for up to seven minutes. Initial snapshots do not invent completions, and acknowledgment stops the pulse.

Ready status color fades linearly from fresh green to muted gray over 42 minutes from the authoritative activity date. Acknowledgment does not reset this age. The helper updates the color every 30 seconds while pulse animation changes only opacity.

Each item matches the released 24-point dark capsule, six-point status dot, seven-point outer padding, and three-point dot-to-title spacing.

Hovering for 0.35 seconds opens a compact session inspector. Leaving the item dismisses it, while clicking keeps the normal source action or opens Chat for an ownerless Chat-capable row.

The inspector matches Swift’s content order: title, phase badge, latest runtime, conditional detail rows, project path, conditional context, activity, and direct-open shortcut.

Reasoning, mode, access, model, and context appear only when the daemon has authoritative values. Missing provider data never creates placeholder claims.

The inspector retains Swift’s layout, typography, native arrow, and shadow. Semantic macOS colors provide a white light-mode card and a dark dark-mode card.

Chat-only transcript history remains navigator-only in Sessions and does not crowd the menu bar.

Source-backed Codex history inside the observed-session window remains a dimmed recent pill candidate and opens its exact `codex://threads/<id>` source. Older or Chat-only history remains available through Sessions and More Sessions. Active headless Codex jobs require a thread-catalog record and rollout before source activation. Hook-only internal tasks stay hidden.

Codex `exec` rows are classified as machine-owned automation. They remain in
the bounded navigator catalog for search and read-only inspection, but never
enter physical pill packing, Ready attention, notifications, Dock badges, or
the normal `+N` overflow set. Their ambient catalog label is
`Codex automation · <project>`; the raw automation prompt is not a pill title.


Visible items retain their normal labels, up to 20 characters plus an ellipsis. Untitled Codex rows use `Codex · <project>` so distinct sessions do not share one fallback label. The helper uses `+N` instead of compact or tight labels.

Clicking `+N` opens a nonactivating More Sessions popover. Its count and initial rows are the exact default-overflow-eligible navigator sessions omitted by the current pill layout.

The popover freezes that layout while open. Search covers the complete bounded navigator catalog, including visible items, Chat-only History, and searchable-only automation that do not enter menu packing.

Rows open the exact source session when one is available. An ownerless Chat-capable row opens Chat as its primary normal-click/Return action. Footer actions open Sessions or Settings, and a second `+N` activation closes the popover.

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

A normal click opens the exact source session when an owner route is available. An ownerless Chat-capable row opens Agent Visor Chat as the primary action; a failed owner focus does not invent a new owner window or silently fall back to Chat. Option-click remains the explicit Chat action for owner-backed rows. Electron serializes owner activations and rejects owners outside its application allowlist.

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
