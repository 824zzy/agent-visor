# Product Surface Contract

Status: Accepted
Last reviewed: 2026-08-01

## Purpose

Agent Visor is a status and navigation layer for coding-agent sessions. It helps the user see what needs action and return to the correct owning app with minimal input.

The owning app remains the authoritative conversation surface. Agent Visor may present its own desktop Chat experience from mirrored session data, but it must not imply that this view is more complete or current than Codex, Claude Code, Cursor, Pi, or the terminal that owns the session.

This document is the product-level contract. Detailed browser behavior is specified in the [interaction design](session-browser.md) and [UI design](session-browser-ui.md). Pi-specific discovery, lifecycle, transcript, and installation behavior is specified in [Pi Integration](pi-integration.md).

Permission setup and recovery are specified in [Permission Health](permission-health.md).

## Principles

1. **Stable actions by surface.** Menu-bar pills, the `+N` popover, and Sessions-browser rows return to the canonical owner when one is available; an ownerless Chat-capable row opens Chat as its primary action. A Chat-capable owner-backed row keeps `Open Chat` as an explicit secondary action. Labels and hit targets never exchange meanings.
2. **Actionability before recency.** Needs-attention, ready, and working sessions appear before recent sessions when a surface has to prioritize.
3. **Honest capability.** UI copy and controls reflect the evidence and transport Agent Visor actually has. Inferred status and mirrored history are labeled as such.
4. **One session truth, different surface scopes.** Surfaces share session identity and phase semantics, but each surface may show a different subset for its job.
5. **No surprise movement.** Background discovery, status updates, and pointer hover must not take control of navigation or scrolling.
6. **Teach shortcuts in context.** Persistent product surfaces explain the keyboard path users can take from the action they are already performing. Shortcut education must reflect the configured keys rather than assume a default.
7. **Respect full-screen focus.** Pills do not cover a full-screen owning app at rest. The default full-screen behavior reveals them only in response to top-edge, shortcut, or explicit-popover intent.

## Surface Responsibilities

| Surface | Primary job | Content | Primary action | Must not become |
| --- | --- | --- | --- | --- |
| Menu-bar pills | Ambient status and fastest return path | Discoverable sessions, ordered by actionability then recency, packed to available width | Open original owner, or Chat when no owner route exists | A full history browser |
| `+N` popover | Quick access to sessions that do not fit as pills | The `+N` overflow by default; all recent navigable sessions while searching | Open original owner, or Chat when no owner route exists | A full history or Chat browser |
| Sessions browser | Complete searchable navigation | Current cross-source sessions plus supported saved history | Open the original owner when available; otherwise open Chat when renderable | A replacement for the owning source |
| Agent Visor Chat | In-window conversation and continuation | Mirrored conversation, composer when controllable, and compact status | Continue in Chat or open original | An implicitly authoritative replacement for the owner |
| Owning app | Canonical conversation and control | Native task, conversation, composer, tools, approvals, and source-specific UI | Continue work | Something Agent Visor attempts to duplicate wholesale |
| Usage glance | Peripheral account-capacity awareness when supported | Available Codex 5-hour and 7-day limits | Open compact usage detail | A placeholder for unavailable provider data |
| Permission health | Explain and repair blocked macOS capabilities | Verified Accessibility state and recovery action | Open the relevant setup path | A permanent warning or a proxy for transient layout evidence |

## Menu-Bar Pill Identity

A pill title is a stable session identity, not a live activity ticker.

- Prefer the source-provided session name when one exists; otherwise use the current project name.
- Running tools, commands, and latest-message excerpts must not replace the title. Current phase remains visible through the status dot, while richer activity context belongs in hover detail, the Sessions browser, or Chat.
- A tool start, tool completion, approval request, or message update must not relabel or resize a pill. This keeps neighboring pills and overflow membership stable while the user is targeting them.

## Machine-Owned Automation Visibility

Codex headless `exec` records are automation, not user-facing session
identities. Provider discovery carries this class through the session snapshot
as `automation`; Codex Desktop and live Codex CLI records remain
`interactive` and `terminal` respectively.

- Automation records are always available to the Sessions browser and remain
  in the menu navigator's search catalog whenever that navigator is open, so
  users can search and inspect their read-only history.
