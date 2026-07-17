# Product Surface Contract

Status: Accepted
Last reviewed: 2026-07-16

## Purpose

Agent Visor is a status and navigation layer for coding-agent sessions. It helps the user see what needs action and return to the correct owning app with minimal input.

The owning app remains the authoritative conversation surface. Agent Visor may summarize or inspect a transcript, but it must not imply that a mirrored view is more complete or current than Codex, Claude Code, Cursor, or the terminal that owns the session.

This document is the product-level contract. Detailed browser behavior is specified in the [interaction design](session-browser.md) and [UI design](session-browser-ui.md).

## Principles

1. **Original first.** The primary activation action returns to the session's owning app or terminal using the best routing that source supports.
2. **Actionability before recency.** Needs-attention, ready, and working sessions appear before recent sessions when a surface has to prioritize.
3. **Honest capability.** UI copy and controls reflect the evidence and transport Agent Visor actually has. Inferred status and mirrored history are labeled as such.
4. **One session truth, different surface scopes.** Surfaces share session identity and phase semantics, but each surface may show a different subset for its job.
5. **No surprise movement.** Background discovery, status updates, and pointer hover must not take control of navigation or scrolling.
6. **Teach shortcuts in context.** Persistent product surfaces explain the keyboard path users can take from the action they are already performing. Shortcut education must reflect the configured keys rather than assume a default.
7. **Respect full-screen focus.** Pills do not cover a full-screen owning app at rest. The default full-screen behavior reveals them only in response to top-edge, shortcut, or explicit-popover intent.

## Surface Responsibilities

| Surface | Primary job | Content | Primary action | Must not become |
| --- | --- | --- | --- | --- |
| Menu-bar pills | Ambient status and fastest return path | Discoverable sessions, ordered by actionability then recency, packed to available width | Open original owner | A full history browser |
| `+N` popover | Quick access to sessions that do not fit as pills | The `+N` overflow by default; all recent navigable sessions while searching | Open original owner | A full history or transcript browser |
| Sessions browser | Complete searchable navigation | Current cross-source sessions plus supported saved history | Open original owner | A replacement chat client |
| Session inspector | On-demand evidence and diagnostics | Status evidence, latest activity, context, and mirrored transcript when available | Inspect or open original | An implicitly authoritative chat |
| Owning app | Canonical conversation and control | Native task, transcript, composer, tools, approvals, and source-specific UI | Continue work | Something Agent Visor attempts to duplicate wholesale |
| Usage glance | Peripheral account-capacity awareness when supported | Available Codex 5-hour and 7-day limits | Open compact usage detail | A placeholder for unavailable provider data |

## Shortcut Education

The Agent Sessions browser is the durable teaching surface for global session shortcuts. It must explain the configured shortcut family without adding a first-run modal, notification, or automatically presented menu-bar popover.

- The browser header replaces generic purpose copy with a compact `Global shortcuts` line.
- When shortcuts are enabled, the line shows the configured modifier family with `1-9` for opening numbered menu-bar pills and `0` for opening More Sessions. For the default Control-Command family, the rendered guidance is equivalent to `⌃⌘1-9  Open numbered pills` and `⌃⌘0  More Sessions`.
- The guidance describes menu-bar targets explicitly. It must not imply that `1-9` indexes rows in the full browser.
- When shortcuts are off, the same location says that global session shortcuts are off and directs the user to Settings.
- Shortcut glyphs come from the effective persisted setting. Copy must not hard-code Control-Command, Option-Command, or any other family.
- The browser footer is scoped to keyboard actions inside the browser: Up/Down navigates, Return opens the original owner, and Option-Return inspects.
- Generic copy such as `Find a session, then return to the app that owns it.` and `Codex history included` is omitted. The browser structure, source chips, and history rows already communicate those facts.
- Pill hover hints remain as contextual reinforcement for users who rarely open the browser.

## Transient Menu-Bar Popovers

