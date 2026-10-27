# Sessions Browser Interaction Design

Status: Accepted
Last reviewed: 2026-10-21

## Purpose

The Sessions browser is the full, keyboard-friendly way to find a session, enter Agent Visor Chat, or return to the app that owns it. Chat is an in-window destination, not a modal inspector or permanent split pane.

The browser optimizes for three tasks:

1. Enter Agent Visor Chat for an actionable or recent session with as little input as possible.
2. Return to the session's canonical owner through an explicit, accurately labeled action.
3. Search older supported history when the desired session is not visible in the menu bar or `+N` popover.

The product-level relationship between surfaces is defined in [product-surfaces.md](product-surfaces.md). Visual hierarchy and component presentation are defined in [session-browser-ui.md](session-browser-ui.md).

The `+N` popover is not a compact copy of this browser. It shows only sessions omitted from the rendered pill strip until the user searches. Popover search covers the current recent navigable snapshot by title and lightweight metadata; `Open Agent Sessions` opens this complete surface for broader browsing, saved history, Chat previews, and session details.

## Data And Ordering

With an empty query, the browser shows the shared presence sections:

1. `Needs you` (`needsAttention`)
2. `In progress` (`working`)
3. `Ready` (`ready`)
4. `Status unavailable` (`unavailable`)
5. `Saved` (`history`)

Current membership is evidence-based: an exact open frontend or confirmed live per-conversation runtime remains Current regardless of age. A saved catalog or source-history record without live proof belongs in Saved and does not establish Current. Only a failed or temporarily unavailable observation belongs in `Status unavailable`. Confirmed closure with no surviving runtime is retained in Saved. Opening a Ready row marks its completion acknowledged without changing presence or lifecycle state. The menu-bar pill priority order remains independent of browser section grouping.

Lifecycle status is derived separately from placement. A known open conversation whose latest turn is Ready remains Ready (green) in the row, inspector, accessibility label, and native overflow. A reviewed idle Ready conversation becomes inactive at exactly thirty minutes of semantic inactivity, while remaining Current; busy turns stay orange and verified unanswered questions or permissions stay yellow. This presentation never archives a conversation or changes its lifecycle evidence.

Saved rows use a neutral gray mark. A confirmed closed row may retain the qualified `Closed` lifecycle detail, while an ordinary catalog/source-history row is labeled `Saved`; neither label claims that an unverified conversation is closed or inactive. Failed observations remain `Status unavailable`. Grouping, row text, status color, and accessibility labels use the same browser presentation, including search results. Agent Room records retain their management label. Working turns and pending approvals do not become saved merely because they are old.

Claude background jobs can remain in the catalog after their worker disappears. A retained `blocked` or `working` value remains unavailable until current evidence confirms liveness or closure; age alone never moves it to Saved. Its subtitle states the last reported state and safe actions remain available.

Real unanswered questions and permissions remain `Needs you` regardless of the underlying job's age. Current Busy status, including matching live worker metadata when the catalog omits that field, keeps a turn `In progress`. These status rules do not make an agent overview into a conversation pill.

Freshness is recalculated every minute and on window focus, visibility changes, and return to Sessions, even if the provider snapshot has not changed. Regrouping preserves the top visible session and its offset, subject to the scroll bounds, plus the keyboard target and query. Restart and reclassification preserve identity, source/profile, saved completion attention, and safe route provenance without restoring stale open/working proof or creating new flashes, notifications, navigation, or acknowledgments.

Rows sort by activity date descending within each group, then by stable session ID. A newer lower-priority row never jumps above a higher-priority group.

Search matches title, preview, project, source, owner, and path. Title matches rank before metadata matches; equally ranked rows use the same recency and stable-ID ordering as the empty-query view.

Agent Room backing sessions remain searchable and keep their current status and
source/Chat actions. Their subtitle and accessible row label say `Managed by
Agent Room`. They are excluded from menu-bar pills and the default `+N` count,
using the latest recorded Codex client identity rather than their title or project.

The browser merges:

- current navigable sessions from all supported sources;
- all saved, non-archived direct Codex tasks with real rollout evidence, including idle/unloaded tasks and tasks older than the observed-session window;
- saved Pi sessions with a valid session header and renderable active-branch transcript evidence;
- verified retained Saved metadata, including bounded metadata-only closed rows that no longer have a current provider catalog entry;
- no fabricated provider source rows from an unverified title, path, transcript guess, or other metadata.

Codex archival is the normal visibility boundary, not elapsed time. A successful empty catalog clears previous rows; a failed database read retains the last successful snapshot until recovery. The native menu shows only conversations with activity in the last seven days, including popover search, and keeps its existing bounds (64 physical candidates and 512 navigator rows); the full Sessions browser is not limited to those native batches.

### Retained Saved records and Ghostty Resume

Retained Saved records are a durable, bounded store of verified provider metadata and validated launch references. They survive daemon and app restart and do not expire merely because time has passed; explicit removal is required. These metadata-only rows remain distinct from fabricated provider source records. Open Chat reads an existing conversation when its transcript is available, while Resume is a separate, explicit cold-creation action.