- Automation records do not create physical menu-bar pills, Ready attention,
  notifications, Dock badges, or normal pill overflow entries.
- Ambient labels for automation use a stable `Codex automation · <project>`
  label. Raw `exec` prompts must never become menu-bar pill titles.
- Automation records with an available canonical transcript expose Agent
  Visor Chat as a read-only view, regardless of inactivity age. Missing
  transcripts, archive exclusions, and the provider's observed-session window
  may still withhold the record; the owning Codex Desktop and CLI surfaces
  keep their existing behavior.

## Menu-Bar Space Efficiency

The pill strip maximizes the visible highest-priority session prefix inside measured safe widths. It does not reduce the 28-point application-menu margin, the 16-point system-status margin, or the 8-point notch-edge padding to gain capacity.

- Meaningless utility placeholders do not displace sessions. Codex shows a 114-point two-window capsule or a 64-point one-window capsule; it does not display an unavailable `--%` window beside a meaningful value.
- Normal session geometry remains the default. A restrained pressure profile may reduce horizontal chrome only when doing so exposes at least one additional ordered session.
- Pressure never shrinks text, status dots, or pill height and never substitutes activity for identity.
- A shorter lower-priority pill cannot bypass a hidden higher-priority pill merely because it fits an isolated fragment.
- Residual whitespace is valid when the next ordered session cannot fit under an approved profile.
- Rendering, overflow counts, shortcut numbering, and click hit-testing consume one immutable packing plan.
- Both measured safe-width boundaries hold their last reliable per-screen edge. A transient ownership loss or a momentarily narrower measurement — common during app activation or across multiple displays — must not collapse the pill bar: more room applies immediately, while less room applies only after the narrower boundary persists. Pills must not flap in and out as the boundary is re-measured.

The detailed algorithm, transition rules, and test contract are defined in [Menu-Bar Space Packing](menu-bar-packing.md).

## Shortcut Education

The Agent Sessions browser is the durable teaching surface for global session shortcuts. It must explain the configured shortcut family without adding a first-run modal, notification, or automatically presented menu-bar popover.

- The browser footer keeps shortcut education visible without placing a second explanatory row above the primary search control.
- When shortcuts are enabled, the footer shows the configured modifier family with `1-9 Switch sessions` and `0 Session menu`. Numbered shortcuts activate sessions in menu-bar pill reading order; zero toggles the menu-bar session overflow. The labels describe user intent rather than exposing “pill” or “more sessions” implementation language.
- Browser row semantics must not overwrite a modifier family that the user explicitly selected in Settings.
- The guidance must not imply that `1-9` indexes rows in the full browser. Return uses the provider-neutral label `Open source app`, while Shift-Return uses `Open Chat` when supported; exact owner names belong to rows.
- When shortcuts are off, the same location says that global session shortcuts are off and directs the user to Settings.
- Shortcut glyphs come from the effective persisted setting. Copy must not hard-code Control-Command, Option-Command, or any other family.
- The footer separates browser-local actions on the left from global shortcuts on the right. Up/Down navigates, Return opens the selected row's owner when available or Chat for an ownerless Chat-capable row, and Shift-Return opens Chat when supported. Capability fallback is reflected in the labels.
- Generic copy such as `Find a session, then return to the app that owns it.` and `Codex history included` is omitted. The browser structure, source chips, and history rows already communicate those facts.
- Pill hover hints remain as contextual reinforcement for users who rarely open the browser.

## Display Notch Adaptation

The menu-bar strip adapts to whether its display has a physical notch. The synthetic notch was originally drawn on every display as the pills' visual home and as the click target that opens the session browser. On a display without a physical notch that produced an *invisible* click target in empty top-center menu-bar space: clicking near the center of an external display opened the session browser with no visible affordance explaining why.

