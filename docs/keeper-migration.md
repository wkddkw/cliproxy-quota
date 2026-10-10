# Keeper mobile integration (local draft)

This change adds an explicit Keeper backend while preserving existing CLIProxyAPI
connections. Existing saved connections default to CPA; new connections default
to Keeper. Configure the complete HTTPS URL including its base path, such as
`https://keeper.example.com/keeper`, and enter the administrator password in the
app. No deployment-specific password, token, address or account data is embedded.

## Interface

- Quota: provider cards show the minimum **healthy** account remaining percentage,
  with the count of available accounts. It is not a combined balance. Drill down
  for account/window detail; failures and timestamps remain visible.
- Usage: today (Keeper server timezone), rolling 7 days or 30 days; choose API-key
  user, upstream account or model. Costs are estimates, never supplier invoices.
  Shared client keys cannot identify separate people.
- Settings: backend, connection, existing Android refresh/notification controls.
- Warm paper/card colors are inspired by CPA Usage Keeper. Implementation is new
  Flutter code, not copied frontend source.

## API contract

Pinned reference: Willxup/cpa-usage-keeper `778b5f8e7196f3fb1eae8f11b63f51de33ea80ed`.
Routes are relative to `<base>/api/v1`. Password login obtains a same-origin
HttpOnly session cookie; POST requests send `X-CPA-Usage-Keeper-Request: fetch`.
Redirects are not followed. Cookies exist only for the operation, then logout is
attempted; the administrator password uses existing OS-backed secure storage.
This first version deliberately trades persistent-session efficiency for simple,
scoped sessions. It may cause login rate limits on rapid repeated refreshes.

Quota uses paginated `/usage/identities/page?auth_type=1`, `/quota/cache`,
`/quota/refresh` and `/quota/refresh/{auth_index}`. Use `identity`, not numeric
identity `id`, as the quota auth index. Polling is bounded; per-account transient
failures preserve cached observations and do not hide other successful accounts.
Unknown balances stay unknown. Weekly Grok credits, monthly USD and PAYG are
separate windows. `usd_cents` is converted to dollars exactly once. Window usage
is never mistaken for remaining allowance. Generic API-provider credentials are
not assumed to have official quota support.

Usage reads `/usage/overview` and `/usage/analysis`, using `range=today|7d|30d`.
No statistics resets, credential edits or server refresh-setting changes occur.
API-key viewer login is not implemented; all-account quota needs admin access.

## Notifications

- Retryable top-level network/429/5xx failures request WorkManager retry; wrong
  credentials and invalid configuration do not enter a retry loop.
- Background snapshots are stored in an epoch-tagged local slot and are consumed
  by the foreground UI. Late data from a previous server connection is ignored.
- Notification anchors are scoped to account and window; identifiers in native
  payloads are hashed, and the native notification cache does not contain credentials or account names.
- Temporary invalid samples preserve the last valid anchor. Removed accounts are
  removed from anchor state. Reset timestamps tolerate one minute of drift.
- Android WorkManager timing is still opportunistic. iOS has no background
  monitoring in this patch. Server-side push is **not** included; it needs a
  separately chosen push channel and server deployment authorization.

## Verification boundary

This is a local draft, not a production-validated release. See the included test
report for executed Flutter analyze/tests and standalone Kotlin tracker tests.
Before shipping, run Android native Gradle tests, release build and real-device background/VPN/Doze/force-stop scenarios. Verify the deployed
Keeper version and its live API contract after secure login. Nothing has been
pushed, published or deployed.

## v0.1.10 unified connection and explicit reset

The default connection form now accepts one host, protocol and port. CPA uses the
origin; Keeper uses `/keeper`. Management-page and Keeper-page URLs may be pasted
into the host field; their page path/fragment is removed. Advanced settings allow
independent full endpoints. Old saved connections retain their original addresses
until edited. Credentials remain distinct in OS-backed storage; no password is
copied from CPA to Keeper or vice versa. Enabling Keeper selects it for quota and
usage; disabling it uses direct CPA quota queries.

GPT/Codex and Claude Keeper account details expose reset-rights inspection.
Read-only inspection uses `/quota/reset-credits/{auth_index}` or
`/quota/claude-reset-grants/{auth_index}`. Only an explicit confirmation invokes
POST `/quota/reset`; Claude forwards the selected grant and organization IDs.
This consumes official rights. It is not a usage-statistics reset, scheduled task,
or quota-display refresh. No live reset was executed during development.

Unknown availability disables reset. Double submission is disabled, and uncertain
responses never auto-retry. One attempted action locks the action for that page
session, including when refreshing its rights list. A follow-up quota query
updates cached amounts. Official success with CPA recovery failure is reported
separately to avoid encouraging duplicate consumption.

Token counts now use decimal K/M/B with up to two decimals and exact-number
details. The daily dimension aggregates server-calendar buckets; opening a day
queries custom/day start=end for both overview and per-key composition. Partial
positive cost remains visible with a partial marker, consistent with Keeper's
heatmap; unknown and unpriced amounts are not presented as free usage.