The `+N` sessions popover and Usage glance are nonactivating menu-bar surfaces. Opening either surface must not activate Agent Visor or show or raise the Agent Sessions browser.

- The first `+N` click opens the sessions popover in place; a second click closes it.
- When session shortcuts are enabled, the configured modifier family plus `0` toggles the same `+N` popover. For example, selecting Option-Command uses `Option-Command-0`; `1` through `9` keep opening their numbered visible pills directly.
- Holding the configured modifiers replaces visible session status dots with `1` through `9` keycaps and replaces the `+N` label with a centered `0` keycap. Releasing the modifiers restores the original labels without changing any pill width or position.
- The overflow shortcut uses the current rendered `+N` snapshot and does nothing when no overflow pill exists. Holding `0` must not repeatedly open and close the popover.
- Clicking outside a transient popover dismisses it without consuming the click or activating Agent Visor. The click must still reach the app or menu-bar control the user chose.
- Opening `More Sessions` selects its first overflow session. With an empty query, Up and Down move through the flattened overflow rows across section boundaries and stop at the list ends; section headers and footer actions are not cursor stops.
- Return opens the selected session in its original owner. Option-Return opens it in Agent Visor. Either action closes the popover.
- A compact search field sits below the header. Clicking it, pressing Command-F, or typing printable text starts search without opening or activating the full Agent Sessions browser.
- An empty query keeps the exact frozen `+N` overflow list. A non-empty query searches the complete recent navigable session snapshot, including sessions already visible as pills, because users should not need to know which side of the packing boundary contains the target.
- Popover search matches title, project, source, owner, and path. It does not search transcript or preview text.
- Search results rank title matches before metadata matches, then use recency and stable session ID. They are presented as one result list rather than state sections.
- Editing the query selects its first result. Up and Down navigate results, Return opens the selected result, and Option-Return inspects it in Agent Visor.
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
- Keep the card compact and non-interactive. Transcript previews, tool lists, cumulative token totals, and navigation controls belong to the Sessions browser or inspector.
- Use a wider layout than the pill itself so labels remain explicit: `Reasoning`, `Access`, and `Context` must not rely on unexplained raw values.
- When a visible pill has an enabled 1-9 shortcut, show a quiet footer such as `⌥⌘3  Open directly`. Use the configured modifier family and the pill's position in the rendered left-to-right snapshot.
- Omit the shortcut footer when shortcuts are off or the pill has no numbered slot. The hint is instructional copy, not an interactive control.
- The hover card and a pill's context menu are mutually exclusive. Right-click dismisses the card and cancels any pending hover presentation before the context menu appears.
- Keep hover presentation suppressed while the context menu is tracking. Closing the menu must not reopen the card under a stationary pointer; the pointer must leave the pill and complete a fresh hover dwell before the card can return.
- A normal pill click dismisses the hover card before navigation.

## Shared Session Semantics

Every surface uses the same phase meanings:

1. `Needs attention`: a structured human decision is blocking progress, such as an approval or user question.
2. `Ready`: the turn is complete or the agent is waiting for normal user input.
3. `Working`: the agent is processing or compacting.
4. `Recent`: no turn is currently active, but the session remains useful for navigation.

State-grouped browser surfaces keep that literal order. The menu-bar strip additionally accounts for whether a Ready completion has been seen:

1. `Needs attention`
2. Unacknowledged `Ready`
3. `Working`
4. Acknowledged `Ready`
5. `Recent`

Within an attention tier, newer phase-entry evidence sorts first and session ID is the stable tie-breaker. Within `Recent`, navigation recency remains the first ordering signal so frequently revisited sessions stay easy to recover, but a new navigation timestamp does not become order-effective until the spatial grace period expires. Source, owner, terminal host, and project do not change priority.

## Ready Completion Attention

