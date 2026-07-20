# Sessions Browser UI Design

Status: Accepted
Last reviewed: 2026-07-19

## Purpose

This document defines the visual design of the Sessions browser. It complements the [product surface contract](product-surfaces.md) and the [interaction design](session-browser.md).

The browser should feel like a focused macOS switcher: dense enough to scan quickly, calm enough to leave open, and explicit about which app owns each session. It must not resemble a second Codex or Claude chat client.

## Visual Principles

1. **Search is the primary control.** The browser opens directly into one compact search bar; it does not spend vertical space restating the window's identity.
2. **Title first, metadata second.** Session titles get the first readable line. Source, project, and owner chips support identification without competing with the title.
3. **State is visible but restrained.** Status uses a small semantic mark and section placement, not a full-row color wash.
4. **Density without crowding.** Rows should expose enough context to distinguish sessions while preserving a steady scanning rhythm.
5. **No false selection.** Hover, keyboard cursor, and inspector state have distinct visual treatments. None should look like a persistent chat selection.
6. **Stable geometry.** Hover, modifier keys, status changes, and relative-time updates must not resize or move rows.

## Window And Canvas

| Property | Contract |
| --- | --- |
| Default content size | `1040 x 720` points |
| Minimum usable size | `960 x 640` points |
| Resizing | Fully resizable; preserve content during live resize |
| Canvas | `ChatTheme.headerBg` across the browser |
| Main content width | Results capped at `980` points and centered |
| Command bar/footer width | Capped at `980` points and centered |
| Horizontal inset | `28` points |

The browser must not use a hero-sized empty area. At the default window size, the first section header should begin within roughly `90` points of the content top when no permission warning is present.

Wide windows keep the list centered instead of stretching rows indefinitely. Minimum-width windows must not introduce horizontal scrolling.

## Page Structure

The browser has three vertical regions:

1. Compact command bar: search, transient result count, loading state, and Settings.
2. Scrollable session list: state sections and rows.
3. Fixed footer: browser navigation hints plus configured global shortcuts.

Dividers separate these regions using the semantic card-border token. The structure must remain visible in both light and dark appearance.

## Command Bar

- Do not render an in-content `Agent Sessions` title. The window and app already provide identity; the visible task begins with search.
- Use a single horizontal row ordered as search, optional search-result count, historical loading, and Settings.
- Top and bottom padding: 12 points.
- Search expands to the available content width instead of preserving an empty summary area.
- Settings uses a 34 x 34 point chrome button with an 8-point corner radius.
- Historical loading uses a small progress indicator beside Settings; it must not replace or move the search field.
- A permission-health warning may appear below the command row because it requires action. It is the only content allowed to expand this region vertically.

Do not add illustrations, large metrics cards, state dashboards, gradients, shortcut teaching, or workspace banners above the list.

### Search Field

- Placeholder: `Search all sessions`.
- Height: 40 points.
- Corner radius: 10 points.
- Horizontal content inset: 13 points.
- Text: 14-point regular.
- Search icon: 13-point medium.
- Focus is shown with the semantic link color and a slightly stronger border, never a glow.
- Empty search shows a compact `Cmd+F` hint. Non-empty search replaces it with a clear button in the same trailing area.

The trailing control area keeps a stable width so entering text does not move the field contents.

### Search Result Count

With an empty query, show no aggregate state counts. They duplicate the section headers and make the command bar read like a dashboard. During search, show one quiet result count between search and Settings.

## Section Headers

- Order and user-facing labels:
  1. `Needs you` for structured approvals or questions.
  2. `Ready to continue` for a completed turn or normal user input.
  3. `In progress` for processing or compacting.
  4. `History` for idle sessions retained for navigation.
- Label: 12-point semibold secondary text.
- Count: 10-point semibold rounded text in a quiet capsule.
- Horizontal inset relative to the result column: 10 points.
- Top spacing: 11 points. Bottom spacing: 5 points.

Section headers never use project names as primary grouping. Project remains row metadata so state priority stays source-agnostic.

## Session Row Anatomy

The row uses a minimum height of 58 points and a 10-point continuous corner radius.

Left to right:

1. State mark: 8-point circle in a fixed 10-point slot.
2. Agent logo: 28 x 28 points from the shared high-resolution brand source.
3. Text and metadata column.
4. Relative age in a fixed trailing slot.
5. Keyboard shortcut slot with stable geometry.
6. Inspector button in a 38 x 42 point target.

The main content uses 13 points between the logo/status area and text. The primary button covers the full row except the dedicated inspector target.

### First Line

The first line is ordered:

1. Session title.
2. Source chip.
3. Project chip.
4. Owner chip, only when owner differs from source.

The title is 14-point semibold and receives the highest layout priority. Chips use 10-point medium text, 6-point horizontal padding, 2-point vertical padding, and a low-opacity semantic tint.

When horizontal space is constrained, preserve information in this order:

1. Title.
2. Source chip.
3. Project chip.
4. Owner chip.

Hide the owner chip first, then the project chip. Do not squeeze the title to a few ambiguous characters merely to preserve every chip. Full metadata remains available in the inspector and accessibility label.

### Second Line

The second line is 12-point secondary text and remains one line.

- Current sessions show the latest useful activity preview.
- Rows without a preview show a shortened path.
- Historical Codex rows identify the history source before the shortened path.