- The first release can create a closed Claude Code or Codex CLI conversation only in the already supported Ghostty route, after fresh provider, process, and surface checks prove the exact identity.
- cmux, Herdr, iTerm2, Terminal.app, unsupported profiles or relocations, and ambiguous provider records remain searchable with an unavailable or repair explanation. Unknown liveness or failed identity evidence never launches a record.
- A row shows `Reopening…` during its one active attempt. `Retry resume` reconciles an uncertain dispatch receipt without creating a second surface; a fresh explicit Resume is required for a safe pre-creation retry. App startup never launches or retries a retained row.
- A repair changes only the selected row after explicit provider validation. It does not rewrite unrelated Saved records or turn an unverified source record into provider history.

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
| Click row | Open the canonical owner; if owner routing is unavailable, use the only supported Chat destination |
| Resume on a closed Saved row | Revalidate the retained provider identity and launch only when the exact Ghostty resume contract is eligible; otherwise keep the row and show its unavailable or repair action |
| Reopening / Retry resume | Keep the row visible while the attempt is active; reconcile an uncertain receipt without a second launch, or report the unavailable/unknown reason |
| Return | Apply the same source-first action to the keyboard-cursor row |
| Shift+Return | Open Agent Visor Chat; if Chat is unavailable, use the only supported owner destination |
| Up/Down | Move the keyboard cursor by one row and minimally reveal it if needed |
| Cmd+1 through Cmd+9 | Open the corresponding row in its canonical owner in current visible order |
| Cmd+F | Focus search |
| Cmd+= or Cmd++ | Increase the shared Sessions-and-Chat content font scale by 10% |
| Cmd+- | Decrease the shared Sessions-and-Chat content font scale by 10% |
| Cmd+0 | Reset the shared Sessions-and-Chat content font scale to 100% |
| Escape with a query | Clear the query and keep search focused |
| `Open in <owner>` label | Names the row's canonical owner inside the primary row target; its hover and selection stop before Chat |
| `Open Chat` action | Enter Agent Visor Chat through a separate, visually quieter target |
| Saved pagination | Load the next retained page using its cursor without dropping earlier rows or resetting the current query |
| Unavailable repair | Offer only the provider or working-directory references supported by that retained row; an invalid or unavailable repair leaves Saved unchanged |
| Details menu | Reveal optional source, owner, project, path, model, and last-tool metadata from the Chat header |
| Context menu | Duplicate `Open in <owner>` and `Open Chat` when available, plus hide |

Hotkey numbering follows the exact visible row order, including state groups and search ranking.

Content-scale commands remain active while browser search is focused and consume the matching keystroke without editing the query. Shift is permitted for the `+`/`_` keyboard forms, but Option-Command and Control-Command combinations are not content-scale gestures because they may belong to configured global session shortcuts. Changing scale preserves the query, keyboard cursor, and current Sessions-versus-Chat destination.

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
- row click and Return open the canonical owner when routing is supported;
- Chat-only rows fall back to Agent Visor Chat;
- Shift-Return opens Chat with capability-safe fallback;
- `Open in <owner>` names the row's primary destination without creating another button or owner chip;
- the always-visible Chat action opens only Agent Visor Chat and has an independent hover surface;
- no generic disclosure chevron hides the row's destination;
- opening the browser does not parse conversation content;
- Back preserves query, keyboard cursor, and viewport;
- browser font-scale commands work while search is focused without mutating the query;
- Option-Command and Control-Command global shortcuts are not consumed as font-scale commands;
- changing scale preserves the query, keyboard cursor, and current destination;
- scaled search, rows, owner actions, and footer grow without clipped text or horizontal scrolling;
- archiving or hiding removes a row without an unrelated jump.

Source-wiring audits must reject an `onHover` path that calls `highlightSession` or any path that turns every highlight change into `scrollTo(..., anchor: .center)`.

Manual regression checks must include long-list scrolling, a pointer sweep, rapid phase changes, search, keyboard navigation, row or Return owner opening, and session removal.

Also check Shift-Return, explicit Chat opening, Chat and Back, and Details.

## Regression Guard

Pointer hover and the keyboard cursor are deliberately separate. Source audits reject an `onHover` path that mutates the keyboard cursor and reject scroll wiring driven by every cursor-state change. Only explicit reveal requests from keyboard navigation or query changes may call `ScrollViewReader.scrollTo`.

## Implementation Boundaries

- In the Electron browser, `session-groups.ts` owns presentation, filtering, ordering, and cursor decisions. Provider summaries remain unchanged.
- `App.tsx` owns browser state and renders the shared presentation; `SessionViewport` captures the reading anchor before list mutations and restores it afterward. Query changes retain their explicit reveal behavior.
- Native menu policy remains in the daemon and `AgentVisorCore`, independent of browser freshness.
- `SessionNavigator` and agent providers own original-app routing.
- Pi-specific discovery and active-branch behavior follows [Pi Integration](pi-integration.md).
- Chat remains explicit and lazy so opening the browser never parses a large conversation.
- `WindowChatView` is source-agnostic: Claude Code and Pi share the same conversation UI while providers retain parsing and transport ownership.
- User-facing actions say `Enter Chat`, `Chat history`, or `Details`; `transcript` remains an internal data-format term.
