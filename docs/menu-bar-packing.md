# Menu-Bar Space Packing

Status: Accepted and implemented
Last reviewed: 2026-08-02

## Purpose

Agent Visor should show as many high-priority session pills as the measured menu bar can safely contain. Visible empty fragments are acceptable only when the next ordered session cannot fit under any approved presentation profile. They must not result from fixed placeholders, stale arithmetic, or a greedy choice that can be improved without changing session priority.

This contract complements [Product Surfaces](product-surfaces.md), [Usage Glance](usage-glance.md), and [Full-Screen Pill Behavior](full-screen-pills.md).

## Observed Problem

A representative 2052-point menu bar produced this verified layout:

- left safe width: `515` points;
- right safe width: `383` points;
- per-side notch-edge padding: `8` points;
- rendered left sessions: `448` points, leaving `59` usable points;
- rendered right session plus `+N`: `133` points inside a `169`-point session budget, leaving `36` usable points;
- Claude plus Codex usage slot: `202` points;
- hidden sessions: `+7`.

The two sides therefore held approximately `95` points of fragmented packing slack while sessions remained hidden. Neither fragment alone could hold the next ordered pill at its current width.

The safe widths were not wrong. They already excluded the measured application-menu and system-status boundaries. The inefficiency came from atomic pill widths and the fixed 114-point Codex usage capsule displaying an unavailable `5h --%` value.

## Acceptance Result

The capacity-aware revision was verified through fixed Core fixtures and a signed development build:

- the measured `507 / 210` session-capacity fixture chooses five pills left and one right instead of the former four-left/two-right split;
- a fixed tiered-label fixture exposes eight ordered sessions where full/compact labels expose only six;
- the measured `515 / 383` usage-shape fixture proves that replacing the 114-point placeholder with the truthful 64-point one-window Codex shape exposes one additional eligible session without changing priority order;
- a residual-backfill fixture proves that an unaffordable higher-priority upgrade no longer blocks an independently affordable lower-priority upgrade on the same side;
- the screenshot fixture restores `Codex St...` to `Codex Stupid...` from the right-side 20-point fragment without changing its eight-session prefix or split;
- exactly one 8-point notch-edge padding layer now feeds both rendering and hit testing, recovering 8 points per side while leaving the far-side menu/status bounds unchanged;
- one representative 12-candidate pressure/headroom pack now performs 7 actual overflow text measurements instead of 709 and completes in approximately 2.14 ms in Debug, so the accepted variant search remains unchanged;
- the complete Core suite passed 1,796 tests after the width-cache amendment;
- `scripts/dev-build.sh`, deep strict signature verification, deployment, and launch succeeded;
- Accessibility health returned to `ready`, with exactly one development process running.

Stable passive evidence after deployment showed `leftSafe=515`, `rightSafe=374`, standard density, a 152-point combined usage slot, six sessions left, two right, and `+5`. Residual backfill rendered `pi-intern-pa...` and `Codex Stupid...` at their compact tiers while retaining tight tiers only where the next upgrade could not fit. No application-menu, notch, or system-status overlap was visible on the Retina display.

The live `+5` is an observation, not a durable guarantee: session order, widths, and usage shape change over time. Durable acceptance comes from the fixed candidate fixtures above. The original later screenshot remains the regression case: under its fixed candidates, residual-capacity balancing must choose five-left/one-right and the approved tight tier must expose the longer ordered prefix without bypassing priority.

## Safety Invariants

Space efficiency must not weaken collision safety.

1. Keep the left application-menu margin at `28` points.
2. Keep the right system-status margin at `16` points.
3. Keep the existing `8`-point per-side notch-edge padding.
4. Unknown or unreliable menu/status evidence continues to fail safe to less space, including zero.
5. A wider application menu or a newly occupied status-tray region contracts capacity immediately according to the existing boundary policies. Status-tray evidence must come from the configured pill display; items on another display cannot reduce its right-side capacity.
6. Packing never extends outside `leftSafeWidth` or `rightSafeWidth` and never borrows width across the hardware/rendered notch.
7. Render geometry and click hit-testing consume the same packing plan; a pressure layout must not be reconstructed independently in the view or click resolver.

The previous Outlook overlap is specifically a reason not to reclaim width by reducing safety margins.

## Ordering Invariants

