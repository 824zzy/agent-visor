# Copilot usage pill

`CP 92%` means 92 percent of the authenticated account's monthly AI-credit
allowance remains. It is one account usage pill, independent of the session
attention order and Codex quota. It reserves 64 points; balance changes do not
change its width. At 25 percent it turns amber, and at 10 percent it turns red.
It does not pulse. Click to see the credit balance, reset, last update, and a
link to GitHub's usage screen. Settings → Pills has a separate CP toggle.

The daemon reads `http://127.0.0.1:4141/usage` from the existing authenticated
Copilot bridge every five minutes and when the usage popover opens. Agent Visor
does not read or store GitHub tokens. `AGENT_VISOR_COPILOT_USAGE_URL` can select
another loopback port; only HTTP loopback `/usage` URLs without credentials,
queries, or fragments are accepted. Requests have a five-second deadline and
a 64 KiB response bound; redirects are rejected.

The bridge currently uses GitHub's undocumented `/copilot_internal/user`
endpoint. On 2026-10-05, its account and 140,000-credit allowance were checked
against the signed-in GitHub Copilot Business Usage screen. The displayed used
amount matched `entitlement - quota_remaining`, rounded to the nearest credit.
The separate `credits_used` counter did not match that screen and is ignored.
The `premium_interactions` bucket name alone is not proof of AI credits: both
token-based billing flags, a finite allowance, consistent remaining values, and
a future reset are required. Legacy request quotas, unlimited/uncapped seats,
and malformed payloads do not produce a fabricated credit balance.

There is no pill before the first valid read. A failed refresh keeps only that
provider's last observation, marked stale in amber (or red if already low), with
an explicit last-known tooltip and timestamp in the popover. Observations older
than ten minutes are stale. Reads coalesce per provider, and each successful
provider presents immediately without waiting for the other. Disabling either
usage pill does not disable the other.

GitHub's public [AI-credit billing reports](https://docs.github.com/en/rest/billing/usage)
report consumption, rather than a live remaining allowance. The internal source
can change; an unknown response must stay unavailable. Organization allowances
can differ from the organization-wide pool, so CP describes the authenticated
account's reported allowance. See [GitHub credit monitoring](https://docs.github.com/en/copilot/how-tos/manage-and-track-spending/monitor-ai-usage).
