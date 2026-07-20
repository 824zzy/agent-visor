# Sessions Browser Interaction Design

Status: Accepted
Last reviewed: 2026-07-19

## Purpose

The Sessions browser is the full, keyboard-friendly way to find a session and return to the app that owns it. It is not a persistent chat workspace.

The browser optimizes for two tasks:

1. Open an actionable or recent session with as little input as possible.
2. Search older supported history when the desired session is not visible in the menu bar or `+N` popover.

The product-level relationship between surfaces is defined in [product-surfaces.md](product-surfaces.md). Visual hierarchy and component presentation are defined in [session-browser-ui.md](session-browser-ui.md).

The `+N` popover is not a compact copy of this browser. It shows only sessions omitted from the rendered pill strip until the user searches. Popover search covers the current recent navigable snapshot by title and lightweight metadata; `Open Agent Sessions` opens this complete surface for broader browsing, saved history, transcript previews, and inspection.

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
- no metadata-only or fabricated history rows.

## Interaction State

The browser has three separate transient states. They must not be represented by one shared session ID.

| State | Meaning | May change scroll position? |
| --- | --- | --- |
| Pointer hover | The pointer is over a row | No |
| Keyboard cursor | The row targeted by arrow keys, Return, and Option+Return | Only when explicit keyboard navigation must reveal the row |
| Inspected session | The session shown in the inspector sheet | No; closing the sheet restores the same browser viewport |

Pointer hover is presentation only. It may change the row background or reveal secondary controls, but it must not change the keyboard cursor, open a session, select a session, or scroll the list.

The keyboard cursor starts at the first visible row when the browser opens or the query changes. Pointer movement never moves it.

## Input Contract

| Input | Result |
| --- | --- |
| Hover row | Show hover styling only |
| Click row | Open the original owner |
| Return | Open the keyboard-cursor row in the original owner |
| Option+Return | Open the inspector for the keyboard-cursor row |
| Up/Down | Move the keyboard cursor by one row and minimally reveal it if needed |
| Cmd+1 through Cmd+9 | Open the corresponding row in current visible order |
| Cmd+F | Focus search |
| Escape with a query | Clear the query and keep search focused |
| Info button | Open the inspector |
| Context menu | Offer explicit open, inspect, rename, and hide actions |

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
- inspector presentation or dismissal.

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
- closing the inspector preserves the viewport;
- archiving or hiding removes a row without an unrelated jump.

Source-wiring audits must reject an `onHover` path that calls `highlightSession` or any path that turns every highlight change into `scrollTo(..., anchor: .center)`.

Manual regression checks must include a long list, trackpad scrolling, a top-to-bottom pointer sweep, rapid phase changes, search entry and clearing, keyboard navigation, inspector open/close, and session removal.

## Regression Guard

Pointer hover and the keyboard cursor are deliberately separate. Source audits reject an `onHover` path that mutates the keyboard cursor and reject scroll wiring driven by every cursor-state change. Only explicit reveal requests from keyboard navigation or query changes may call `ScrollViewReader.scrollTo`.

## Implementation Boundaries

- Pure filtering, ordering, and interaction decisions belong in `AgentVisorCore`.
- `MainWindowViewModel` owns browser state and translates Core decisions into app actions.
- `MainSplitView` renders state and reports user input; it must not invent navigation policy.
- `SessionNavigator` and agent providers own original-app routing.
- The inspector remains explicit and lazy so opening the browser never parses a large transcript.
