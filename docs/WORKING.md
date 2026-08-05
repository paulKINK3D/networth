# WORKING

## Current State (2026-08-04 — Phase 1 step 1 implemented, uncommitted)

Canonical plan: `docs/2026-08-03-plaid-first-spending-history-plan.md`
(supersedes the 2026-08-02 goals/budget plan, which is deferred to Phase 2).
Implementation order: (1) clean reset + Plaid-first foundation, (2) YNAB
reference table + type-first review, (3) Spending History screen,
(4) recurring expectations in Cash Projections.

### Step 1 — done this session (working tree, branch feature/budget-phase-1)

**Versioned destructive clean start** — `Networth/Persistence/FreshStart.swift`
(new file, registered in pbxproj):
- Runs first in `AppContainerController.bootstrap()`, before the Claude data
  sync coordinator starts observing saves.
- Deletes every row of every model type in both stores (cache + CloudKit
  durable), verifies both stores empty, then creates one fresh
  `DurableUserSettings` row with Plaid-first defaults
  (`primaryFinancialDataSource = .plaid`, `plaidTransactionsEnabled = true`,
  current schema/backfill/canonical version stamps) and
  `freshStartVersion = 1` as the completion marker. Two-save sequence makes
  interruption re-run the wipe on next launch.
- Once complete, every later bootstrap purges resurrected legacy rows:
  retired budget/fund model types (`DurableSinkingFund`, `DurableFundEvent`,
  `DurableFixedCommitment`, `DurableBudgetCategoryAssignment`,
  `DurableIncomePatternOverride`) and settings rows with a stale
  freshStartVersion.
- Keychain untouched: YNAB PAT retained solely for future explicit reference
  imports (step 2). Plaid Worker Items and IBR App Group doc untouched.

**Plaid authoritative / YNAB severed**:
- `syncNow()` no longer contacts YNAB at all; Plaid investments +
  transactions only. Successful Plaid sync stamps `settings.lastSyncedAt`
  (staleness throttle) and one-time `firstPlaidSyncCompletedAt`.
- `refreshIfStale` guards on the Plaid backend token only.
- `forceFullResync` now wipes Plaid transaction cursors (full re-import) and
  NEVER deletes snapshots — history is never reconstructed post-clean-start.
- `rebuildChartHistory()` removed; manual-asset edits just record today's
  snapshot. Reset Chart History sheet removed from Settings and unregistered
  from the build (`ResetChartHistorySheet.swift` left on disk — delete from
  Xcode when convenient).
- Sync phase UI (Net Worth toolbar, Projections notice, Settings) now reads
  the Plaid transaction coordinator. Net Worth connection banner is
  Plaid-only (no YNAB fallback).
- YNAB cutover machinery (`makePlaidPrimary`) is now unreachable (fresh
  settings are already Plaid-primary); AccountsView section self-hides.
  Step 2 will rework reconciliation UI for reference imports.

**First snapshot gating**: `SnapshotScheduler.recordIfNeeded` records nothing
until `firstPlaidSyncCompletedAt` is set — day one of the new Net Worth
history is the first successful Plaid sync (per plan; manual assets entered
earlier don't snapshot early).

**Data foundation models**:
- `DurableCategoryGroup` (durable): stable `groupIdentity`, name,
  displayOrder, chartColorHex, `reportingRole`
  (spending/income/investment/transfer — new `CategoryReportingRole` enum in
  NetworthCore).
- Additive `categoryGroupIdentity: String?` on `DurableCanonicalCategory` and
  `DurableTransactionCategory`.
- `PlaidAccountCoverage` (cache): per-plaid-account earliest/latest imported
  transaction dates (+ reserved gapsData), maintained inside the transaction
  sync page loop. Coverage is per-account, never a global window.
- New settings fields: `freshStartVersion`, `firstPlaidSyncCompletedAt`
  (both merged in `dedupeSettingsRows`).

**Tests**: NetworthCore 138/138 pass. App Debug + Release generic-device
builds pass; test bundle compiles (build-for-testing). AppContainerTests
updated: new clean-start tests (wipe + defaults + token preservation;
idempotence + legacy purge), YNAB-never-contacted test, snapshot gating
test, backfill-never-runs test; retired the four YNAB backfill tests and the
cutover test; pre-bootstrap seeding moved after bootstrap where needed.
NetworthTests not RUN (simulator disallowed) — run in Xcode when convenient.

### Codex review (done) — findings fixed same session
- Clean start now commits wipe + fresh settings + marker in ONE atomic save
  (failure rolls back to legacy state, retried next launch). Separate
  per-device UserDefaults marker (`networth.freshStartLocalCacheWipeVersion`)
  wipes the device-local cache store even when the CloudKit durable marker
  arrived from another device; durable rows are never re-wiped once the
  marker is visible.
- PlaidTransactionSyncCoordinator.syncAll can retry from `.error` (was
  bricked until relaunch after one failure).
- Sync markers (`lastSyncedAt`, `firstPlaidSyncCompletedAt`) stamp only on a
  fully successful pass; investments-only paths no longer stamp them.
- `PlaidAccountCoverage` cleared by forceFullResync (widen-only rows can't
  narrow otherwise) and by Plaid item removal (no orphan coverage).
- Item removal now syncs both Plaid paths before recording the snapshot.
- Tests added: multi-device cache wipe, resync clears cursors/coverage but
  never snapshots, YNAB-severed test now seeds a Plaid token.
- Known residuals (accepted): a device racing ahead of CloudKit marker
  delivery re-runs the full wipe (safe for legacy rows; ordering caveat if it
  received another device's fresh rows first); resurrected rows of still-live
  durable types are indistinguishable from fresh data; no save-failure
  injection tests (no failing-store fake exists).

### Open items
- NetworthTests compile but were not RUN (simulator disallowed) — run in
  Xcode when convenient.
- BudgetView still reads now-empty legacy models until step 3 replaces it
  with Spending History (expected interim state).
- Step 2 next: account-scoped YNAB reference table, type-first review flow.
