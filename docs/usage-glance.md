# Usage Glance

## Decision

Add a read-only Codex usage pill to Agent Visor's menu-bar utility area. The pill provides zero-click awareness of both account limits when Codex actually exposes those limits. It complements ChatGPT's one-click status menu rather than replacing its full Usage view.

The user preference expresses intent to show the glance when available; it does not force an empty utility slot. Provider capability and a meaningful rate-limit snapshot determine whether the pill is rendered.

## User Problem

The ChatGPT status item exposes Codex limits after a click, but a user who is actively running several agents cannot see approaching limits peripherally. The desired behavior is a stable, glanceable signal that does not disturb session ordering or require opening another menu.

## V1 Scope

- Codex only.
- Show both rate-limit windows in one compound pill, always ordered `5h` then `7d`.
- Use `5h NN% | 7d NN%`, with each percentage meaning remaining capacity.
- Render a dedicated 114-point utility pill on the right side of the notch, beside any `+N` overflow pill.
- Keep the utility pill outside session ordering and overflow counts.
- Clicking toggles a compact popover with both windows, reset times, reset-credit count when available, and last-sync time.
- Add a `Show Codex usage when available` setting, enabled by default.
- Keep the feature read-only.

## Presentation

The pill uses 10.5-point medium text inside a 24-point-high, 114-point-wide capsule sized for `5h 100% | 7d 100%`. Changing percentages cannot move adjacent session pills, and the two windows never reorder.

The usage pill has no status dot. Dots elsewhere in Agent Visor communicate session phase, while account usage has no session phase. Each percentage carries its own warning tone instead:

| Remaining | Tone |
| --- | --- |
| More than 25% | Neutral |
| 11% through 25% | Warning |
| 0% through 10% | Critical |

Normal values remain neutral. A warning or critical tone applies only to the affected percentage, not the whole pill. If a successful snapshot contains only one recognized window, the other value remains `--%`. The menu bar never renders a persistent `5h --% | 7d --%` pill: while capability is unknown, or when Codex exposes no recognized window, no utility width is reserved.

## Availability

Usage visibility is capability-driven rather than inferred from an installed app, account label, or billing mode. A snapshot is meaningful when its presentation contains at least one numeric 5-hour or 7-day value. This accepts either explicitly identified 300-minute/10,080-minute windows or the protocol's primary/secondary fallback when duration metadata is absent.

| State | Menu-bar behavior | Settings behavior |
| --- | --- | --- |
| Preference off | Hidden | Toggle is off |
| Checking, no prior snapshot | Hidden; reserve no width | Explain that Agent Visor is checking |
| Meaningful snapshot | Show | Report that Codex usage is available |
| Refresh failure after a meaningful snapshot | Keep the last values; popover marks them stale | Explain that cached values remain visible |
| Codex missing, unauthenticated, unsupported, or no recognized windows | Hidden; reserve no width | Explain that the pill will appear automatically when supported |

Claude-only users therefore see no Codex usage pill. API-billed Codex users see it only if the app-server returns a meaningful 5-hour or 7-day window; Agent Visor does not guess from billing type. A failed probe never changes the user's preference, so installing or signing into Codex later can make the pill appear automatically on a subsequent refresh.

## Data Source

Use the bundled Codex app-server protocol:

- Request: `account/rateLimits/read`
- Notification: `account/rateLimits/updated`
- Primary fields: `usedPercent`, `windowDurationMins`, and `resetsAt`
- Optional field: `rateLimitResetCredits.availableCount`

The monitor uses the existing authenticated `CodexAppServerClient`; it does not scrape ChatGPT UI or read credentials directly.

Refresh on:

- app launch when the setting is enabled;
- `account/rateLimits/updated` notifications;
- Codex turn completion, with debounce;
- opening the usage popover;
- a five-minute fallback interval.

The latest successful snapshot remains visible if a later refresh fails, but the popover marks it stale.

## Layout And Input

- Reserve the fixed utility width from the right-side safe width before packing sessions only when the capability policy says the pill is visible.
- Hide the utility pill rather than overlap system status items when the right-side safe width cannot contain it.
- Include the usage slot in the same render-time `PillBarHitTest` snapshot used by session and overflow pills.
- A second click while the popover is open closes it.
- The usage slot never receives a Cmd+Option number shortcut.

## Non-Goals

- Claude, Cursor, Gemini, or provider aggregation.
- Usage history, burn-rate prediction, or forecasting.
- Notifications or automated limit management.
- Purchasing credits or consuming reset credits.
- Reproducing ChatGPT's full Usage screen.

## Test Contract

- Decode the live Codex rate-limit response shape.
- Clamp percentages and compute remaining capacity.
- Produce fixed-order `5h` and `7d` presentations with independent values and tones.
- Keep both labels in fixed order when one recognized window is missing and never render a status dot.
- Hide the pill while checking without a prior snapshot and after an unsupported or failed first probe.
- Keep a meaningful prior snapshot visible after a transient refresh failure.
- Treat the preference as `show when available`; unsupported capability does not mutate it.
- Merge sparse account updates without erasing known windows or reset-credit data.
- Reserve a fixed right-side utility width before session packing.
- Keep `+N` counts limited to hidden sessions.
- Resolve usage clicks from the rendered snapshot, including second-click toggle behavior.
- Persist and apply the visibility setting.
- Verify the app-server method and notification wiring through source audits.