- The notch shape is **decoration only**. It is drawn on a display with a physical notch, behind the hardware cutout, and it does not hit-test. Clicking it does nothing. There is no panel behind it: the strip renders pills and nothing else.
- On a display **without** a physical notch, Agent Visor renders no synthetic notch. The pills consolidate at center with no center gap.
- **No global pointer monitor turns a menu-bar click into a window summon.** Clicks in empty menu-bar space never open a window, on any display.
- The session browser is reached through the always-visible menu-bar status item, the Dock icon, and the global window hotkey. The status item is present on every display and whatever the VoiceOver state, so keyboard and VoiceOver users have the same standard entry point.
- Pill clicks are the one global click route that remains. They resolve against geometry captured for the pill display, so they are ignored whenever that display has moved, been resized, or been detached since capture. A rebuilt strip with fresh geometry takes over.

The reason for the last two rules: a click target derived from captured screen geometry keeps claiming the *coordinates* it was built for, even after the display moves. Geometry captured while the built-in display was the main display kept a 244x38 band alive at global coordinates that later belonged to empty space in the middle of an external monitor, and clicks there summoned the session window with nothing on screen to explain it.

## Transient Menu-Bar Popovers

The `+N` sessions popover and Usage glance are nonactivating menu-bar surfaces. Opening either surface must not activate Agent Visor or show or raise the Agent Sessions browser.

- The first `+N` click opens the sessions popover in place; a second click closes it.
- When session shortcuts are enabled, the configured modifier family plus `0` toggles the same `+N` popover. For example, selecting Option-Command uses `Option-Command-0`; `1` through `9` keep opening their numbered visible pills directly.
- Holding the configured modifiers replaces visible session status dots with `1` through `9` keycaps and replaces the `+N` label with a centered `0` keycap. Releasing the modifiers restores the original labels without changing any pill width or position.
- The overflow shortcut uses the current rendered `+N` snapshot and does nothing when no overflow pill exists. Holding `0` must not repeatedly open and close the popover.
- Clicking outside a transient popover dismisses it without consuming the click or activating Agent Visor. The click must still reach the app or menu-bar control the user chose.
- Opening `More Sessions` selects its first overflow session. With an empty query, Up and Down move through the flattened overflow rows across section boundaries and stop at the list ends; section headers and footer actions are not cursor stops.
- Return opens the selected session in its original owner when available, or opens Chat for an ownerless Chat-capable row. Option-Return opens it directly in Agent Visor Chat. Either action closes the popover.
- A compact search field sits below the header. Clicking it, pressing Command-F, or typing printable text starts search without opening or activating the full Agent Sessions browser.
- An empty query keeps the exact frozen `+N` overflow list. A non-empty query searches the complete recent navigable session snapshot, including sessions already visible as pills, because users should not need to know which side of the packing boundary contains the target.
- Popover search matches title, project, source, owner, and path. It does not search Chat content or preview text.
- Search results rank title matches before metadata matches, then use recency and stable session ID. They are presented as one result list rather than state sections.
- Editing the query selects its first result. Up and Down navigate results, Return opens the selected result's owner when available or Chat for an ownerless Chat-capable result, and Option-Return opens Chat in Agent Visor.
- Escape clears a non-empty query and keeps the popover open. A second Escape with an empty query dismisses the popover.
- The query resets whenever the popover closes.
- Keyboard commands handled by `More Sessions` must not leak to the previously active owning app. Pointer hover may add hover feedback but must not discard the keyboard cursor.
- Clicking a different pill closes the popover before performing that pill's action. Selecting a popover row closes it before navigation.
- A popover row accepts the first click even while Agent Visor is inactive. That click closes the popover and performs the row action; users must never click once to focus the popover and again to navigate.
- First-click delivery must not activate Agent Visor or raise the Agent Sessions browser. The transient surface remains nonactivating while its controls accept click-through.
- Clicking inside the popover without choosing an action keeps it open.
- With an empty query, the `+N` count and popover row count describe the same overflow set, and sessions already rendered as pills do not appear again. Search mode reports its own match count and may include visible pills.
- The overflow set and complete recent-session search catalog are captured when the popover opens and remain stable until it closes. Query edits may replace the overflow rows with ranked results, but background status or width changes must not make either list jump while the user is choosing.
- The footer provides separate actions for opening the full Agent Sessions browser and overall Agent Visor Settings. Settings closes the popover, activates Agent Visor, and preserves the last-selected settings category; it must not open the Agent Sessions browser as a side effect.
- The full Agent Sessions browser opens only through an explicit action such as `Open Agent Sessions`, the overflow context menu, the Dock, or the global window hotkey.
- Opening a transient popover must not change normal Dock or Cmd-Tab reopen behavior.
- The Usage glance follows the same nonactivating rule and must not summon the Agent Sessions browser as a side effect.

