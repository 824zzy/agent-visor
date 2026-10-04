# Native menu bar

The signed Swift helper presents Agent Visor’s macOS menu items.

## Ownership

The TypeScript daemon selects active and recent sessions, assigns priority, reads provider usage, and sends a typed presentation.

The helper renders that presentation with click-sized AppKit panels. It does not read provider files or credentials.

Each panel contains one native button. Transparent menu-bar space has no Agent Visor window and cannot capture clicks.

Button actions and the Accessibility fallback use the live panel frames. No separate click-geometry cache can outlive its rendered capsule.

The helper measures the active application menus, system tray, display, and physical notch. A left lane requires a complete, stable menu reading. Failed child reads, mixed-display frames, gaps, or an unresolved owner close that lane; there is no guessed app-menu width. A complete menu measured on another display transfers with 24 points of clearance, while a crowded source reading is rejected. The shared `PillBarPacker` selects the visible priority prefix and overflow.

Display and application changes trigger immediate layout. A bounded half-second refresh covers menu-title and system-tray changes without rebuilding visible pills.

## Display and full-screen behavior

Automatic placement prefers the built-in display, then the main display. A selected display follows its saved UUID across reconnection and reused display IDs. Older preferences match the ID and name together, then the name. If a selected monitor is unavailable, another external display is used temporarily without changing the saved preference.

`Show on demand` is the default full-screen choice. Pills hide at rest and reveal at the selected screen’s top edge, while session modifiers are held, or while a native popover is open.

Pointer exit waits 650 milliseconds. Modifier release waits 350 milliseconds. `Always hide` ignores passive reveal, while `Always show` remains visible.

Hidden panels keep their frames and shortcut snapshot current. They have zero opacity, ignore direct mouse input, and are excluded from global hit routing.

Full-screen detection uses native `AXFullScreen` evidence on the selected display. A full-screen window on another display does not hide the pills.

## Session items

Needs you items come first, then In progress, fresh Ready completions, and source-backed recent History shortcuts. Claude Code rows that remain Ready without activity for the shared 30-minute transcript stale ceiling keep their Ready wire phase and true turn/route state, but receive a History attention tier on native surfaces. That tier moves them behind newer work and makes the overflow show them as Recent without truncating the Ready age fade. Their full Sessions-browser row remains unchanged. Each group sorts by authoritative activity (`updatedAt`) newest first, then stable session ID. Seen and unseen completions share one priority group; acknowledgment controls the pulse, not position. The daemon assigns priority and the helper adopts it without a second ordering policy.

### Pill-surface selection contract

Codex direct conversations remain in the full Sessions browser until archived, including idle and unloaded conversations. Discovery pages through the unarchived catalog and requires an existing rollout; age never removes a direct conversation. Cursor, Zed, and Codex automation still use the configured observed-agent window, which defaults to 42 hours. The native menu selector applies a seven-day activity window to both physical pills and the More Sessions catalog, including search, before the existing 64/512 bounds. This applies to every phase, using authoritative `updatedAt`; invalid activity timestamps are excluded. Older conversations remain in the full Sessions browser and re-enter the menu after fresh activity. A minute timer rechecks the cutoff even when the catalog is unchanged.

Needs you, Ready, and Working rows with ambient presence are active pill candidates. A History row with an available source action is a recent-shortcut candidate. A History row that has only Chat remains navigator-only because it has no safe physical-pill action.

The daemon sends active candidates first and recent shortcuts second. The helper renders recent shortcuts with the muted History treatment and packs the complete ordered physical list into the available menu-bar space.

