# Native menu bar

The signed Swift helper presents Agent Visor’s macOS menu items.

## Paseo-managed Claude conversations

Paseo discovery reads the authenticated local daemon published under `~/.paseo`.
It includes the built-in Claude provider and profiles whose `extends` value is
`claude`, including `claude-copilot`. The read path sends only `hello` and paged
`fetch_agents_request` messages. It does not create, resume, send to, or stop agents.
The handshake advertises Paseo's `all_providers` capability so custom profiles are
included, and explicit event subscriptions so directory reads do not follow timelines.
Ambient reads have a three-second cache and a two-second request deadline. Clicks
bypass the cache and verify that the agent still belongs to the same server.
An unavailable or invalid snapshot removes its ambient rows until a successful read.

Paseo supplies titles, running state, pending permission/question counts, and
explicit completion attention. Idle alone does not create unopened-completion
attention. Paseo clearing `requiresAttention` acknowledges its completion even
when activity timestamps do not change. The usual attention ordering and seven-day
menu cap still apply. Archived, internal, and child agents do not occupy pills.

Paseo IDs include both server and agent identity. A verified native Claude UUID
in the same working directory replaces the native ambient alias, including late
hooks; matching titles or directories alone never merges sessions. Other native
Ghostty conversations and overview suppression retain their existing rules.
The source action opens `paseo://h/<server-id>/agent/<agent-id>` through Paseo's
registered link handler. Paseo-managed Chat sending is not exposed in Agent Visor.
Remote Paseo hosts and other provider families are outside this adapter's scope.

## Ownership

The TypeScript daemon selects active and recent sessions, assigns priority, reads provider usage, and sends a typed presentation.

The helper renders that presentation with click-sized AppKit panels. It does not read provider files or credentials.

Each panel contains one native button. Transparent menu-bar space has no Agent Visor window and cannot capture clicks.

Button actions and the Accessibility fallback use the live panel frames. No separate click-geometry cache can outlive its rendered capsule.

The helper measures the application menu on the pill display, system tray, display, and physical notch. It reads the local menu owner's PID from Accessibility hits in the Apple and application menu areas, even when focus is on another display or separate Spaces are disabled. Both hits must identify the same app menu; global focus and window order cannot establish local ownership. The owner is checked again after reading its menu geometry.

A left lane requires a complete, stable menu reading. Failed child reads, mixed-display frames, gaps, or an unresolved owner close that lane; there is no guessed app-menu width. A complete menu measured on another display transfers with 24 points of clearance, while a crowded source reading is rejected. The shared `PillBarPacker` selects the visible priority prefix and overflow.

Display and application changes trigger immediate layout. A bounded half-second refresh covers menu-title and system-tray changes without rebuilding visible pills.

## Display and full-screen behavior

Automatic placement prefers the built-in display, then the main display. A selected display follows its saved UUID across reconnection and reused display IDs. Older preferences match the ID and name together, then the name. If a selected monitor is unavailable, another external display is used temporarily without changing the saved preference.

`Show on demand` is the default full-screen choice. Pills hide at rest and reveal at the selected screen’s top edge, while session modifiers are held, or while a native popover is open.

Pointer exit waits 650 milliseconds. Modifier release waits 350 milliseconds. `Always hide` ignores passive reveal, while `Always show` remains visible.

Hidden panels keep their frames and shortcut snapshot current. They have zero opacity, ignore direct mouse input, and are excluded from global hit routing.

Full-screen detection uses native `AXFullScreen` evidence on the selected display. A full-screen window on another display does not hide the pills.

## Session items

Codex async questions remain yellow Needs you while unanswered in their owning
in-progress turn, including after delivery acknowledgment and sibling work.
The owning turn's completion or abortion ends pending status. A replacement turn
starts with no inherited question requests; duplicate starts and late boundaries
for other turns do not clear the current question. Provider turn metadata prevents
late question records from resurrecting requests belonging to earlier turns.
A structured user reply resolves only its exact call ID and question index in that
conversation. Both array and single-object reply envelopes are supported. Explicit
delivery rejection removes the request; unknown output and malformed replies do not.
Blocking questions retain their existing matching-result and turn-boundary rules.
Native-owned questions are answered in Codex; Agent Visor does not acquire a writer.
Checkpoints retain only bounded request IDs, indices, and timestamps. Normal rows
use 8 KiB prefixes; oversized user replies use a 64 KiB prefix of the new transcript
delta. Content beyond that bound cannot claim acknowledgment. The usual menu age
cap and managed-session visibility rules still apply.

Needs you items come first, then unopened Ready completions, In progress, opened Ready completions, and source-backed recent History shortcuts. Each group sorts by authoritative activity (`updatedAt`) newest first, then stable session ID. Opening a completion moves it behind running work. The acknowledgment belongs to the latest provider turn, with authoritative activity as the fallback for providers without turn IDs. A later completion becomes unopened even if polling did not observe its Working phase. The daemon assigns priority and the helper adopts it without a second ordering policy.