- A pulsing `Ready` indicator means the current completed turn is recent and has not yet been acknowledged.
- Opening the session through an Agent Visor navigation surface acknowledges that specific completion. Its indicator becomes static immediately while the session remains `Ready`, green, and active.
- In the menu-bar strip, the first acknowledgment of a Ready transition holds the pill in its current Ready priority tier for two seconds so the clicked target does not appear to vanish. After that spatial grace period, it moves below Working pills. Reopening the same acknowledged completion does not restart the hold or promote the pill again. It may enter `+N` overflow when space is constrained, but it does not become `Recent`.
- A genuine phase change takes precedence over the spatial grace period. The hold never delays new status evidence or mutates session phase.
- State-grouped browser surfaces keep the row in `Ready` and preserve their keyboard cursor and viewport.
- Acknowledgment is scoped to the current Ready transition. A later completion has a newer phase-entry date and pulses again.
- A later Ready transition also returns the pill above Working until that completion is acknowledged.
- Navigation recency is recorded independently for `Recent` ordering and must not replace the Ready acknowledgment timestamp.
- The attention pulse expires after seven minutes even when it is not acknowledged.
- The brief capsule press response remains separate click feedback and is not an attention signal.

## Navigation-Driven Spatial Grace

- Every pill move caused by a navigation action waits two seconds. The clicked target keeps its rendered position during that interval.
- Ready acknowledgment uses the Ready priority hold above. Recent navigation defers the recency commit that can move a grey pill to the front of the Recent tier.
- Repeating navigation during an existing hold does not restart its deadline. The latest navigation timestamp takes effect at the original deadline.
- Genuine phase evidence, archiving, removal, width changes, and other non-navigation layout changes remain immediate.
- A click that would not change ordering does not manufacture a move after the grace period.

## Visibility By Surface

- Hidden, ended, archived, and titleless sessions are excluded wherever their corresponding policy says they are not navigable.
- Pills are width-constrained. Sessions that do not fit are represented by `+N`; the overflow count is not a status count.
- With an empty query, the `+N` popover contains only the sessions omitted from the current rendered pill snapshot. It keeps state grouping and ordering within that overflow set, including idle observed sessions that did not fit.
- With a non-empty query, the popover searches the complete recent navigable snapshot and may return sessions already visible as pills. Search does not expand the observed window or invent historical rows.
- The popover header identifies the default rows as `More Sessions` and search results as `Search Sessions`. Its footer opens the complete workspace explicitly as `Open Agent Sessions`.
- The Sessions browser is the broadest surface. It includes current source-agnostic sessions and saved Codex Desktop history that can be routed safely.
- Historical rows from unsupported sources are not invented from process metadata alone.

## Navigation Contract

- A normal click or Return opens the original owner.
- Saved legacy click-routing preferences must not redirect an externally owned session into Agent Visor.
- Option-click on a pill, the info action, Option+Return, or a browser-row context menu opens Agent Visor inspection explicitly.
- A session pill's context menu contains only `Pill Settings...`. It does not repeat the normal open action or expose alternate click defaults.
- Routing is best effort. When a source cannot select an exact task, the UI must not claim exact routing.
- A navigation action records recency so frequently used `Recent` sessions remain easy to reach and the current Ready completion can be acknowledged. Recent ordering applies the new recency after the two-second spatial grace.

## Non-Goals

- Reimplementing Codex, Claude Code, Cursor, or terminal chat experiences.
- Treating process existence as proof of a real session.
- Scraping agent UIs to manufacture unsupported status guarantees.
- Forcing identical row counts across pills, the popover, and the full browser.

## Change Control

Changes to surface purpose, state meaning, primary click behavior, or visibility scope require an explicit design decision and an update to this document before implementation.

Implementation policy belongs in `AgentVisorCore`; SwiftUI and AppKit views render policy results and route user intent. Each behavior change must add or update a Core test or a focused source-wiring audit. Visual-only changes still require manual verification on the menu-bar and main-window surfaces they affect.

Related contract: [Usage Glance](usage-glance.md).

Full-screen visibility is specified in [Full-Screen Pill Behavior](full-screen-pills.md).
