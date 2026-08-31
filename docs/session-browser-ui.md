# Sessions Browser UI Design

Status: Accepted
Last reviewed: 2026-07-31

## Purpose

This document defines the visual design of the Sessions browser. It complements the [product surface contract](product-surfaces.md) and the [interaction design](session-browser.md).

The browser should feel like a focused macOS switcher: dense enough to scan quickly, calm enough to leave open, and explicit about which app owns each session. It must not resemble a second Codex or Claude chat client.

## Visual Principles

1. **Search is the primary control.** The browser opens directly into one compact search bar; it does not spend vertical space restating the window's identity.
2. **Title first, metadata second.** Session titles get the first readable line. Source and project chips support identification; Chat-only rows may also name a different owner.
3. **State is visible but restrained.** Status uses a small semantic mark and section placement, not a full-row color wash.
4. **Density without crowding.** Rows should expose enough context to distinguish sessions while preserving a steady scanning rhythm.
5. **No false selection.** Hover and keyboard cursor have distinct visual treatments. Entering Chat replaces the list rather than leaving a misleading selected row behind it.
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
| Chat content rail | Capped at the same `980` points and centered |
| Horizontal inset | `28` points |

The browser must not use a hero-sized empty area. At the default window size, the first section header should begin within roughly `90` points of the content top when no permission warning is present.

Wide windows keep the list and Chat rail centered instead of stretching rows indefinitely. Minimum-width windows use the available width after the 28-point insets and must not introduce horizontal scrolling.

## Content Scaling

The Sessions browser and Agent Visor Chat share one persistent content-text scale. The accepted range is 80% through 250% in 10% steps; all point sizes elsewhere in this document describe the 100% baseline.

- `Cmd+=` or `Cmd++` increases the scale, `Cmd+-` decreases it, and `Cmd+0` resets it to 100%. These commands work while either Sessions or Chat is visible, including while the browser search field is focused.
- Appearance presents the shared control as one compact `Content size` row inside the Display group, not as a dedicated subsection or Chat-only setting. The row shows the current percentage and a short slider; reset and keyboard-command discovery live in the View menu as `Zoom In`, `Zoom Out`, and `Actual Size`. The existing stored Chat scale remains the compatibility source so an upgrade preserves the user's selected percentage.
- In Sessions, the scale applies to search text and its inline symbol/hint, result counts, permission-health copy and actions, section labels/counts, row titles/subtitles/chips/ages/shortcut badges, owner actions, empty-state copy, and footer education.
- Brand logos, status dots, window controls, the Settings surface, and menu-bar surfaces remain fixed. Settings must remain usable as a recovery path at every content scale.
- Text containers grow from their existing minimum hit-target sizes instead of clipping scaled text. Search remains at least 40 points tall, rows at least 58 points, the footer at least 42 points, and owner actions at least 32 points.
- At high scales, preserve row information in title, source, project, and owner-destination order. The project chip may disappear and destination labels may compact.
- The footer may stack its shortcut groups at high scales. Scaling must not introduce horizontal scrolling.
- Changing scale never clears the query, changes the keyboard cursor, activates a row, or changes the visible product destination.

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
- Minimum height: 40 points; scaled content may make the field taller.
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
6. An `Open in <owner>` label with an external-open symbol inside the primary row target.
7. A fixed 138-point trailing `Open Chat` accessory when both destinations are supported.

The main content uses 13 points between the logo/status area and text. Activating an owner-routable row opens its canonical owner, exactly like Return. The owner label communicates that destination but is not a second button. Its selection and hover surface ends before the disjoint `Open Chat` action. Chat-only rows use Chat as their capability-safe row fallback.

### First Line

The first line is ordered:

1. Session title.
2. Source chip.
3. Project chip.
4. Owner chip only when a Chat-only row does not already name that owner as its destination.

Owner-routable rows do not repeat the owner as metadata because `Open in <owner>` already names it. The title is 14-point semibold and receives the highest layout priority. Chips use 10-point medium text, 6-point horizontal padding, 2-point vertical padding, and a low-opacity semantic tint.

When horizontal space is constrained, preserve information in this order:

1. Title.
2. Source chip.
3. Project chip.
4. Optional Chat-only owner chip.

Hide the optional owner chip first, then the project chip. Do not squeeze the title to a few ambiguous characters. Full metadata remains available from Chat Details and accessibility labels.

### Second Line

The second line is 12-point secondary text and remains one line.

- Current sessions show the latest useful activity preview.
- Rows without a preview show a shortened path.
- Historical Codex rows identify the history source before the shortened path.

The preview must not render raw markdown structure, tool payloads, or multiline text.

### Trailing Information

- Relative age: 11-point medium rounded text, minimum 28-point slot, tertiary color.
- Shortcut badge: fixed 35 x 24 point slot whether visible or hidden.
- Owner destination: `Open in <owner>` plus an external-open symbol inside the primary row button. It uses secondary text and may compact to the owner name or icon.
- Chat accessory: fixed 138-point slot when both destinations exist, disjoint from the row button and its selection surface.
- The Chat label aligns to the slot's leading edge. Unused width remains after the label, not between the two destinations.
- Chat action: 32 points high, 11-point semibold tertiary text, and transparent at rest. Only its own hover or press adds a quiet link surface.
- At constrained widths, `Open Chat` may compact to `Chat` and then to its chat icon. Its accessibility label always keeps the full action name.
- Owner-only rows omit the unavailable Chat accessory rather than inserting a disabled placeholder.
- Chat-only rows name Chat inside the primary row and omit the unavailable owner destination.