## Pill Hover Detail

The pill hover card is a compact session inspector. Its job is to confirm identity, current state, and the latest known execution configuration before the user navigates. It is not an action surface.

- Always show the full session title, shared session state, owning source, project path, and last-activity age.
- Show the latest known model and context-window usage when the owning source provides them.
- Show reasoning effort and execution policy when they are explicit in the latest turn. For Codex this includes reasoning effort, sandbox access, and approval policy.
- Treat model, effort, access, and approval values as latest-turn metadata because they may change between turns.
- Omit unavailable fields instead of displaying placeholders or inferring per-session values from unrelated global settings.
- Keep the card compact and non-interactive. Chat previews, tool lists, cumulative token totals, and navigation controls belong to the Sessions browser or Agent Visor Chat.
- The card owns an opaque, palette-matched content surface. It must not depend on native popover vibrancy or on colors sampled from the owning app, because terminal and editor content behind a translucent popover can destroy text contrast.
- Resolve the card surface and all text tiers from the same Agent Visor appearance. Latte uses a light opaque surface with dark text; Mocha uses a dark opaque surface with light text. Native positioning, arrow geometry, dismissal, and shadow may remain system-owned.
- Readability must remain stable over both black and white owning-app backgrounds, whether Agent Visor is active or inactive. Background translucency is not part of the hover-card aesthetic contract.
- Use a wider layout than the pill itself so labels remain explicit: `Reasoning`, `Access`, and `Context` must not rely on unexplained raw values.
- When a visible pill has an enabled 1-9 shortcut, show a quiet footer such as `⌥⌘3  Open directly`. Use the configured modifier family and the pill's position in the rendered left-to-right snapshot.
- Omit the shortcut footer when shortcuts are off or the pill has no numbered slot. The hint is instructional copy, not an interactive control.
- The hover card and a pill's context menu are mutually exclusive. Right-click dismisses the card and cancels any pending hover presentation before the context menu appears.
- Keep hover presentation suppressed while the context menu is tracking. Closing the menu must not reopen the card under a stationary pointer; the pointer must leave the pill and complete a fresh hover dwell before the card can return.
- A normal pill click dismisses the hover card before navigation.

## Model Identity And Presentation

A model identifier is provider data, not a human-facing label. Agent Visor preserves the raw identifier for matching, context-window resolution, and diagnostics while presenting the owning provider's canonical display name wherever that metadata is available.

- Pi resolves the latest active-branch provider and model identifier through Pi's read-only `models-store.json` catalog. Codex resolves rollout model identifiers through Codex's read-only `models_cache.json` catalog. Agent Visor never creates, refreshes, or writes either catalog.
- Provider catalog spelling, capitalization, and punctuation are authoritative for that provider. For example, Pi's `openai-codex` entry presents `gpt-5.6-sol` as `GPT-5.6 Sol`; a directly owned Codex session may retain Codex's `GPT-5.6-Sol` label.
- When catalog metadata is absent, known model families use one conservative shared fallback: Claude family identifiers retain the established compact form, GPT retains the uppercase brand and readable variant words, and unknown identifiers remain unchanged. Synthetic identifiers stay hidden.
- Chat status, model chips, pill hover detail, and Chat `Details` consume the same resolved session label. Views must not independently split, title-case, or punctuate raw identifiers.
- Technical `Details` may additionally expose the raw model identifier when it differs from the display label. Compact ambient surfaces show only the display label.
- A model change invalidates both the raw identifier and any display label attached to the previous identifier. A later catalog resolution may enrich the same raw identifier without altering session identity, phase, ordering, or usage accounting.

## Agent Visor Chat Entry And Naming

User-facing UI calls the desktop conversation surface **Chat**, not **Transcript** or **Inspect**. Transcript remains an implementation term for parsers, files, and diagnostic internals; it is not the name of the user task.

The rules in this section define the target behavior. The Electron migration
currently provides a bounded subset; its parity status and implementation
order are tracked in [Chat feature parity](chat-feature-parity.md).