Claude Code's retained background inventory is a resumable catalog, not evidence of an open conversation. Background jobs receive physical pills and default overflow membership when current live interactive metadata identifies a displayed conversation, or a current Ghostty conversation title uniquely matches the canonical job name and directory. A terminal in the agent overview contributes no pill: its `parkedJobId` marks the host conversation as parked, not the background job as displayed. The parked marker can remain while the host displays an attached job. A fresh Ghostty title read distinguishes that job from the overview; failed reads, unknown titles, and ambiguous matches do not restore background pills. Ambient title reads do not prompt for Automation permission or write terminal input. Other retained jobs stay in Sessions and navigator search regardless of their Working, blocked, completed, or failed state. A worker PID, attach command launch arguments, fresh transcript activity, or a lifecycle hook alone does not establish ambient presence. Entering a conversation establishes presence; returning to the overview, closing, or switching the interactive UI removes that terminal's contribution at the next refresh without deleting history or attach actions. A conversation independently displayed in another terminal remains eligible.

`+N` counts every bounded, default-overflow-eligible navigator row that is not visible. This includes physical candidates that do not fit and eligible navigator-only rows; searchable-only automation, app-managed sessions, and retained Claude jobs without ambient presence are excluded. The helper reserves space for that total before it places physical pills, so a complete navigator remains reachable even when all physical candidates fit.

Ponytail: a change to the observed window, History eligibility, or overflow count must update the provider, menu-presentation, packer, and overflow-snapshot tests together. Do not restore a source-specific History exclusion at the presentation seam.

A normal click immediately opens the selected task and marks its Ready completion seen. Acknowledgment alone does not reorder pills. Layout changes from activity, phase, or membership updates are deferred while the pointer remains over either pill strip, a press begun there remains held, session shortcut modifiers are held, or a native popover is open. Gaps between pills count as part of the strip; the notch does not.

Cursor IDE history pills open their owning workspace through Cursor's document handler; they do not select an exact Agent conversation. Their subtitle says “Opens workspace.” Discovery advertises this action only for an existing workspace, and clicking rechecks that directory. A missing workspace keeps its readable transcript in the navigator. Cursor CLI sessions with a terminal target still focus that exact terminal.

Claude Code background jobs have a private daemon PTY with no visible terminal tab. Source navigation runs `claude attach <job-id>` for that exact background identity when the canonical inventory and CLI executable establish an attach route. When current live interactive metadata identifies the same conversation, its exact terminal route is retained alongside the canonical job name and state. Both interactive and background source actions revalidate the current conversation before focus. A matching existing `claude attach` terminal is not reused solely because its launch arguments match: it may have moved into Agent View or another conversation. A displayed Ghostty job reuses its stable surface ID after checking the application process instance, conversation title, and directory; Claude's animated title indicator does not change the conversation identity. A changed or unavailable surface falls back to attaching the canonical job, which can open a new terminal window. A hook alone does not establish that attach route.

After 120 milliseconds outside the interaction, pills slide to their new positions over 240 milliseconds with smooth acceleration and deceleration. The clicked pill stays in front where paths cross; overlapping capsules use solid backgrounds so labels remain readable. Native window stacking and click routing share that same order. Pointer re-entry pauses at the last rendered positions, and leaving resumes toward the latest layout. Reduce Motion retains the interaction hold and applies the deferred layout without animation.

Motion is clipped to each safe menu-bar lane without compressing the button content. A pill changing sides exits its source lane before entering the destination lane; it never travels through the notch. Pills entering or leaving overflow pass through their lane edge. Updates during a slide coalesce into the next move.

The rendered layout determines click targets, visible shortcut numbers, and overflow membership. Seen state, colors, and provider updates continue during the hold. Removed sessions disappear immediately. If screen or menu/tray geometry makes the held frames unsafe, safe placement takes precedence over the hold. Screen changes and hiding cancel pending motion.

In progress stays ahead of completed work once the layout settles. Activity-only refreshes adopt the new recency order after the interaction hold, even when every session keeps the same phase.

An observed transition into Ready pulses its status dot for up to seven minutes. Initial snapshots do not invent completions, and acknowledgment stops the pulse.

Ready status color fades linearly from green to gray over 42 minutes from the authoritative activity date. The helper refreshes the color every 30 seconds. Opening a completion marks it seen and stops its pulse; it does not reset the color age. A later Working-to-Ready transition creates a new unseen completion. Pulse animation changes only opacity; elapsed time never marks a completion seen.