The fixed Chat accessory prevents rows from moving when Cmd shortcuts appear or timestamps change width. Capability changes may add or remove the whole secondary destination rather than leave a control whose label and action disagree.

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
| Primary hover | `ChatTheme.cardBg` at reduced opacity on the primary target | None | Source-app feedback only |
| Chat hover | Low-opacity semantic link surface on the Chat target | None | Chat feedback only |
| Keyboard cursor | `ChatTheme.cardBg` on the primary target | 1-point semantic link border at reduced opacity | Target for Return and Shift+Return |
| Pressed | Slightly stronger surface contrast on the pressed target | Existing geometry | No scale or position change |
| Chat open | Browser retained but hidden | Browser retained but hidden | Full-window Chat owns presentation |

Hover must not look stronger than the keyboard cursor. Hovering one target must not highlight the other. Do not animate row size, padding, logo size, or chip visibility between states.

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

- Minimum height: 42 points; at high content scales the local and global shortcut groups may stack.
- Left: `Up/Down Navigate`, then capability-aware Return and Shift-Return labels. A Chat-capable owner-routable row reads `Return Open source app` and `Shift+Return Open Chat`. The footer remains provider-neutral and stable; the row names the exact Codex, terminal, or editor destination. When only one destination is supported, show that action once rather than teaching a duplicate shortcut.
- Right: configured global shortcuts using intent-first labels: `1-9 Switch sessions` and `0 Session menu`. Numbered shortcuts still follow menu-bar pill reading order, while zero toggles the menu-bar session overflow; the teaching copy must not expose “pill” or “more sessions” implementation language.
- When global shortcuts are disabled, the right side says `Global shortcuts off · Configure in Settings`.
- Text: 10-point secondary and tertiary tiers.

The footer remains quiet and fixed. It is the durable teaching surface for keyboard acceleration without taking space from the primary search task. It must not become a toolbar of secondary actions. Do not show `Codex history included`; source chips and historical row copy already expose that scope.

## In-Window Agent Visor Chat

Chat is a full-content destination in the existing main window. It is not a modal sheet and not a permanent split pane.

The bullets below define the Swift behavior contract. They are not a claim
that the Electron replacement has complete parity. The current baseline and
the nine-phase implementation order are tracked in [Chat feature parity](chat-feature-parity.md).

- The Sessions browser remains mounted but hidden so its query, keyboard cursor, and scroll position survive without reconstruction.
- The header is a compact, single-line navigation toolbar between 44 and 48 points high. From left to right it contains the labeled `Back to Sessions` action, a compact status glyph plus the stable session title, a quiet always-visible `Open in <owner>` action when routing is available, and an overflow menu containing optional technical `Details`.
- `Back to Sessions` owns a 44-point rectangular hit target covering its arrow, text, and padding. The visible arrow area contains no dead space.
- Back, owner, and Details controls highlight independently. Hover adds link-colored content and a quiet rounded link surface without changing geometry.
- The toolbar does not repeat the provider logo, source/project subtitle, or a decorative vertical separator. `Open in <owner>` remains transparent and secondary at rest, while Details uses an ellipsis.
- The session title is the toolbar's only flexible item and truncates before navigation or actions become unusable. The status glyph has a phase-specific tooltip and accessibility label, so color is not its only available meaning.
- The conversation begins immediately below the header; no status summary, latest-result card, or session-context card precedes it.
- Chat reuses the existing Claude Code desktop conversation presentation: messages, tools, pagination, composer, approvals, and status bar.
- Chat has one responsive content rail shared with the Sessions browser. The rail is at most 980 points wide and centered; below that width it uses all space remaining after the 28-point window insets.
- Header controls, history rows, work disclosures and expanded tools, pagination and processing affordances, composer or approval controls, and status content align to that rail. The canvas, section backgrounds, dividers, scrolling viewport, and drill-down overlays remain full-bleed.
- The status bar presents the session's provider-resolved model display name. Pi catalog metadata therefore renders `gpt-5.6-sol` as `GPT-5.6 Sol`; raw identifiers remain available only through optional technical Details when they differ. Status, hover detail, and Details must not implement separate model-name formatting rules.
- The bottom status bar shares geometry across providers, not capabilities. Claude Code's permission-mode segment (`default`, `accept edits`, `plan`, and observed optional modes) appears only for Claude Code sessions. A terminal-owned Claude session may cycle it; a non-terminal Claude owner may show the latest mode read-only.
- Pi, Codex, Cursor, and every other non-Claude provider hide Claude permission modes even if stale or falsely probed mode metadata exists. Their Chat composers do not expose or forward Claude's Shift-Tab mode action. Rendering, terminal probing, optimistic state, Details, and keystroke delivery consume the same provider-capability decision so no layer can reintroduce the control independently.
- Assistant prose uses the rail width remaining after its status glyph. It has no independent readable-width frame and no decorative trailing spacer.
- Thinking prose uses the same basic inline-Markdown presentation as assistant prose, with the established quieter italic tone; raw emphasis markers are not shown as content.
- User prompts are trailing, content-hugging bubbles inside the rail. Short prompts keep balanced horizontal insets around their content; long prompts wrap only when the rail and the role-separating leading space require it. The rounded background never expands merely because the rail has spare width.
- Pi uses the same view. Its provider owns active-branch parsing. A live exactly routed Pi terminal accepts the shared image composer: Agent Visor saves each image locally, shows the existing thumbnail, and submits one ordered path-plus-text prompt through Pi's provider-aware terminal route. Historical or owner-only Pi rows remain read-only, and image submission never mutates the system clipboard or changes the bundled lifecycle extension.
- Technical metadata lives in the optional overflow `Details` menu and never becomes an intermediate destination.
- Historical or ended content that cannot accept input is titled `Chat history` and carries a visible `Read only` label.
- Metadata-only rows open their owner and omit the unavailable Chat accessory rather than exposing disabled or fabricated Chat.
- Opening the browser does not parse conversation content; parsing begins only after an explicit Chat request.

