# Sessions Browser Interaction Design

Status: Accepted
Last reviewed: 2026-07-27

## Purpose

The Sessions browser is the full, keyboard-friendly way to find a session, enter Agent Visor Chat, or return to the app that owns it. Chat is an in-window destination, not a modal inspector or permanent split pane.

The browser optimizes for three tasks:

1. Enter Agent Visor Chat for an actionable or recent session with as little input as possible.
2. Return to the session's canonical owner through an explicit, accurately labeled action.
3. Search older supported history when the desired session is not visible in the menu bar or `+N` popover.

The product-level relationship between surfaces is defined in [product-surfaces.md](product-surfaces.md). Visual hierarchy and component presentation are defined in [session-browser-ui.md](session-browser-ui.md).

The `+N` popover is not a compact copy of this browser. It shows only sessions omitted from the rendered pill strip until the user searches. Popover search covers the current recent navigable snapshot by title and lightweight metadata; `Open Agent Sessions` opens this complete surface for broader browsing, saved history, Chat previews, and session details.

## Data And Ordering

With an empty query, rows are grouped by the same internal states in this order, using action-oriented browser labels:

1. `Needs you` (`needsAttention`)
2. `Ready to continue` (`ready`)
3. `In progress` (`working`)
4. `History` (`recent`)

Rows sort by activity date descending within each group, then by stable session ID. A newer lower-priority row never jumps above a higher-priority group.

Search matches title, preview, project, source, owner, and path. Title matches rank before metadata matches; equally ranked rows use the same recency and stable-ID ordering as the empty-query view.

The browser merges:

- current navigable sessions from all supported sources;
- saved, non-archived Codex Desktop tasks with real rollout evidence;
- saved Pi sessions with a valid session header and renderable active-branch transcript evidence;
- no metadata-only or fabricated history rows.

## Interaction State

The browser has three separate transient states. They must not be represented by one shared session ID.

| State | Meaning | May change scroll position? |
| --- | --- | --- |
| Pointer hover | The pointer is over a row | No |
| Keyboard cursor | The row targeted by arrow keys, Return, and Shift+Return | Only when explicit keyboard navigation must reveal the row |
| Chat destination | The session shown in full-window Chat | No; Back reveals the still-mounted browser at the same viewport |

Pointer hover is presentation only. It may change the row background or emphasize the already-visible owner action, but it must not change the keyboard cursor, open a session, select a session, or scroll the list.

The keyboard cursor starts at the first visible row when the browser opens or the query changes. Pointer movement never moves it.

## Input Contract

| Input | Result |
| --- | --- |
| Hover row | Show hover styling only |
| Click row | Enter Agent Visor Chat; if Chat is unavailable, open the only supported owner destination |
| Return | Apply the same Chat-first action to the keyboard-cursor row |
| Shift+Return | Open the canonical owner; if owner routing is unavailable, use the only supported Chat destination |
| Up/Down | Move the keyboard cursor by one row and minimally reveal it if needed |
| Cmd+1 through Cmd+9 | Open the corresponding row in its canonical owner in current visible order |
| Cmd+F | Focus search |
| Escape with a query | Clear the query and keep search focused |
| Chat disclosure chevron | Visually communicates the row's Chat destination; it is part of the row target, not a separate button |
| Open in `<owner>` action | Open the canonical owning app or terminal without entering Chat |
| Details menu | Reveal optional source, owner, project, path, model, and last-tool metadata from the Chat header |
| Context menu | Duplicate `Enter Chat` and `Open in <owner>` when available, plus hide |

Hotkey numbering follows the exact visible row order, including state groups and search ranking.

## Scrolling Contract

The viewport belongs to the user unless a direct navigation command requires a reveal.

The browser may scroll when:

- the user scrolls with a wheel, trackpad, or scrollbar;
- Up or Down moves the keyboard cursor outside the visible viewport;
- a query change needs to show its first result;
- the user explicitly invokes a jump command.

The browser must not scroll because of:

- pointer movement or hover transitions;
- relative-time updates;
- background discovery or phase changes;
- transcript refreshes;
- app focus changes;
- entering Chat or returning to the already-mounted browser.

Keyboard reveal uses the smallest movement that makes the target row readable. It must not center every row after every cursor change. When background data changes, preserve the top visible row and its offset when that row still exists. If a visible row is removed, preserve the nearest surviving neighbor rather than jumping to the current keyboard cursor.

## Async Update Contract

- Session phase changes may move a row between groups, but they do not seize the viewport.
- Background catalog updates preserve the query and keyboard cursor when that session still matches. Editing the query selects and reveals the first ranked result.
- Hiding or archiving removes the row immediately from the browser and menu surfaces.
- Renaming updates the row in place without changing its group, keyboard cursor, or viewport.
- Periodic timestamp rendering must not rebuild navigation state.
- Large transcript parsing never blocks list input or status rendering.

## Accessibility

- Every row exposes title, state, source, and project in its accessibility label.
- Every pointer action has a keyboard equivalent.
- Hover is never required to discover or invoke the primary action.
- Focus order follows visible row order.

## Test Contract

Core tests own filtering, grouping, search ranking, stable ordering, and hotkey order.

Interaction tests must prove:

- hover cannot mutate the keyboard cursor;
- hover cannot issue a scroll request;
- Up and Down issue a minimal reveal request for the new cursor;
- background refresh does not issue a scroll request;
- query changes select and reveal the first result;
- row click and Return enter Chat whenever the row can render Chat;
- owner-only rows fall back to their canonical owner;
- Shift-Return opens the owner with capability-safe fallback;
- the disclosure chevron belongs to the row's Chat target rather than creating another competing button;
- the always-visible owner action opens only the original owner;
- no repeated high-emphasis `Enter Chat` button competes with session identity;
- opening the browser does not parse conversation content;
- Back preserves query, keyboard cursor, and viewport;
- archiving or hiding removes a row without an unrelated jump.

Source-wiring audits must reject an `onHover` path that calls `highlightSession` or any path that turns every highlight change into `scrollTo(..., anchor: .center)`.

Manual regression checks must include a long list, trackpad scrolling, a top-to-bottom pointer sweep, rapid phase changes, search entry and clearing, keyboard navigation, row/Return Chat entry, Shift-Return owner routing, the explicit owner action, Chat/Back, optional Details, and session removal.

## Regression Guard

Pointer hover and the keyboard cursor are deliberately separate. Source audits reject an `onHover` path that mutates the keyboard cursor and reject scroll wiring driven by every cursor-state change. Only explicit reveal requests from keyboard navigation or query changes may call `ScrollViewReader.scrollTo`.

## Implementation Boundaries

- Pure filtering, ordering, and interaction decisions belong in `AgentVisorCore`.
- `MainWindowViewModel` owns browser state and translates Core decisions into app actions.
- `MainSplitView` renders state and reports user input; it must not invent navigation policy.
- `SessionNavigator` and agent providers own original-app routing.
- Pi-specific discovery and active-branch behavior follows [Pi Integration](pi-integration.md).
- Chat remains explicit and lazy so opening the browser never parses a large conversation.
- `WindowChatView` is source-agnostic: Claude Code and Pi share the same conversation UI while providers retain parsing and transport ownership.
- User-facing actions say `Enter Chat`, `Chat history`, or `Details`; `transcript` remains an internal data-format term.
