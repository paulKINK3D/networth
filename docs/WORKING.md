# WORKING

## Current State (2026-07-31)
The app foundation and the Net Worth, Projections, Accounts, Investments, sync, security, persistence, and tutorial workflows are implemented around the product north star in `docs/PLAN.md`: help the user understand upcoming cash obligations before they become a problem, with clear supporting reporting for the broader financial picture.

**Active branch:** `feature/plaid-transactions`. The completed Plaid Investments work is merged. This branch adds a staged path for Plaid Transactions to replace YNAB as the source for non-investment, non-loan accounts and new transactions.

The Worker maintains product-aware Items, requests up to 730 days of history,
exposes cursor-based added/modified/removed transaction pages, and supports
consent upgrades for an existing investment Item. It does not call Plaid
Recurring Transactions or Transactions Refresh. Normalized accounts,
transactions, cursors, and match evidence stay in the disposable local cache.

The transaction migration is now YNAB-first. YNAB payees, categories, stable
transaction IDs, transfer IDs, and split legs seed durable editable Networth
directories. Plaid merchant/counterparty IDs, names, and normalized
descriptions are aliases that may point to a canonical contact; they are not
contacts or category rules themselves. The durable models are
`DurableCanonicalPayee`, `DurablePayeeAlias`,
`DurableCanonicalCategory`, and
`DurableCanonicalTransactionDecision`.

The former merchant-rule/name-review result is deliberately discarded by a
versioned one-way migration. Raw YNAB/Plaid rows, account mappings, and
user-created categories survive. Existing transaction/payee cursors are reset
once so YNAB can replay the stable IDs required by the new matcher.

Every Plaid account must be explicitly mapped to its YNAB predecessor or marked
new. Reconciliation waits for every historical import to finish and uses exact
canonical account plus milliunit amount with a bounded date window. Its
maximum-cardinality assignment avoids greedy duplicate matching. Exact matches
copy YNAB contact/category/treatment/split decisions and do not enter review;
ambiguous or unmatched rows do.

Only posted transactions enter the future queue. Every new posted transaction
requires confirmation, even with a strong prefill. Confirmation links aliases
to a selected contact and stores one transaction-specific decision. All
confirmed decisions add evidence for future suggestions, but mixed
category/treatment history causes no category preselection instead of
last-write-wins behavior. Apple inference and optional privacy-bounded Claude
fallback may suggest names/categories but never approve them. Card payments
and internal transfers have no category. Hidden YNAB categories remain valid
only on exact historical decisions.

Contacts and categories are editable from Accounts → Networth Data. Contacts
can be created, renamed, archived, merged, and have aliases reassigned.
Categories can be created, renamed, regrouped, and hidden. User edits survive a
later YNAB source refresh. Review counters use `fetchCount`, remain zero until
the current historical reconciliation completes, and the review sheet fetches
one row at a time.

Positive transactions that are not identified as income default to the Refund
treatment. They retain a mapped Plaid/YNAB spending category when available
and otherwise fall back to Other; positive cash flow alone never assigns the
Income category.

Pending local cleanup and historical-reconciliation migrations run during app
bootstrap. They do not wait for the network-sync freshness window.

Plaid account detail keeps its 30-day activity summary lightweight and links to
full posted history. Full history uses an indexed account/status/date query and
fetches 50 rows per page rather than loading or sorting the complete transaction
cache in memory. Recent and historical rows are tappable; opening a row reuses
the transaction editor so confirmed decisions can be corrected.

The Plaid Investments iOS path is implemented and validated on-device in Sandbox and Production Trial. LinkKit 7.0.3 opens from Settings, exchanges its short-lived public token through the private backend, syncs Items/accounts/securities/holdings independently from YNAB, supports unlinking, and requires explicit per-account duplicate review. Real-account Link now succeeds. Duplicate matches use a dedicated selection sheet that shows source, account classification, and balance so repeated names remain distinguishable; choosing a duplicate no longer silently selects the first candidate. A Plaid account matched to a manual investment asset supplies that asset's live current value across Accounts, Investments, Net Worth, and daily snapshots without modifying the durable manual entries. Multiple Plaid accounts may replace one aggregate manual asset, and the stored manual value is the safe fallback if any matched balance becomes unavailable. Successful Plaid syncs now persist one private-CloudKit balance point per contributing account per day. Investment history uses manual values before the first Plaid point, sums multiple matched accounts while linked, and writes inactive end markers so excluding or unlinking an account preserves prior Plaid history while returning current and future days to the manual value. Connected manual-asset detail pages merge those daily Plaid observations into the preserved manual history and mark Plaid rows with the connection symbol. Only reviewed USD balances contribute; holdings remain explanatory detail. The backend bearer token is entered once and stored in iCloud Keychain. The Link session is retained until success or exit, and backend requests time out after 20 seconds so the connection sheet cannot remain stuck indefinitely. The 87-test `NetworthCore` suite passes; simulator validation is intentionally excluded.