- A normal Sessions-browser row click and Return open the canonical owner. If that destination is unavailable, activation safely falls back to Chat when renderable.
- Shift-Return opens Agent Visor Chat when renderable. If Chat is unavailable, it falls back to the owner.
- The row names its primary owner destination as `Open in <owner>` with an external-open symbol. It does not repeat the owner as a metadata chip.
- `Open Chat` remains an always-visible, visually secondary trailing action when both destinations are supported. Its hit target, hover, and selection surface stay separate from the primary row target.
- Chat replaces the browser content inside the same main window; it is not a modal sheet, popover, or permanent split pane.
- `Back to Sessions` restores the already-mounted browser with its query, keyboard cursor, and viewport intact.
- The Chat surface reuses Agent Visor's established Claude Code conversation, composer, approval, pagination, and status presentation. Pi reaches that same source-agnostic surface through its provider parser and text sender.
- Shared Chat presentation does not imply shared provider controls. A provider-specific control is visible, stateful, and actionable only when the owning provider defines that capability. In particular, Claude Code permission modes and their Shift-Tab cycle are Claude-only; non-Claude sessions must ignore stale mode metadata and cannot activate that route.
- The Chat header is a compact, single-line navigation toolbar: labeled Back navigation; a compact status glyph and stable session title; a quiet, always-visible `Open in <owner>` action; and an ellipsis overflow for optional technical Details. It does not repeat the provider logo, source/project subtitle, decorative separators, or a filled accent CTA.
- The canonical owner remains one click away while Chat retains visual priority. Technical metadata is optional in the overflow; status cards, latest-result summaries, and session-context cards must not precede the conversation.
- Historical or ended conversation content is labeled `Chat history` and visibly marked `Read only` when it cannot accept input. A metadata-only row falls back to its original owner rather than fabricating Chat.
- Context-menu actions duplicate the row and owner routes; they are never the only way to discover either destination.
- Conversation parsing remains lazy. Opening the Sessions browser alone must not parse a large conversation.

## Shared Session Semantics

Every surface uses the same phase meanings:

1. `Needs attention`: a structured human decision is blocking progress, such as an approval or user question.
2. `Ready`: the turn is complete or the agent is waiting for normal user input.
3. `Working`: the agent is processing or compacting.
4. `Recent`: no turn is currently active, but the session remains useful for navigation.

### Phase Evidence And Claude Desktop Recovery

- Direct lifecycle evidence remains preferred. Hook events and authoritative
  source metadata update `Needs attention`, `Ready`, and `Working`
  immediately when they are available.
- Claude Desktop is a hybrid source. Its long-lived worker process is not
  evidence that a turn is still running, its session metadata may omit a
  busy/idle status, and a completion hook may occasionally be absent.
- For a Claude Desktop session with unknown metadata status, Agent Visor uses
  the transcript as a completion fallback. A newer user/tool entry remains
  `Working`; a newer assistant entry that has stopped changing becomes
  `Ready`; and any completed transcript quiet past the existing 30-minute
  stale ceiling becomes `Recent`.
- Transcript fallback cannot override newer hook evidence or authoritative
  busy/terminal metadata. Pending approval, compaction, and ended states keep
  their stronger lifecycle semantics.
- Terminal Claude Code keeps its hook and metadata-first behavior. Merely
  keeping Claude Desktop or one of its worker processes alive never keeps an
  orange pill alive indefinitely.
- Agent Visor does not scrape Claude Desktop UI to recover phase.

The menu-bar strip and state-grouped browser surfaces use the same attention order, including whether a Ready completion has been seen:

1. `Needs attention`
2. Unacknowledged `Ready`
3. `Working`
4. Acknowledged `Ready`
5. `Recent`

Within an attention tier, newer phase-entry evidence sorts first and session ID is the stable tie-breaker. Within `Recent`, navigation recency remains the first ordering signal so frequently revisited sessions stay easy to recover, but a new navigation timestamp does not become order-effective until the spatial grace period expires. Source, owner, terminal host, and project do not change priority.

## Ready Completion Attention