The preview must not render raw markdown structure, tool payloads, or multiline text.

### Trailing Information

- Relative age: 11-point medium rounded text, minimum 28-point slot, tertiary color.
- Shortcut badge: fixed 35 x 24 point slot whether visible or hidden.
- Inspector glyph: 13-point medium.

Fixed slots prevent rows from moving when Cmd shortcuts appear or timestamps change width.

## State Color

| State | Semantic token | Visual use |
| --- | --- | --- |
| Needs you | `ChatTheme.statusPending` | State mark |
| Ready to continue | `ChatTheme.statusSuccess` | State mark |
| In progress | `ChatTheme.statusRunning` | State mark |
| History | `ChatTheme.tertiary` | Neutral state mark |

Color never carries state alone. Section placement and accessibility text provide the same meaning. Chips use brand or metadata tints only as quiet identification, not status.

A freshly completed, unacknowledged `Ready` turn may pulse for at most seven minutes. Opening that session through Agent Visor acknowledges the current completion and makes the mark static without changing its color, browser section, or browser row position. The menu-bar pill may move below Working according to the product-surface attention order. A later Ready transition may pulse and return to the higher menu-bar tier again.

## Row States

| State | Background | Border | Behavior |
| --- | --- | --- | --- |
| Default | Transparent | None | Resting list row |
| Hover | `ChatTheme.cardBg` at reduced opacity | None | Pointer feedback only |
| Keyboard cursor | `ChatTheme.cardBg` | 1-point semantic link border at reduced opacity | Target for Return and Option+Return |
| Pressed | Slightly stronger surface contrast | Existing geometry | No scale or position change |
| Inspector open | Browser row unchanged | Browser row unchanged | Sheet owns inspector emphasis |

Hover must not look stronger than the keyboard cursor. Do not animate row size, padding, logo size, or chip visibility between states.

## Empty, Loading, And Error States

### Empty Workspace

Use a small neutral stack icon, `No sessions available`, and one sentence naming supported starting points. Keep the state centered within the result region with a minimum height of 330 points.

### No Search Results

Use a search icon, `No matching sessions`, and a suggestion to try title, project, source, or path. Keep the query intact.

### Historical Loading

Show the small header progress indicator while current sessions remain interactive. Never replace the list with a blocking spinner.

### Partial Failure

If saved history fails to load, keep current sessions usable and show a compact, dismissible explanation near the header. Do not present an empty workspace when live sessions are available.

## Footer

- Height: 42 points.
- Left: `Up/Down Navigate`, `Return Open original`, `Option+Return Inspect`.
- Right: configured global shortcuts using compact key labels: `1-9 Open pills` and `0 More sessions`.
- When global shortcuts are disabled, the right side says `Global shortcuts off · Configure in Settings`.
- Text: 10-point secondary and tertiary tiers.

The footer remains quiet and fixed. It is the durable teaching surface for keyboard acceleration without taking space from the primary search task. It must not become a toolbar of secondary actions. Do not show `Codex history included`; source chips and historical row copy already expose that scope.

## Inspector Presentation

Inspection is an explicit modal sheet, not a permanent right pane.

- Current-session inspector minimum: `760 x 560` points.
- Historical-session inspector minimum: `680 x 440` points.
- The sheet shows status evidence, latest activity, context, and mirrored history only when available.
- Closing the inspector restores the exact browser query, keyboard cursor, and viewport.

The browser behind the sheet must not change visual selection to imply that the inspected row is now the canonical active session.

## Appearance And Accessibility

- Use `ChatTheme` semantic tokens; do not introduce raw light/dark colors in browser components.
- Small text and status tokens target at least 4.5:1 contrast against the browser canvas in light mode.
- Brand logos use the shared high-resolution source policy at all rendered sizes.
- Every row accessibility label includes title, state, source, and project.
- The inspector button has a minimum 38 x 42 point target and a specific label.
- Keyboard focus and pointer hover remain independently perceivable.
- Reduced Motion disables optional fades. Core navigation never depends on animation.

## Motion And Stability

Permitted motion is limited to short opacity or color transitions. The following never animate position or size:

- row hover;
- keyboard shortcut reveal;
- phase changes;
- relative age updates;
- search result count changes;
- inspector-button emphasis.

Background updates may reorder rows according to the interaction contract, but must not create a decorative shuffle animation.

## Visual Regression Matrix

Review the browser at:

- default size and minimum size;
- light and dark appearance;
- empty, loading, populated, and no-results states;
- short and very long titles;
- same-source and mixed-source sessions;
- owner equal to source and owner different from source;
- all four state sections;
- Cmd shortcut badges hidden and visible;
- hover, keyboard cursor, and inspector-open states;
- large session counts and rapid status changes.

For each case, verify that titles remain the dominant text, logos are sharp, chips stay subordinate, rows do not move on hover or modifier changes, no horizontal scrollbar appears, and the first section begins without excessive empty space.

## Change Control

Changes to browser hierarchy, row anatomy, status color meaning, responsive priority, or density require updating this document before implementation.

Reusable colors come from semantic theme tokens. Reusable geometry should be centralized rather than repeated as unrelated literals. Visual changes require focused source audits where practical and manual screenshots at default/minimum sizes in light and dark appearance.