`PlaidWorker/` is deployed with the Transactions and privacy-bounded Claude endpoints at `networth-plaid.bluelava.me`; the Claude secret is configured outside git. Exact Plaid Transactions Production pricing remains account-specific, and Plaid documents it as a per-Item subscription. The checked-in backend never invokes the separately billed Refresh or Recurring add-ons.

The optional Claude.ai data connector is implemented separately from transaction
inference. After explicit consent, the app uploads full-replacement financial
snapshots that exclude credentials, provider IDs, account numbers, raw bank
descriptions, unreviewed transactions, and the local IBR document. The Worker
encrypts the snapshot, exposes five read-only MCP tools through OAuth 2.1 with
PKCE, and revokes every grant when access is disabled. Worker deployment and
unauthenticated production smoke checks are complete; authenticated iPhone and
Claude.ai verification remains a manual follow-up.

**The current working tree completes the Projections rebuild around cash confidence.** The screen combines a conservative headline, one projected-cash curve, and a chronological event timeline. Each card has a close day, autopay day, and funding account; full-statement payments are simulated across the configured horizon and feed the same cash ledger as scheduled income, bills, and transfers. The chart shows total selected cash after known commitments and the spending reserve, while a separate known-commitment ledger validates that each actual payment account has enough money on the required date.

The main projection also includes a horizon cash-flow bridge: starting cash plus known income and transfers in, less scheduled outflows, card payments, and the unscheduled spending reserve, reconciled to projected ending cash.

Safe to Spend closes the primary decision loop: it reports additional spending capacity now through the lowest point found across the full selected projection horizon. The calculation takes that lowest expected cash balance and subtracts the configured minimum buffer, so ordinary spending, scheduled obligations, and card payments are already reserved. The card names the low-point date as the actionable window and withholds the figure when card setup or spending history is incomplete.
The card opens a detail sheet whose bridge is computed by `CashPositionProjector` from the same low point: starting cash, inflows, scheduled outflows, card payments, expected ordinary spending, projected low, buffer, and Safe to Spend. It also lists each dated event included through the low point.
With four or more complete monthly samples, the projector also computes a higher-spending case from the 75th-percentile month. Only the unscheduled daily reserve changes; dated scheduled obligations remain exact. The card shows the resulting downside Safe to Spend amount without adding another chart curve.

Projection Details exposes every complete monthly spending sample used by the median. Each month drills into total, scheduled, and unscheduled amounts plus included category totals; excluded categories are listed alongside the method assumptions.

Monthly category details list their contributing transactions. A swipe excludes or restores one transaction (or one split leg) from the spending baseline. `DurableExcludedSpendTransaction` stores that user decision in the CloudKit durable tier; the Spending Exclusions screen provides a permanent restore path. The schema change is additive with defaulted fields, so existing CloudKit rows remain compatible and no legacy field cleanup is required.

The Net Worth tab is now organized as a long-term scorecard. Its hero reconciles current net worth to total assets and liabilities and reports the 30-day movement. The existing scrub-enabled historical chart and diagnostic sheet remain intact. A Balance Sheet provides tappable asset and liability categories; after cutover, cash/cards use Plaid while retained loan/manual/investment sources continue to contribute.

The Accounts tab is the detailed inventory behind Net Worth. Before cutover it shows YNAB accounts; afterward cash/cards use normalized Plaid balances and reviewed activity while legacy loans remain available. Liability balances display as positive amounts owed. Manual assets navigate to their durable value history.

The Investments tab is now a portfolio report instead of a static list. It reconciles investment-typed YNAB accounts with manual brokerage, retirement, and crypto values; reports the total and 30-day movement; provides a scrub-enabled 3-month through 5-year balance trend; and shows allocation by source/type plus holding-level percentages. YNAB holding details include cleared/pending balances, a one-year balance trend, and recent activity. Manual holdings reuse the durable value-history and Update Value workflow. `InvestmentHistoryBuilder` reconstructs YNAB balances and carries each dated manual valuation forward. Generic Other assets are intentionally excluded from Investments. No persistence schema changed.