1. Candidates remain ordered by the shared pill-surface priority policy.
2. Visible sessions are always the highest-priority prefix of that ordered list.
3. A shorter lower-priority pill never bypasses a hidden higher-priority pill merely because it fits a fragment.
4. The left side contains the visible prefix and the right side contains the remaining visible suffix, preserving left-to-right reading order across the notch.
5. `+N` remains at the session reading end on the right whenever the right side can safely contain it.
6. Overflow contains exactly the ordered sessions not rendered on either side.
7. Session titles remain stable identities. Pressure may truncate according to the approved label tiers but may not substitute activity text.

## Usage-Slot Compaction

Usage presentation is compacted by available data, not by hiding meaningful data under pressure.

### Codex

- Two recognized windows: retain the current fixed 114-point `5h NN% | 7d NN%` capsule.
- Exactly one recognized window: render only that value in a fixed 64-point capsule, for example `7d 99%`.
- No recognized windows: render no Codex capsule and reserve no Codex width.
- Never render an unavailable `--%` window beside a meaningful value in the menu bar. The popover may explain unavailable windows when useful.
- Percentage changes do not change width. Width changes only when the recognized-window shape changes from zero, one, or two windows.

### Claude

The compact Claude `CC $<remaining>` capsule remains fixed at 68 points. Its provider identity is explicit in the `CC` label and accessibility text; the full used/limit breakdown stays in the popover.

### Shared Slot

When both providers render, one normal inter-pill gap separates their capsules. The right-side reservation is derived from the exact provider widths that will render. The same value feeds rendering and hit-testing.

## Session Pressure Profile

The normal profile remains unchanged:

- session font: 11 points;
- pill height: 24 points;
- status dot: 6 points;
- horizontal padding: 7 points per side;
- inter-pill spacing: 4 points.

When sessions are hidden, Agent Visor may evaluate one global pressure profile:

- same font, height, dot, colors, and hit behavior;
- horizontal padding: 5 points per side;
- inter-pill spacing: 3 points.

Label presentation is evaluated independently inside each density:

- **Full**: the stable session identity, capped by the existing 22-character surface limit.
- **Compact**: the established recognizable 12-character prefix plus ellipsis.
- **Tight**: an 8-character prefix plus ellipsis, used only when it exposes a longer visible prefix than all less-truncated alternatives.

Compression remains priority-safe: no plan may downgrade a higher-priority identity merely to improve a lower-priority one. Among plans with the same visible prefix, the first differing higher-priority label must use the less-truncated tier. Once every higher-priority label is already at its best affordable tier on its assigned side, a lower-priority label may consume residual capacity that the higher label cannot use. This side-local readability backfill prevents an unaffordable 22-point upgrade from blocking a later 19-point upgrade and does not alter visibility, side assignment, or session order. Full labels therefore return automatically when capacity permits; tight labels are not a cosmetic density choice.

From normal density, pressure is adopted only when it renders a longer highest-priority prefix. It is not entered merely to make the bars look fuller.

To prevent a 1–6 point AX fluctuation from toggling every pill between densities, a currently pressured layout remains pressured until normal density can preserve the same visible count with at least 8 points of release headroom on the constrained side. The pure transition policy receives the current density; no timer is required, and safety contraction is never delayed.

## Packing Decision

For each refresh:

1. Resolve safe widths through the existing owner-bound left policy and status-tray right policy.
2. Resolve the truthful zero/one/two-window usage widths.
3. Reserve the exact usage slot from the right side.
4. Pack the ordered session candidates with the normal profile, including existing lower-priority label compaction.
5. If sessions remain hidden, evaluate the pressure profile using the same candidate order and overflow rules.
6. Choose the best plan inside each profile lexicographically:
   1. more visible sessions;
   2. less truncation at the first differing higher-priority session;
   3. lower total truncation severity;
   4. smaller largest residual safe width across the two sides;
   5. smaller difference between the two residual widths;
   6. more sessions on the left when every prior objective ties.
7. Apply the density transition rule: normal enters pressure only for a longer prefix; pressure returns to normal only with equal visibility plus release headroom.
8. Within the selected split, backfill label readability in global priority order. For each visible session, choose the best fuller tier that fits its assigned side without changing any earlier tier, visibility, overflow, or side assignment.
9. Publish one immutable packing plan containing side assignment, visible label mode, exact rendered widths, spacing, padding, overflow side/count, and usage-slot width.
10. Render and hit-test that exact plan.