Each item matches the released 24-point dark capsule, six-point status dot, seven-point outer padding, and three-point dot-to-title spacing.

Hovering for 0.35 seconds opens a compact session inspector. Leaving the item dismisses it, while clicking keeps the normal source action or opens Chat for an ownerless Chat-capable row.

The inspector matches Swift’s content order: title, phase badge, latest runtime, conditional detail rows, project path, conditional context, activity, and direct-open shortcut.

Reasoning, mode, access, model, and context appear only when the daemon has authoritative values. Missing provider data never creates placeholder claims.

The inspector retains Swift’s layout, typography, native arrow, and shadow. Semantic macOS colors provide a white light-mode card and a dark dark-mode card.

Chat-only transcript history remains navigator-only in Sessions and does not crowd the menu bar.

Unarchived source-backed Codex history with activity in the last seven days remains a dimmed pill candidate and opens its exact `codex://threads/<id>` source. Archiving removes the conversation from the normal Sessions catalog and pills on the next successful refresh; an already-open Chat keeps its separate read-only archival state. Active headless Codex jobs require a thread-catalog record and rollout before source activation. Hook-only internal tasks stay hidden.

Codex `exec` rows are classified as machine-owned automation. They remain in
the bounded navigator catalog for search and read-only inspection, but never
enter physical pill packing, Ready attention, notifications, Dock badges, or
the normal `+N` overflow set. Their ambient catalog label is
`Codex automation · <project>`; the raw automation prompt is not a pill title.

Agent Room backing sessions remain in Sessions and navigator search, labelled
`Managed by Agent Room`, but do not enter physical pills or the default `+N`
count/list. Their actual lifecycle and existing source/Chat actions remain intact.
The daemon uses the latest matching Codex `session_meta.originator` record, not
the title or working directory. A later client record identifying Codex Desktop
restores normal pill eligibility. Unknown/missing client identity stays visible;
Visor does not infer an ownership transfer from merely viewing a transcript.

Visible items retain their normal labels, up to 20 characters plus an ellipsis. Untitled Codex rows use `Codex · <project>` so distinct sessions do not share one fallback label. The helper uses `+N` instead of compact or tight labels.

Clicking `+N` opens a nonactivating More Sessions popover. Its count and initial rows are the exact default-overflow-eligible navigator sessions omitted by the current pill layout.

The popover freezes that layout while open. The placeholder reads “Search N recent sessions”. Search covers the bounded seven-day navigator catalog, including visible items, Chat-only History, and searchable-only automation that do not enter menu packing.

Rows open the exact source session when one is available. An ownerless Chat-capable row opens Chat as its primary normal-click/Return action. Footer actions open Sessions or Settings, and a second `+N` activation closes the popover.

Activity, phase, and membership changes adopt the daemon's new priority order. Existing panels move or update in place without replacing their native buttons.

The status colors match the released sRGB roles:

- `#f4c114` means Needs you.
- `#a6e3a1` means a fresh Ready completion and fades toward `#7f849c` as activity ages.
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

## Placement diagnostics

Set `AGENT_VISOR_MENU_DIAGNOSTICS=1` when launching the desktop app to log changed monitor UUIDs, menu-owner PIDs, measured edges, and lane widths under the `com.824zzy.AgentVisor.NativeHelper` subsystem. Diagnostics are off by default and contain no session titles or credentials.

## Navigation diagnostics

Pill and Sessions-window focus requests write correlated stages to `diagnostics/pill-navigation.jsonl` in the app data directory. Each request records its origin, hashed session/profile identity, target kind, PID, helper request/response, and fixed failure reason when available. Titles, prompts, paths, process environments, and arbitrary error text are excluded. The current log and one rotated log are limited to 256 KiB each; writes use owner-only file permissions and a bounded queue. Logging failures do not block or replay navigation.

Codex focus failures distinguish target validation, process identity, profile verification, and rejected thread links. An OSStatus code is included for link failures when provided by macOS. The process/profile checks remain required before sending a thread link.