The primary UI has had a density pass. Net Worth and Investments no longer repeat their navigation titles inside hero cards; low-value counts, single-series legends, duplicate status badges, repeated update labels, and category item counts were removed. Projection chart metadata is one line, Safe to Spend copy is shorter without dropping ordinary-spending and buffer assumptions, and configuration/diagnostic explanations were reduced to concise footnotes. Detailed methodology remains behind the existing info and detail surfaces.

BL IBR can now publish an opt-in student-loan summary through the local App Group `group.com.bluelava.me.financial`. Networth refreshes that read-only document at bootstrap and foreground activation, includes the current balance in Loans and total liabilities, exposes repayment details in Accounts, and deep-links back to IBR. IBR's dated balances are overlaid locally on the Net Worth trend. By default, linked-loan history begins on the earliest cached YNAB transaction date; Accounts → Student Loans provides `Count Loan Starting` only as an override. Date edits stay local until `Apply Start Date`, avoiding repeated five-year chart recalculation while the picker changes. Before IBR's first dated balance, Networth estimates backward using $0 payments and IBR's shared weighted rate as simple daily interest on principal. Accrued interest is floored at zero and capitalization is not inferred. The shared balance, rate, and override are deliberately excluded from `DurableNetWorthSnapshot`, so no IBR loan field, override, or derived balance is copied to CloudKit. The selected banking transaction source remains the cash-flow evidence for loan payments; Networth does not generate another projected payment from IBR metadata.

- `Networth.xcodeproj` is the source of truth. Add new files via Xcode's UI.
- The user confirmed the latest app and copy/layout cleanup run correctly on-device.
- NetworthCore SPM package: 5 sub-modules plus an umbrella target.
- App-target unit tests: 42 Swift Testing tests under `xcodebuild test`.

## What ships
- Single ModelContainer with two ModelConfigurations:
  - `NetworthLocalCache` (no CloudKit) — retained YNAB cache rows plus Plaid investment rows, normalized banking accounts/transactions, transaction cursors, and historical match evidence.
  - `NetworthDurable` (CloudKit private DB) — manual assets, aggregate snapshots, daily `DurablePlaidBalanceSnapshot` history, user/projection settings, account reconciliation decisions, editable canonical contacts/categories, aliases, and transaction-specific decisions.
- `AppContainerController` (`@Observable`, `@MainActor`) owns the YNAB and private-backend Plaid clients, their independent sync coordinators, security/persistence services, and the local IBR boundaries.
- Every IO boundary is protocol-based with a production and in-memory/scriptable/recorded fake.
- `Nw*` design system: tokens (spacing, corner radius, typography, colors, shadow, opacity, stroke, icons) + components (card, section header, metric capsule, status badge, empty/loading state, inline notice, banner, modal layout, button styles, amount text).
- 4 tabs: **Net Worth · Projections · Accounts · Investments**. Settings opens from a sheet behind the Net Worth toolbar.
- Investments combines YNAB investment accounts, manual brokerage/retirement/crypto assets, and approved Plaid investment balances. Plaid account details reconcile account balances to security-level holdings and cost basis without double-counting holdings.
- Net Worth is the default launch tab. Projections remains the daily cash-confidence tool and shows selected cash today, the lowest projected balance and date, the event that causes it, a user-set minimum buffer, and derivation details for assumptions and card payments.
- Optional IBR linking is local-only and read-only. The current IBR balance contributes to liabilities; dated IBR balances and the local history-start estimate overlay the chart without entering the CloudKit snapshot store.
- Before cutover, Known Commitments uses dated YNAB scheduled activity plus generated full-statement card autopays. After cutover, recurring/scheduled prediction is intentionally deferred: projections use Plaid transaction history for ordinary-spending estimates and retain the explicit card statement/autopay settings, but do not pretend Plaid's historical feed contains future bills.
- Aggregate cash establishes overall capacity, but does not mask account liquidity. Internal scheduled transfers update both account paths without changing the total; when an account runs short despite sufficient total cash, the headline gives the minimum transfer and deadline.
- Aggregate shortfall headlines report the first day projected cash turns negative; the lowest balance across the full horizon remains supporting context rather than replacing the actionable crossing date.
- Card-cycle timing treats an ambiguous later-numbered due day fewer than 14 days after close as belonging to the following monthly cycle. Prior statement autopays are netted from a following statement estimate even when that payment lands just after the next close, preventing duplicate same-day autopays.
- Cards whose configured payment account is excluded from the selected cash pool are called out as incomplete coverage instead of disappearing from the projection.
- Open on-budget cash accounts default into the outlook. CloudKit-backed account overrides let the user exclude reserves or include off-budget cash explicitly.
- Read-only YNAB v1 client (delta-sync aware via `last_knowledge_of_server`), Keychain-stored PAT with iCloud sync, Face ID gate on by default when biometrics are available.
- `safeSave(source:)` posts a notification on failure; container surfaces an alert.