Residual slack is correct only when no longer highest-priority prefix fits under the full/compact/tight variants of either density and no visible label can be independently restored without sacrificing a higher-priority tier. Atomic residuals that remain are distributed by capacity: minimizing the largest unused side takes precedence over making the rendered bars themselves look equal.

## Measurement Performance

Packing runs on the main thread, so expensive font measurement must be bounded independently of the number of candidate variants evaluated.

- Session and overflow text widths are deterministic for a process-lifetime tuple of text, font size, and font weight. `PillBarCoordinator` caches that measurement and keeps content scale out of the key because menu-bar pills remain fixed-size by design.
- The packer's `overflowPillWidthFor` callback is treated as an expensive deterministic boundary. One top-level `pack` memoizes its result per distinct hidden count and shares that cache across standard, pressure, and release-headroom evaluations.
- Rendering reuses the exact selected tier widths instead of introducing a second uncached measurement path.
- Width caching may not alter safe capacities, candidate order, density selection, label tiers, overflow identity, or hit-test geometry.

The existing suffix-tier search remains the correctness reference. After callback and text-width caching, a representative 12-candidate Debug probe must be reassessed. The search is simplified only if pure packing still consumes a material portion of a frame; avoiding speculative algorithm replacement is preferred because ordering and tier tie-breaks are safety-sensitive.

## Stability

- Changing a percentage or dollar amount within the same usage shape does not move session pills.
- Sparse usage updates continue to merge with prior known windows, so transient omissions do not repeatedly switch between one- and two-window widths.
- A real usage-capability shape change may repack sessions atomically; no position animation is added.
- Pressure begins only when it improves visible count and ends only after the release-headroom rule is satisfied.
- Navigation spatial grace, status priority, stable titles, and overflow snapshot freezing remain unchanged.
- Packing continues while full-screen policy hides the strip so keyboard shortcuts retain a current snapshot.

## Accessibility And Input

- Compact usage text retains full provider/window meaning in its accessibility label and popover.
- Truncated session pills retain the full title in hover detail and accessibility text.
- Shortcut numbering follows the final rendered session order only.
- `+N` remains the count of sessions hidden by the final chosen plan.
- Session, overflow, and usage clicks resolve from the final plan's exact widths and spacing.

## Non-Goals

- Reducing menu or status safety margins.
- Reordering sessions by width or skipping a higher-priority session.
- Moving usage capsules to the left side.
- Hiding a meaningful Codex usage window merely to fit another session.
- Shrinking font size, status dots, or pill height.
- Removing `+N` when sessions genuinely remain hidden.
- Combining free fragments across the notch as though they were one continuous region.

## Test Contract

Core tests must prove:

1. A one-window Codex snapshot renders one value, reserves 64 points, and contains no `--%` placeholder.
2. A two-window Codex snapshot remains 114 points and percentage changes do not change that width.
3. Zero recognized Codex windows reserve zero width.
4. The shared Claude+Codex slot uses the exact provider widths plus one gap.
5. The normal profile remains behaviorally equivalent to current 7-point padding and 4-point spacing behavior.
6. Pressure is selected only when it reduces hidden count.
7. Normal density wins when both profiles show the same prefix with release headroom.
8. The highest-priority visible prefix is preserved; no shorter lower-priority candidate bypasses a hidden candidate.
9. Compact and tight labels apply from lower-priority suffixes before higher-priority identities are shortened, and a less-truncated tier wins whenever visibility is equal.
10. With 507 points left and 210 points right, the screenshot fixture chooses the feasible five-left/one-right split over four-left/two-right because it has the smaller largest residual.
11. Tight suffix labels expose a longer ordered prefix when full and compact variants leave otherwise unusable fragments.
12. `+N` equals the final hidden IDs and remains on the right when feasible.
13. Zero safe width still renders no pills rather than overlapping menus or status items.
14. A fixture matching `leftSafe=515`, `rightSafe=383`, Claude width 84, and one-window Codex width 64 shows at least one more eligible short session than the current two-window-placeholder layout when the supplied candidate widths permit it.
15. The render-time and hit-test snapshots use the plan's exact density, label tier, per-pill widths, overflow width, and usage width.
16. If a higher-priority label's next tier cannot fit, a lower-priority label whose next tier does fit consumes that side-local residual without changing the visible prefix or split.
17. Exactly one 8-point notch-edge padding layer separates pills from each notch edge. Removing the duplicate layer increases the Core budget by 8 points per side while preserving the existing far-side application-menu and status-item collision boundaries.
18. One top-level pack invokes the overflow-width callback no more than once for each distinct count, even when standard, pressure, and release-headroom paths are all evaluated.
19. App wiring uses the shared process-lifetime text-width cache for full, compact, tight, selected render, and overflow labels without changing fixed menu-bar typography.
20. A multi-display fixture ignores status-item windows outside the configured pill display when resolving the right safe boundary.