Codex completion freshness uses the recorded completion time. Running freshness uses start and actual turn-progress records, including bounded headers of large answer/tool rows. File modification times, settings, client metadata, and context records do not refresh either claim. Opening an old conversation cannot turn History into unopened Ready or revive a dormant start marker. Transcript revisions still track file changes so Chat refreshes normally.

Claude Code rows that remain Ready without activity for the shared 30-minute transcript stale ceiling keep their Ready wire phase and true turn/route state, but receive a History attention tier on native surfaces. That tier moves them behind newer work and makes the overflow show them as Recent without truncating the Ready age fade. Their full Sessions-browser row remains unchanged.

### Pill-surface selection contract

Codex direct conversations remain in the full Sessions browser until archived, including idle and unloaded conversations. Discovery pages through the unarchived catalog and requires an existing rollout; age never removes a direct conversation. Cursor, Zed, and Codex automation still use the configured observed-agent window, which defaults to 42 hours. The native menu selector applies a seven-day activity window to both physical pills and the More Sessions catalog, including search, before the existing 64/512 bounds. This applies to every phase, using authoritative `updatedAt`; invalid activity timestamps are excluded. Older conversations remain in the full Sessions browser and re-enter the menu after fresh activity. A minute timer rechecks the cutoff even when the catalog is unchanged.

Needs you, Ready, and Working rows with ambient presence are active pill candidates. A History row with an available source action is a recent-shortcut candidate. A History row that has only Chat remains navigator-only because it has no safe physical-pill action.

The daemon sends active candidates first and recent shortcuts second. The helper renders recent shortcuts with the muted History treatment and packs the complete ordered physical list into the available menu-bar space.

Claude Code's retained background inventory is a resumable catalog, not evidence of an open conversation. Background jobs receive physical pills and default overflow membership when current live interactive metadata identifies a displayed conversation, or a current Ghostty conversation title uniquely matches the canonical job name and directory. A terminal in the agent overview contributes no pill: its `parkedJobId` marks the host conversation as parked, not the background job as displayed. The parked marker can remain while the host displays an attached job. A fresh Ghostty title read distinguishes that job from the overview; failed reads, unknown titles, and ambiguous matches do not restore background pills. Ambient title reads do not prompt for Automation permission or write terminal input. Other retained jobs stay in Sessions and navigator search regardless of their Working, blocked, completed, or failed state. A worker PID, attach command launch arguments, fresh transcript activity, or a lifecycle hook alone does not establish ambient presence. Entering a conversation establishes presence; returning to the overview, closing, or switching the interactive UI removes that terminal's contribution at the next refresh without deleting history or attach actions. A conversation independently displayed in another terminal remains eligible.

Ghostty conversation detection uses current title and view evidence. A plain title can be confirmed from Claude's current conversation footer, including when the already running frontend has title updates disabled. A metadata-only read first selects visible titles matching the Claude catalog; only those names are sent in the bounded footer scope. The passive Accessibility reader requires a unique matching window and one terminal content area; duplicate titles, split panes, unavailable permission, unsupported footers and changed process identities remain unconfirmed. It does not prompt for permission, focus a window or send input. Only the final 4 KiB is classified, with bounded traversal and messaging deadlines. Terminal text is transient: only an optional conversation/overview classification crosses the helper protocol, and no text is saved. The local `diagnostics/claude-presence.jsonl` records changes in read status and counts of conversation, overview, unrecognized, and matched titles. It stores no titles, paths, session IDs, or error text; unchanged polls add no records, and the file rotates at 64 KiB with one previous file.

CLI 2.1.296 can emit a plain job name after returning from agent view. An alternative confirmation path is a Ghostty surface created by the native helper with an explicit title-enabled client configuration. The helper runs `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=0` and a session-scoped `--settings` env override. Its bounded, private `ghostty-terminal-evidence.json` stores the surface ID, Ghostty PID/start token and directory, preserving that capability across Agent Visor/helper restarts. Current view reads revoke it when the surface closes, the directory changes or the Ghostty process instance changes. Invalid reads do not erase valid evidence. The direct attach command closes its surface on exit, so a later shell cannot inherit its title trust. The worker is neither restarted nor stopped. Frontend discovery does not require a parked-host metadata record: standalone attach clients may publish none.

An existing terminal with unknown title settings needs a status-prefixed title or fresh conversation-footer evidence. A title-suppressed client can leave a plain name unchanged in overview, so name/directory matching alone remains insufficient. Fresh overview evidence overrides both title formats and retained title capability. Source focus rechecks recovered view mode before and after activation, alongside the scripting API's exact surface ID, directory and normalized name checks. A claimed title capability without the helper's matching persisted identity is rejected. Returning to overview removes that surface's contribution; another independently displayed copy remains eligible. Existing Sessions attachment actions remain available without restarting a worker.

The session snapshot includes `claudePresence` for canonical background rows. Its reason distinguishes current interactive metadata, a uniquely identified conversation, overview, no displayed match, an unrecognized or ambiguous title, expired inventory authority, unavailable or failed observation, and a changed application process. This comes from the same current observation that supplies the exact terminal route. A reused Ghostty PID cannot supply presence without a matching process-instance token. One job shown in several terminals still produces one canonical pill. Verified conversation evidence wins over unrelated unknown or overview terminals in the same directory.