## Historical net-worth backfill
- `SyncCoordinator.runHistoryBackfillIfNeeded(budgetId:)` runs at the end of `syncAll` and reconstructs up to 5 years (60 months) of daily snapshots from cached YNAB transactions via `NetworthCore.AccountHistoryReconstructor` + `NetWorthHistoryAggregator`.
- Gated by `DurableUserSettings.historyBackfillVersion` (default `0`, flipped to `1` after a successful run). The marker lives in the CloudKit-backed durable store so a device reinstall or iCloud restore doesn't re-trigger it.
- Reconstructed rows are stamped `source = .backfill` (manual assets aren't included — their history doesn't extend that far back). When a `.backfill` row collides with a `.live` row from `SnapshotScheduler.recordIfNeeded`, the dedupe pass keeps `.live` so manual-asset totals are preserved.
- `AppContainerController.forceFullResync()` clears all `SyncCursor` rows AND resets `historyBackfillVersion = 0`, so the next sync redoes the full 5-year fetch and reconstruction.

## Build & Test
```bash
# Pure-Swift domain tests (fastest):
cd NetworthCore && swift test

# App target builds (generic iPhone; do not launch a simulator):
xcodebuild -project Networth.xcodeproj -scheme Networth \
  -configuration Debug -destination 'generic/platform=iOS' build

xcodebuild -project Networth.xcodeproj -scheme Networth \
  -configuration Release -destination 'generic/platform=iOS' build

# Worker tests and type checking:
cd PlaidWorker && npm test && npm run check
```

## Known follow-ups
- **CloudKit cross-device verification:** not needed for the user's current single-device workflow.
- **TestFlight CloudKit schema:** before a TestFlight build, initialize and deploy the additive canonical account/payee/alias/category/transaction-decision record types and the new defaulted/optional `DurableUserSettings` fields. Keep the legacy merchant-rule, custom-category, and override record types for migration compatibility. The exact checklist lives in `docs/2026-07-25-plaid-transactions-migration.md`.
- **Claude.ai connector verification:** on iPhone, enable access and confirm the first snapshot sync; connect Claude.ai with a fresh app code; exercise all five read-only tools; then disable access and verify the connector is revoked.
- **Numeric-first-tap-replaces-value:** the documented input pattern is stubbed in `ManualAssetForm.selectAllOnFirstTap()` — wire a UITextField responder coordinator if/when that polish is desired.
- **Historical transfers from excluded closed accounts — deferred:** the 5-year reconstructor walks open accounts plus user-selected closed accounts. If a closed account remains excluded, its transfer into an included account is still rolled back as if it were external activity, which can understate earlier net worth. Including that closed account mitigates the issue. The user chose to ignore this edge case for now.

## Recently shipped (2026-06-07)
- **PAT input cleanup:** `AppContainerController.saveYNABToken` trims whitespace/newlines before storing. `PATEntrySheet` confirm-disabled state uses the trimmed value.
- **Form save-failure handling:** `ManualAssetForm` and `CardSettingsForm` consume `safeSave`'s `Bool` return, keep the sheet open on failure, surface an inline error, and roll back the in-memory mutation so retries are clean. Manual asset skips the follow-up snapshot if its save failed.
- **Sync save-failure handling:** `SyncCoordinator.syncAll` bails to `.error` if cache or durable save fails. `runHistoryBackfillIfNeeded` returns `Bool`; failed snapshot or marker saves leave `historyBackfillVersion = 0` and cause `syncAll` to report sync failure instead of `.idle`.
- **Rate-limit throttling:** `LiveYNABClient` proactively refuses requests when within 5 of YNAB's 200/hr limit. A 60-second cooldown on the throttle lets a probe through after the rolling window has had time to recover, preventing permanent lockout from a single near-limit observation.
- **Overlap guards:** `SyncCoordinator.syncAll` no-ops if a sync is already in flight. `AppContainerController.forceFullResync` refuses to wipe state when a sync is running.