Source-wiring audits must reject independent hard-coded session padding, spacing, Codex width, a second notch-edge padding layer, or uncached duplicate text measurement in rendering and hit testing once the packing plan owns those values.

## TDD Implementation Record

Implementation proceeded as vertical slices. Each slice wrote one behavioral test, observed RED, applied the smallest production change, and returned to GREEN before the next test.

### Slice 1 — Truthful one-window Codex usage

**RED:** Add `CodexUsageGlanceTests.testSingleRecognizedWindowUsesCompactMenuBarShape` asserting that a seven-day-only snapshot produces `7d 99%`, contains no `5h --%`, and reserves 64 points.

**GREEN:** Add a shape-specific Core presentation/width and update only the Codex capsule rendering and right-side reservation to consume it. Keep the two-window path at 114 points.

**Regression:** Existing parser, availability, tone, two-window ordering, popover, and Claude usage tests remain green.

### Slice 2 — Shared usage-slot geometry

**RED:** Add a pure shared-slot test asserting Claude 84 + one-window Codex 64 + one 4-point gap equals 152 points, while Claude + two-window Codex remains 202 points.

**GREEN:** Move combined usage-slot arithmetic behind one Core value returned to `PillBarCoordinator`; remove independent fixed-width reconstruction from rendering and hit-testing.

**Regression:** Usage clicks still resolve to one shared hit region, second-click toggle behavior remains unchanged, and `+N` counts only sessions.

### Slice 3 — Pressure profile selection

**RED:** Add a `PillBarPackerTests` fixture where standard 7-point/4-point geometry hides the third ordered pill but 5-point/3-point pressure geometry fits all three. Assert that pressure is chosen because hidden count decreases.

**GREEN:** Extend the pure packing interface with standard and pressure profiles plus the selected profile in `PackResult`. Reuse the existing ordered-prefix, compact-suffix, overflow, and balancing logic for each profile; choose pressure only on a strictly better hidden count.

**Next RED:** Add the mirror case where pressure changes geometry but does not reduce hidden count; assert standard wins. Apply the minimal profile-choice tie-break.

### Slice 4 — Release-headroom stability

**RED:** Add boundary fixtures around a 1–6 point capacity fluctuation, passing the current density into the transition. Assert a pressured layout remains pressured until standard can preserve the same visible prefix with 8 points of constrained-side headroom.

**GREEN:** Add the release-headroom transition to the pure profile selector. Store only the selected density at the app boundary; do not add a timer or alter menu/status edge policies.

### Slice 5 — One immutable render/hit-test plan

**RED:** Add a wiring audit requiring the chosen profile's spacing, padding, per-pill widths, overflow width, and usage width to reach both `NotchPillBar` and `PillBarHitTest`. Reject direct use of global standard metrics in those paths.

**GREEN:** Make `PillBarCoordinator.Pack` carry immutable layout metrics and rendered widths. Update `PillButton`, `OverflowPillButton`, snapshot construction, and hit testing one route at a time. Keep height, font, status-dot, hover, popover, and click semantics unchanged.

### Slice 6 — Representative full packing fixture

**RED:** Add the measured `515 / 383` safe-width fixture with current session widths, Claude 84, one-window Codex 64, and overflow. Assert that the final plan shows an additional eligible session while retaining the same ordered prefix and safety budgets.

**GREEN:** Make only the integration adjustment exposed by that fixture. Do not relax margins or reorder candidates to force the assertion.

### Slice 7 — Regression and live acceptance