The Sessions window shows a separate, searchable explanation for uncertain presence. It preserves the worker's Working or Needs you status and its available source action. Normal background inventory and verified overview rows have no warning. An unrecognized title does not prove that title suppression is enabled; it can also be an unsupported attach-title format. The explanation states that the displayed conversation could not be identified without recommending a worker restart. Ghostty attachment settings apply only to the new client; Agent Visor does not rewrite user settings or create background workers. Terminal.app fallback clears the inherited title-suppression variable but supplies no Ghostty surface capability. In Claude Code 2.1.285, the worker's mounted title store captures its launch configuration; a later environment update or new attach client does not recreate that store. That fact alone does not describe all titles emitted by the attach client.

`+N` counts every bounded, default-overflow-eligible navigator row that is not visible. This includes physical candidates that do not fit and eligible navigator-only rows; searchable-only automation, app-managed sessions, and retained Claude jobs without ambient presence are excluded. The helper reserves space for that total before it places physical pills, so a complete navigator remains reachable even when all physical candidates fit.

Ponytail: a change to the observed window, History eligibility, or overflow count must update the provider, menu-presentation, packer, and overflow-snapshot tests together. Do not restore a source-specific History exclusion at the presentation seam.

A normal click immediately requests the selected task. Successful focus marks that Ready completion seen; a failed focus or a focus that finishes after a newer completion does not. Opening Chat marks it seen after a valid page is sent for the current chat reference. The helper waits for the daemon's acknowledgment before stopping the pulse. Layout changes from acknowledgment, activity, phase, or membership updates are deferred while the pointer remains over either pill strip, a press begun there remains held, session shortcut modifiers are held, or a native popover is open. Gaps between pills count as part of the strip; the notch does not.

Cursor IDE history pills open their owning workspace through Cursor's document handler; they do not select an exact Agent conversation. Their subtitle says “Opens workspace.” Discovery advertises this action only for an existing workspace, and clicking rechecks that directory. A missing workspace keeps its readable transcript in the navigator. Cursor CLI sessions with a terminal target still focus that exact terminal.

Claude Code background jobs have a private daemon PTY with no visible terminal tab. Source navigation runs `claude attach <job-id>` for that exact background identity when the canonical inventory and CLI executable establish an attach route. When current live interactive metadata identifies the same conversation, its exact terminal route is retained alongside the canonical job name and state. Both interactive and background source actions revalidate the current conversation before focus. A matching existing `claude attach` terminal is not reused solely because its launch arguments match: it may have moved into Agent View or another conversation. A displayed Ghostty job reuses its stable surface ID after checking the application process instance, conversation title, and directory; Claude's animated title indicator does not change the conversation identity. A changed or unavailable surface falls back to attaching the canonical job, which can open a new terminal window. A hook alone does not establish that attach route.

After 120 milliseconds outside the interaction, pills slide to their new positions over 240 milliseconds with smooth acceleration and deceleration. The clicked pill stays in front where paths cross; overlapping capsules use solid backgrounds so labels remain readable. Native window stacking and click routing share that same order. Pointer re-entry pauses at the last rendered positions, and leaving resumes toward the latest layout. Reduce Motion retains the interaction hold and applies the deferred layout without animation.

Motion is clipped to each safe menu-bar lane without compressing the button content. A pill changing sides exits its source lane before entering the destination lane; it never travels through the notch. Pills entering or leaving overflow pass through their lane edge. Updates during a slide coalesce into the next move.

The rendered layout determines click targets, visible shortcut numbers, and overflow membership. Seen state, colors, and provider updates continue during the hold. Removed sessions disappear immediately. If screen or menu/tray geometry makes the held frames unsafe, safe placement takes precedence over the hold. Screen changes and hiding cancel pending motion.

Unopened completions stay ahead of In progress once the layout settles. Opening a completion lets running work move ahead of it after the interaction hold. Activity-only refreshes adopt the new recency order after the interaction hold, even when every session keeps the same phase.

An authoritative unopened completion keeps a gentle green status-dot pulse until that exact completion is opened. Its three-second cycle varies opacity from 0.65 to 1. Reduce Motion keeps its green marker static, and hidden strips stop the animation timer. Completion attention is stored separately from lifecycle age and restored after app/helper restarts. Old catalog entries, empty idle conversations, and settings writes do not invent unopened completions. The seven-day menu cap and ambient eligibility still apply.

Unopened completions stay green. Opening marks that completion seen and stops its pulse; the existing 42-minute fade then uses the original completion date, without resetting its age. A later completion receives a new identity and starts attention again. Hover, overflow browsing, elapsed time, metadata writes, and failed opens never mark it seen.

Completion acknowledgment requires a successful explicit source activation through Agent Visor or a valid Chat open. Opening a window or conversation directly in another app leaves its completion unopened in Agent Visor. Automatic detection of direct opens is deferred until a reliable identity integration is available; catalog refresh never infers that a result was seen from foreground windows, titles, or document URLs.

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