### TDD Implementation Record — Provider-Isolated Bottom Bar Modes

Status: Implemented, signed-deployed, and included in the regenerated local v2.5.0 release candidate on 2026-07-30. The user accepted the live Pi presentation with no Claude permission-mode chip and explicitly skipped the optional live Claude cycle; automated Claude terminal, editor, and tmux coverage passed.

- **RED — capability:** A captured `019f88a3` Pi fixture failed because no shared provider decision existed; the live symptom was a false Claude `default` chip beside Pi's `GPT-5.6 Sol` model label.
- **GREEN — capability:** `PermissionModeSurfacePolicy` now resolves display, cycle, probe, and state-update capability from provider ownership, TTY availability, and tmux routing. Claude terminal, tmux, editor, unknown-mode, Pi, Codex, Cursor, and Auggie cases are covered.
- **RED/GREEN — wiring:** Focused audits first failed, then proved that SessionStore hydration and live updates, both Chat variants, both composers, hover Details, presentation fingerprints, probe timers, and the final keystroke boundary consume that decision. Non-Claude mode metadata is invisible and inert even if stale state or a generic prompt-glyph probe reports `default`.
- **REFACTOR:** Probe start/stop follows live capability changes so a late Claude TTY attachment remains supported without leaving a timer active for Pi or another provider.
- **Validation:** 27 focused mode regressions and the complete 1,764-test Core suite passed; ad-hoc and pinned signed builds passed; the signed development app relaunched as one process with Accessibility Ready; release identity continuity, archive, cask, appcast, Sparkle signature, Homebrew push dry-run, and all release-policy gates passed. No tag, push, publication, or production-app launch occurred.

## Appearance And Accessibility

- Use `ChatTheme` semantic tokens; do not introduce raw light/dark colors in browser components.
- Small text and status tokens target at least 4.5:1 contrast against the browser canvas in light mode.
- Brand logos use the shared high-resolution source policy at all rendered sizes.
- Every row accessibility label includes title, state, source, project, and the stable action its activation will perform.
- An owner-routable row exposes `Open in <owner>` through its primary accessibility label. The decorative owner label is hidden from accessibility, while `Open Chat` has its own specific label and remains visible without hover.
- Keyboard focus and pointer hover remain independently perceivable.
- Reduced Motion disables optional fades. Core navigation never depends on animation.

## Motion And Stability

Permitted motion is limited to short opacity or color transitions. The following never animate position or size:

- row hover;
- keyboard shortcut reveal;
- phase changes;
- relative age updates;
- search result count changes;
- owner-action/disclosure emphasis.

Background updates may reorder rows according to the interaction contract, but must not create a decorative shuffle animation.

## Visual Regression Matrix

Review the browser at:

- default size and minimum size;
- 80%, 100%, 120%, and 250% content scales;
- light and dark appearance;
- empty, loading, populated, and no-results states;
- short and very long titles;
- same-source and mixed-source sessions;
- owner equal to source and owner different from source;
- all four state sections;
- Cmd shortcut badges hidden and visible;
- hover, keyboard cursor, Sessions-to-Chat, and Chat-to-Sessions states;
- large session counts and rapid status changes.

For each case, verify that titles remain the dominant text, logos are sharp, chips stay subordinate, the owner action does not read as disabled or compete with the row, rows do not move on hover or modifier changes, scaled text is not clipped, high-scale metadata/footer fallbacks preserve action labels or accessibility equivalents, no horizontal scrollbar appears, and the first section begins without excessive empty space.

## Change Control

Changes to browser hierarchy, row anatomy, status color meaning, responsive priority, or density require updating this document before implementation.

Reusable colors come from semantic theme tokens. Reusable geometry should be centralized rather than repeated as unrelated literals. Visual changes require focused source audits where practical and manual screenshots at default/minimum sizes in light and dark appearance.