Run focused suites after every slice, then the complete Core suite. Build only with `scripts/dev-build.sh`. Verify code signing and `git diff --check`.

Passive/live acceptance records:

- safe widths and final per-side slack;
- mathematical versus rendered pill frames;
- usage slot shape and width;
- visible ordered IDs and exact overflow IDs;
- hit resolution for sessions, `+N`, and usage.

Manual app switching to Outlook, adding/removing system status items, or other foreground mutation requires explicit action-time approval. The acceptance criterion is one additional visible session when the approved profile permits it, with no overlap and no incorrect click target.

### Slice 8 — Capacity-aware residual balancing

**RED:** Reproduce the later screenshot with 507 points left, 210 points right, six visible candidates, and right-side overflow. Assert five-left/one-right instead of four-left/two-right.

**GREEN:** Replace rendered-width balancing with a capacity-aware objective that minimizes the largest residual, then residual imbalance, while preserving the chosen visible prefix and reading order.

### Slice 9 — Tight lower-priority label tier

**RED:** Extend the screenshot fixture so full and compact labels expose six sessions while recognizable tight suffix variants expose eight. Assert the same highest-priority prefix and exact hidden IDs.

**GREEN:** Add full/compact/tight candidate variants to Core packing. Select variants by visible count, priority-lexicographic truncation, and total severity; carry the chosen label tier and exact width through the immutable render/hit-test plan.

### Slice 10 — Residual readability backfill

**RED:** Add a fixed two-label fixture where both tight labels fit, the higher-priority label's next tier does not fit, and the lower-priority label's next tier does. Assert that the lower label upgrades without changing visibility, order, or split.

**GREEN:** Backfill selected label tiers in global priority order inside the immutable Core plan. A backfill may consume only residual capacity on the label's assigned side and may never downgrade another label.

### Slice 11 — One notch-edge padding layer

**RED:** Add app-wiring and geometry regressions proving the renderer and hit-test snapshot use one 8-point notch-edge offset and that the far-side menu/status bounds remain unchanged while each Core budget gains the duplicate 8 points.

**GREEN:** Remove the inner duplicate notch padding, stop subtracting it from the Core budgets, and update hit-test anchors from two edge paddings to one. Keep the measured menu/status policies and their 28/16-point margins unchanged.

### Slice 12 — Bounded width measurement

**RED:** Add a 12-candidate pressure/headroom fixture whose callback records requested overflow counts. Require every distinct count to be measured once while preserving the exact existing plan. Add a source-wiring regression requiring one shared text-width cache across candidate construction, selected-tier rendering, and overflow materialization.

**GREEN:** Memoize overflow widths at the outermost Core packing boundary and add a process-lifetime AppKit measurement cache keyed by text, fixed font size, and weight.

**REFACTOR:** Re-run a representative Debug cost probe after caching. Keep the suffix-tier search unchanged if its remaining pure-logic cost is comfortably bounded; any later search replacement must reproduce the complete existing fixture suite before adoption.

**RESULT:** The representative 12-candidate pressure/headroom probe reduced actual overflow text measurements from 709 to 7 and measured approximately 2.14 ms per Debug pack. The remaining pure variant search was comfortably bounded, so simplifying it was unnecessary and the accepted geometry logic was retained.

Manual validation must cover:

- Ghostty's narrow menus and Outlook's wider menus;
- app switching and same-app menu changes;
- system status items appearing and disappearing;
- Codex with zero, one, and two recognized windows;
- Claude-only, Codex-only, and combined usage;
- standard-to-pressure and pressure-to-standard thresholds;
- `+N` content and shortcut numbering;
- 1x external and 2x Retina displays;
- full-screen hidden/reveal behavior;
- passive frame diagnostics confirming rendered and mathematical widths agree.

## Implementation Boundary

- Usage shape and width policy belong in `AgentVisorCore`.
- Density selection and ordered packing remain pure `AgentVisorCore` logic.
- `PillBarCoordinator` adapts sessions and usage snapshots into the Core plan and owns the fixed-font text-measurement cache.
- `NotchPillBar` renders the plan without inventing geometry.
- `PillBarHitTest` consumes the same plan.
- `NotchMenuLayoutPolicy` and `StatusTrayLayoutPolicy` remain unchanged by this work.