- A pulsing `Ready` indicator means the current completed turn is recent and has not yet been acknowledged.
- Opening the session through an Agent Visor navigation surface acknowledges that specific completion. Its indicator becomes static immediately while the session remains `Ready`. In the menu bar, a separate activity-age fade continues from fresh green toward muted gray over 42 minutes.
- In the menu-bar strip, the first acknowledgment of a Ready transition holds the pill in its current Ready priority tier for two seconds so the clicked target does not appear to vanish. After that spatial grace period, it moves below Working pills. Reopening the same acknowledged completion does not restart the hold or promote the pill again. It may enter `+N` overflow when space is constrained, but it does not become `Recent`.
- A genuine phase change takes precedence over the spatial grace period. The hold never delays new status evidence or mutates session phase.
- State-grouped browser surfaces keep the row in `Ready`, move it between the two Ready attention groups, and preserve their keyboard cursor and viewport.
- Acknowledgment is scoped to the current Ready transition. A later completion has a newer phase-entry date and pulses again.
- A later Ready transition also returns the pill above Working until that completion is acknowledged.
- Navigation recency is recorded independently for `Recent` ordering and must not replace the Ready acknowledgment timestamp.
- The attention pulse expires after seven minutes even when it is not acknowledged.
- The Ready pulse must not saturate the compositor. Color-age updates run every 30 seconds, never inside the per-frame animation closure. Only opacity uses the throttled pulse schedule. This keeps per-frame cost near zero even when several indicators pulse simultaneously on a high-refresh display.
- The brief capsule press response remains separate click feedback and is not an attention signal.

### Ready Completion Notifications

- Agent Visor posts at most one `your turn` notification during one continuous `Ready` episode. The episode begins when a session enters `Ready` from another phase and ends when it leaves `Ready`.
- Notification identity follows that Ready episode, not rendered transcript shape. Late history hydration, thinking/text block expansion, tool-result reconciliation, metadata refresh, and same-phase evidence updates must not replace or repost the notification while the session remains Ready.
- A later genuine completion may notify again only after an intervening non-Ready phase such as `Working`, `Needs attention`, `Recent`, or `Ended` establishes a new episode.
- Resolving an attention episode retracts its Agent Visor notification. Approval notifications remain independently keyed to their explicit tool request.
- Agent Visor owns only notifications posted under its own application identity. Provider, terminal, and user-installed extension notifications remain independent; Agent Visor neither mutates nor silently disables them.
- Regression coverage must replay the observed Pi ordering where `agent_settled` publishes Ready before the debounced transcript replay adds final thinking and text rows. `Ready(count: 3216) → Ready(count: 3218)` produces one Agent Visor notification, while `Ready → Working → Ready` produces two.

## Navigation-Driven Spatial Grace

- Every pill move caused by a navigation action waits two seconds. The clicked target keeps its rendered position during that interval.
- Ready acknowledgment uses the Ready priority hold above. Recent navigation defers the recency commit that can move a grey pill to the front of the Recent tier.
- Repeating navigation during an existing hold does not restart its deadline. The latest navigation timestamp takes effect at the original deadline.
- Genuine phase evidence, archiving, removal, width changes, and other non-navigation layout changes remain immediate.
- A click that would not change ordering does not manufacture a move after the grace period.

## Visibility By Surface

- Hidden, ended, archived, and titleless sessions are excluded wherever their corresponding policy says they are not navigable.
- Pills are width-constrained. Sessions that do not fit are represented by `+N`; the overflow count is not a status count.
- With an empty query, the `+N` popover contains only default-overflow-eligible navigator sessions omitted from the current rendered pill snapshot. It keeps state grouping and ordering within that overflow set, including Chat-only History rows; searchable-only automation remains excluded from the default count.
- With a non-empty query, the popover searches the complete recent navigable snapshot and may return sessions already visible as pills. Search does not expand the observed window or invent historical rows.
- The popover header identifies the default rows as `More Sessions` and search results as `Search Sessions`. Its footer opens the complete workspace explicitly as `Open Agent Sessions`.
- The Sessions browser is the broadest surface. It includes current source-agnostic sessions plus supported saved Codex Desktop and Pi history that can be routed, opened in Chat, or viewed as Details according to actual capability.
- An explicit summon of the Sessions browser — the global window hotkey, the Dock, or an owner/overflow action — brings it to the foreground as the key window, raised above other applications' windows, even when another app is frontmost. macOS made cross-app activation cooperative, so a background summon must activate Agent Visor, promote the window to key, and order it front regardless of deferred activation; it must not leave the browser visible-but-behind. This is distinct from the nonactivating menu-bar popover and Usage glance, which never activate the app.
- Historical rows from unsupported sources are not invented from process metadata alone.

