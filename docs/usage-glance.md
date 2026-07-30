# Usage Glance

## Decision

Add read-only usage pills to Agent Visor's menu-bar utility area. The pills provide zero-click awareness of account limits when a provider actually exposes them. They complement each provider's own status UI rather than replacing it.

Two providers currently populate the shared right-side usage slot:

- **Codex** — 5-hour and 7-day rate-limit windows from the bundled app-server.
- **Claude (Anthropic subscription)** — monthly dollar-pool spend (e.g. `$18 / $600`) from the same endpoint Claude Code's `/usage` uses.

Each provider's preference expresses intent to show the glance when available; it does not force an empty utility slot. Provider capability and a meaningful snapshot determine whether a pill is rendered. When both are available they render side by side (Claude left of Codex) and share one hit region and one popover; when only one is available the slot narrows to just that pill.

## User Problem

The ChatGPT status item exposes Codex limits after a click, but a user who is actively running several agents cannot see approaching limits peripherally. The desired behavior is a stable, glanceable signal that does not disturb session ordering or require opening another menu.

## Menu-Bar Scope

- Codex renders recognized 5-hour and 7-day rate-limit windows, always ordered `5h` then `7d` when both are available.
- Two windows use `5h NN% | 7d NN%` in a fixed 114-point capsule; exactly one window uses only its available value (for example `7d 99%`) in a fixed 64-point capsule.
- Claude renders monthly spend as `$used/$limit` in its fixed 84-point capsule.
- Provider capsules remain on the right side of the notch, beside any `+N` overflow pill.
- Keep utility pills outside session ordering and overflow counts.
- Clicking toggles a compact popover with both windows, reset times, reset-credit count when available, and last-sync time.
- Add a `Show Codex usage when available` setting, enabled by default.
- Keep the feature read-only.

## Presentation

Codex uses 10.5-point medium text inside a 24-point-high capsule. A two-window presentation is fixed at 114 points and a one-window presentation is fixed at 64 points. Changing percentages within either shape cannot move adjacent session pills, and two available windows never reorder. A real capability-shape change may atomically repack sessions.

The usage pill has no status dot. Dots elsewhere in Agent Visor communicate session phase, while account usage has no session phase. Each percentage carries its own warning tone instead:

| Remaining | Tone |
| --- | --- |
| More than 25% | Neutral |
| 11% through 25% | Warning |
| 0% through 10% | Critical |

Normal values remain neutral. A warning or critical tone applies only to the affected percentage, not the whole pill. If a successful snapshot contains only one recognized window, the menu bar omits the unavailable placeholder and reserves only the 64-point one-window width. The menu bar never renders `5h --% | 7d --%`: while capability is unknown, or when Codex exposes no recognized window, no Codex width is reserved.

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

## Data Source — Codex

Use the bundled Codex app-server protocol:

- Request: `account/rateLimits/read`
- Notification: `account/rateLimits/updated`
- Primary fields: `usedPercent`, `windowDurationMins`, and `resetsAt`
- Optional field: `rateLimitResetCredits.availableCount`

The monitor uses the existing authenticated `CodexAppServerClient`; it does not scrape ChatGPT UI or read credentials directly.

## Data Source — Claude

Use the Anthropic OAuth usage endpoint (the same one Claude Code's `/usage` reads):

- Request: `GET https://api.anthropic.com/api/oauth/usage`
- Headers: `Authorization: Bearer <access>`, `anthropic-beta: oauth-2025-04-20`
- Parsed fields: the `spend` block (`used.amount_minor`, `limit.amount_minor`, `percent`, `severity`, `enabled`), falling back to `extra_usage` (`monthly_limit`, `used_credits`, `spend_limit_reached`).
- For Pro/Max accounts the `five_hour`/`seven_day` blocks would apply; on enterprise dollar-pool plans they are null and the spend block is authoritative.

The access token is read from Pi's credential store at `~/.pi/agent/auth.json`.

**Token safety (read-only):** Anthropic rotates refresh tokens on use, so the Claude monitor must never refresh or write the token — an independent refresh would invalidate Pi's stored credential and break Pi's own auth. When the access token is expired the pill goes stale and waits for Pi (which refreshes ~5 minutes before expiry) to rewrite `auth.json`. This endpoint is Claude Code's internal `/api/oauth/*` surface, not a documented public API; it can change and must fail closed (hidden) rather than erroring loudly.

The Claude tone follows the server `spend.severity` string when recognized, otherwise used-percentage thresholds (>=90% critical, >=75% warning).

Refresh on:

- app launch when the setting is enabled;
- `account/rateLimits/updated` notifications;
- Codex turn completion, with debounce;
- opening the usage popover;
- a five-minute fallback interval.

The latest successful snapshot remains visible if a later refresh fails, but the popover marks it stale.

## Layout And Input

Detailed pressure packing and safety invariants are defined in [Menu-Bar Space Packing](menu-bar-packing.md).

- Reserve the exact zero-, one-, or two-window Codex width from the right-side safe width before packing sessions.
- Keep Claude at its fixed 84-point width and add one normal inter-pill gap when both providers render.
- Hide a utility pill rather than overlap system status items when the right-side safe width cannot contain it.
- Include the usage slot in the same render-time `PillBarHitTest` snapshot used by session and overflow pills.
- A second click while the popover is open closes it.
- The usage slot never receives a Cmd+Option number shortcut.

## Non-Goals

- Cursor, Gemini, or full provider aggregation beyond Codex and Claude.
- Refreshing or writing any provider's OAuth token from Agent Visor.
- Usage history, burn-rate prediction, or forecasting.
- The Anthropic Admin API dollar `cost_report` (needs an `sk-ant-admin` key); the glance uses the OAuth usage endpoint the signed-in account already exposes.
- Notifications or automated limit management.
- Purchasing credits or consuming reset credits.
- Reproducing ChatGPT's full Usage screen.

## Test Contract

- Decode the live Codex rate-limit response shape.
- Clamp percentages and compute remaining capacity.
- Produce fixed-order `5h` and `7d` presentations with independent values and tones when both are available.
- Render only the recognized label when one window is missing, reserve 64 points, and never render a status dot.
- Hide the pill while checking without a prior snapshot and after an unsupported or failed first probe.
- Keep a meaningful prior snapshot visible after a transient refresh failure.
- Treat the preference as `show when available`; unsupported capability does not mutate it.
- Merge sparse account updates without erasing known windows or reset-credit data.
- Reserve the exact shape-specific right-side utility width before session packing and keep percentage-only updates width-stable.
- Keep `+N` counts limited to hidden sessions.
- Resolve usage clicks from the rendered snapshot, including second-click toggle behavior.
- Persist and apply the visibility setting.
- Verify the app-server method and notification wiring through source audits.