## Navigation Contract

- In the Sessions browser, a normal row click or Return opens the canonical owner when routing is supported. An ownerless Chat-capable row opens Chat as its primary action instead of exposing a dead owner action; the same fallback applies to its `+N` overflow row.
- Shift-Return opens Chat when renderable. `Open in <owner>` names the row's primary destination, while `Open Chat` remains a separate, quieter action.
- Pointer and keyboard activation agree. Menu-bar pills and the `+N` popover retain their original-owner-first behavior; Option-click or their explicit Agent Visor action enters Chat.
- Saved legacy browser-action and click-routing preferences are inert and must not override these surface-specific actions.
- A session pill's context menu contains only `Pill Settings...`. It does not repeat the normal open action or expose alternate click defaults.
- Routing is best effort. When a source cannot select an exact task, the UI must not claim exact routing.
- A navigation action records recency so frequently used `Recent` sessions remain easy to reach and the current Ready completion can be acknowledged. Recent ordering applies the new recency after the two-second spatial grace.

## Zed-Hosted Agent Ownership

A supported external agent thread hosted through Zed remains owned by Zed even though Claude, Codex, or Pi writes the canonical transcript. Zed's exact durable-session row owns the visible title, workspace, and navigation destination; provider-derived process names and standalone desktop fallbacks cannot replace that host identity.

Zed-hosted Chat is read-only. A normal pill or owner action activates the running Zed channel and target worktree. When the title query is unique and the user enables the behavior, Agent Visor may drive Zed's documented default sidebar-filter path and verify the persisted Agent Panel selection before reporting an exact reveal. Missing titles, duplicate titles, remapped keys, unsupported schemas, and failed verification degrade to activation plus an identifying toast rather than a false success or a prompt injection.

The detailed read-only database, liveness, identity, channel, keyboard-safety, and acceptance contract is defined in [Zed-Hosted Agent Integration](zed-integration.md).

## Automatic Pi Reboot Restoration

Automatic reboot restoration is a lifecycle capability, not a new navigation or Chat surface. When Agent Visor launches on a new macOS boot, it may recreate only the exact persisted interactive Pi sessions that it had accepted as live and Ghostty-owned before the prior boot ended.

Restoration is silent and does not summon the Sessions browser, post a confirmation dialog, replay a prompt, acknowledge a Ready episode, or change normal pill ordering. Successfully relaunched sessions re-enter every surface through the existing authoritative Pi `SessionStart` and heartbeat path. Failures remain diagnostics; no historical row is promoted to live and no substitute session is created.

Same-boot Agent Visor relaunches, sleep/wake, intentional Pi or Ghostty closure, and already-live exact owners never trigger a restoration launch. Ghostty layout is best effort, but the restored durable session-ID set is strict. The detailed lifecycle, identity, persistence, and fallback contract is defined in [Pi Integration](pi-integration.md#reboot-restoration).

## Non-Goals

- Reimplementing Codex, Claude Code, Cursor, Pi, or terminal chat experiences.
- Treating process existence as proof of a real session.
- Scraping agent UIs to manufacture unsupported status guarantees.
- Forcing identical row counts across pills, the popover, and the full browser.

## Change Control

Changes to surface purpose, state meaning, primary click behavior, or visibility scope require an explicit design decision and an update to this document before implementation.

Implementation policy belongs in `AgentVisorCore`; SwiftUI and AppKit views render policy results and route user intent. Each behavior change must add or update a Core test or a focused source-wiring audit. Visual-only changes still require manual verification on the menu-bar and main-window surfaces they affect.

Related contracts: [Menu-Bar Space Packing](menu-bar-packing.md), [Usage Glance](usage-glance.md), [Pi Integration](pi-integration.md), and [Zed-Hosted Agent Integration](zed-integration.md).

Full-screen visibility is specified in [Full-Screen Pill Behavior](full-screen-pills.md).
