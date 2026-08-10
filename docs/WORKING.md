# WORKING

## Stabilization checkpoint (2026-08-09)

- `ux-cleanup` contains focused commits for retired Fresh Start removal,
  atomic category deletion, YNAB reference-only categories, type-driven
  Spending, simplified groups, explicit goal transaction types, direct goal
  allocations, and removal of the fixed category taxonomy.
- The pending goal-transfer slice is intentionally confirm-first. A Goal
  Spend/Refund made through a cashflow account creates a durable reminder,
  adjusts the pool until the real account balances catch up, lets the user
  choose both accounts later, and clears only after an exact Plaid candidate
  is explicitly confirmed. The Goals tab does not rescan transaction history
  when opened; requests are updated with the reviewed transaction mutation.
- Manual device checks passed for Goal Spend, Goal Refund, split attribution,
  transfer-account selection persistence, explicit match confirmation,
  projection exclusion, card-autopay uniqueness, and Net Worth reconciliation.
- A one-time local repair converts only the legacy positive Refund shape that
  used the synthetic `Reimbursement` label without a category identity. It
  updates cached transactions, canonical decisions, and legacy overrides;
  preserves real category refunds and undecodable split payloads; and records
  a disposable local marker so the full scan does not repeat every launch.
- Known correctness work still open:
  - Standalone Plaid investment accounts contribute to Net Worth but are not
    rendered by All Accounts.
  - The Investments screen presents Plaid IRAs as brokerage accounts even
    though Net Worth classifies their balances as retirement.
  - Independently rounded Spending group rows can differ by one dollar from
    the rounded monthly headline.
- Known UX work still open:
  - Goal allocation editing needs a deliberate redesign. The committed staged
    sheet remains temporarily; the rejected per-goal Add/Remove experiment was
    not retained.
  - Spending group rename/edit controls need native list-row management.
  - Investment reconciliation controls should not appear for ordinary banking
    accounts where they do not control banking or Goals behavior.
- A connected Cash Plus account temporarily lacked a usable live balance until
  Plaid reconnect completed. The exact stale-cache/recovery cause remains open.
- Checkpoint validation: NetworthCore 211/211; generic-device Debug and Release
  builds pass; the app test bundle compiles with `build-for-testing`. App tests
  were not run because simulator execution was not requested.
- `Networth/Features/Projections/ProjectionsView.swift` contains an unrelated
  user-owned worktree change and must remain outside stabilization commits.

## Goals overhaul (2026-08-09)

- Goal accounts are explicitly selected eligible asset accounts. Debt and
  retirement accounts are excluded; selected cash, checking, savings, and
  non-retirement investment balances form the pool and remain excluded from
  the Projections cash pool while selected.
- The allocation sheet stages every goal amount and commits all changes in one
  save. One optional goal receives the live remainder after all fixed
  allocations, so account growth automatically flows to it.
- Goal creation exposes only a name and optional amount/date target. The old
  kind, monthly-plan, emergency-formula, Add Money, Withdraw, Record Purchase,
  and Ledger UI is retired.
- Goal Spend and Goal Refund are explicit transaction/split-leg types with an
  explicitly selected active goal. They affect goal balances directly and are
  excluded from monthly Spending and Projections.
- The legacy synthetic Goal Purchases report path is removed. Historical
  allocation rows remain readable as the backing representation for current
  fixed allocations, but they are not exposed as a user timeline.
- Initial validation: NetworthCore tests plus generic-device Debug
  build-for-testing and Release build. The later on-device interaction findings
  and remaining work are recorded in the stabilization checkpoint above.

## Paycheck detection in Cash Projections (2026-08-06)

- `IncomeAnalyzer.detectPaycheck(confirmedTransactions:selectedAccountIds:
  asOf:calendar:)` is the Plaid-first entry point: groups confirmed `.income`
  transactions (split legs included) by canonical payee or folded name,
  merges same-day deposits per payday while keeping per-account amount
  breakdowns, judges payers on trailing-15-month totals, and reuses the
  existing private cadence classifier and phase detector.
- Review round (same session) hardened five correctness gaps:
  - **Freshness limit**: ≥2 expected paydays passed without a confirmed
    deposit → `.staleHistory(payee, lastDepositDate)`; income stops
    projecting instead of extrapolating a dead pattern. One missed payday is
    tolerated as review lag.
  - **Exact dated events**: `DetectedPaycheck.scheduledSummaries(asOf:
    horizonDays:)` emits one `.never`-frequency summary per expected payday
    via `IncomePattern.expectedPaycheckDates` (payday-of-month clamping —
    no monthly/semimonthly drift; detected daysOfMonth are used).
  - **Phase-priced amounts**: each payday priced by
    `IncomePattern.expectedPerPaycheckAmount` (phases from pool-scoped
    deposit amounts; no unobserved step-ups, bonuses can't leak in).
  - **Pool scoping**: deposits landing only outside the selected cash pool →
    `.depositsExcluded(payee)` warning instead of silently-dropped inflows;
    split paydays project only the in-pool portion.
  - **Per-account portions** (second review round): each selected account's
    share projects as its own dated inflow from its own deposit series
    (`PaycheckPortion`) — a checking/savings split can never overstate the
    account that pays the bills. Event ids carry the account suffix.
  - **Bonus resistance** (second review round): per-portion amounts are the
    month's phase price capped by `confirmedRecurringAmount` — the newest
    run of ≥2 matching deposits (2.5% tolerance). A single higher deposit
    (trailing bonus, unconfirmed raise) never raises the forecast until it
    repeats; a single lower deposit adopts immediately.
  - **nextDate = first generated event** (derived from the same payday
    enumeration), so Projection Details never advertises a date the
    timeline doesn't contain.
- `PaycheckDetection` cases: `.detected`, `.staleHistory`,
  `.depositsExcluded`, `.insufficientHistory` (<4 recent deposits),
  `.unstableCadence`, `.noConfirmedIncome` — every failure reason drives a
  specific UI warning.
- Manual recurring income overrides detection per payer:
  `IncomeAnalyzer.manualIncomeOverride(for:expectations:)` matches canonical
  payee id when both sides have one, else case/diacritic-insensitive name.
  A manual entry for a different payer coexists with the detected paycheck.
- ProjectionsDataActor (Plaid path only): runs detection on the projection
  history with the selected cash-account ids, appends the dated summaries
  unless overridden, passes `paycheckDetection` + override payee +
  `hasManualIncome` through ProjectionData. Detected ids join the
  estimate-exempt set automatically (computed after the append).
- UI: Projection Details Income section (payer, cadence, next paycheck
  amount, next deposit date, confirmed-deposit count — or the specific
  warning); "Income not projected" priority notice when the projection has
  no future paychecks and no manual income, after shortfall warnings. Stale
  "Schedule paychecks and bills in YNAB" copy replaced in the timeline empty
  state and tutorial step 4.
- Projection Details lists per-account portion amounts when a paycheck
  splits across more than one pool account.
- Off-cycle hardening (third review round):
  - `onCycleOccurrences` drops deposits off the payday grid before anchor/
    dates/phases/portions form: interval cadences require a day gap within
    ±2 of a whole step multiple to a neighbor (holiday shifts survive);
    day-of-month cadences require the clamped day within ±3 of a detected
    payday-of-month. An off-cycle bonus can no longer shift the anchor or
    enter the series; detection re-classifies from the cleaned dates and
    needs ≥4 on-cycle deposits.
  - A portion requires deposits on ≥2 paydays — a one-time bonus into a new
    account (even on a regular payday) never becomes a recurring inflow.
  - Freshness counts missed paydays via the same clamped
    `expectedPaycheckDates` enumeration the events use — a 31st payday is
    checked at its real clamped date, so month-end stepping drift cannot
    miscount (verified: May 30 with an Apr 30-clamped anchor reports zero
    missed and projects May 31).
  - Known residual: multiple off-cycle bonuses landing on several distinct
    days of month within the window can still confuse semimonthly
    stable-days detection (falls back to biweekly); single bonuses are
    handled.
- Validation: NetworthCore 189/189 (22 paycheck tests incl. off-cycle
  bonus anchor, new-account bonus portion, month-end freshness clamp);
  generic-device Debug + Release builds pass.

## Phase 2 — Spending groups (2026-08-05)

- Spending remains the screen/tab name and now answers where money went:
  ordinary category spending plus net Savings and net Investment allocations.
  Credit-card payments and checking-to-checking counterparts stay excluded to
  prevent double-counting.
- Spending groups are entirely user-defined. Networth seeds no destination
  names, and YNAB group identities remain reference metadata only: they never
  become Spending columns or cleanup work.
- Spending toolbar → group manager starts with `Create Group`, lists only the
  user's Networth groups, and exposes visible rename/hide controls plus Edit
  ordering. `Unassigned Categories` is the explicit inbox for categories that
  do not yet belong to one of those groups. Both assigned and unassigned lists
  show only categories referenced by stored transactions. Select mode supports
  circular checkmarks and a batch `Add to Group` menu.
- `Savings Transfers` and `Investment Contributions` are Networth-owned
  automatic categories in that same inbox. The user assigns them to any group;
  Networth calculates their amounts without exposing reporting-role controls.
- Savings counts only the savings-account side of confirmed internal transfers:
  deposits add, withdrawals offset. Investment counts only the cash-account
  side of confirmed investment contributions: contributions add, withdrawals
  offset. Projection treatment remains unchanged.
- Zero-activity groups remain visible so the selected-month columns stay stable.
- Month navigation no longer uses blue arrow buttons. A horizontal swipe on
  the Spent card moves between months (right = previous, left = next), with
  equivalent VoiceOver accessibility actions. Tapping the Spent card selects
  All Spending history. The month header no longer repeats "Month to date."
- The 24-month history is a single monthly column series. Tapping a selected-
  month group column chooses that group's history; the group name becomes the
  chart label. The current partial month uses a lighter bar without an MTD
  label. There is no picker, trend line, or point layer. A chart tap selects
  that month and, for group series, opens its category detail. The chart is
  horizontally scrollable with roughly eight wider month bars visible at once,
  so its 24-month drill-down targets remain practical on iPhone. Month taps use
  the chart's native spatial-tap gesture rather than a transparent overlay, so
  the overlay cannot intercept horizontal scrolling.
- Group detail navigates category → transaction list → the existing full
  transaction editor. Transaction rows reuse `NwTransactionRow`; split rows
  retain the selected category leg amount while the detail screen shows the
  complete parent transaction, classification, account, and split information.
- `DurableUserSettings.spendingGroupSetupVersion` is an additive, defaulted
  CloudKit field. Legacy/restored rows hydrate at 0; version 3 retires untouched
  seeded defaults and preserves renamed groups. After a completed Plaid sync
  with no posted reviews remaining, version 4 deletes canonical categories with
  no transaction, split, durable decision, or recurring-expectation reference.
  Automatic allocation categories are created only when matching transactions
  exist.
- Validation: NetworthCore 162/162; generic-device Debug + Release builds and
  the app test bundle compile.

Remaining candidate: preserve YNAB memos in reference suggestions (transfers
are easier to identify with them).

## Current State (2026-08-04 — Phase 1 COMPLETE; all four steps committed)

Commits: 79fa7b2 (step 1) · 18ea60d (step 2) · 8da7e06 (step 3) ·
78f16b1 (step 4), all on feature/budget-phase-1, pushed. Cleanup done
2026-08-06: BudgetView.swift and ResetChartHistorySheet.swift deleted, dead
DiscretionaryBudgetSettingsSheet struct removed from SettingsView.swift.

### Step 4 — Recurring expectations in Cash Projections (this session)

- `NetworthCore/Projections/RecurringExpectations.swift`:
  `RecurringExpectation` (account, optional destination, payee, treatment ∈
  {ordinarySpending, income, internalTransfer, investmentContribution},
  cadence, next occurrence, signed user-entered amount).
  `toScheduledSummary()` compiles an expectation into the existing
  scheduled-summary pipeline: cash bills → dated outflows; income → dated
  inflows; expected card purchases (bill on a card account) raise that
  card's projected statement via CCPaymentForecaster (only the generated
  autopay reaches the pool); pool-internal transfers net out via existing
  buildScheduledEvents logic; investment contributions are pool outflows
  while staying outside spending. Card payments are never expectations.
- Exactly-once: the projector's existing scheduled-outflow subtraction
  removes matched history from the ordinary-spend estimate for
  ordinary-spending expectations; NEW `estimateExemptScheduledIds`
  parameter on `CashPositionProjector.project` keeps transfers/investment
  expectations (whose actuals never enter projection history) out of the
  subtraction so they are dated events only.
- Matching: account is routing for the next payment, not identity. Matching
  uses payee canonical-id-or-name, category corroboration, treatment,
  direction, and a cadence-specific date window across accounts. Historical
  estimate removal reconstructs expected dates backward and claims at most
  one closest actual per occurrence; amount then account only break ties, so
  changing the payment account neither double-counts a bill nor excludes all
  activity from the same merchant.
  `advanceRecurringExpectations(for:)` runs inside all three confirm paths
  (single, split, batch): an approved matching transaction replaces the
  occurrence and advances the cadence; otherwise only explicit Skip
  (swipe) or reschedule (edit) advances. `advance` handles all six
  CommitmentCadence cases with month-end clamping.
- `DurableRecurringExpectation` (durable store, CloudKit-safe, `toCore()`),
  registered in ModelContainerFactory + FreshStart wipe/emptiness lists.
- ProjectionsDataActor fetches active expectations → summaries feed both
  `upcomingPayments` (card purchases) and `project(scheduled:)`; exempt
  ids for non-ordinary treatments. YNAB schedules remain dead.
- UI: Settings → Projections page "Recurring" section (add, edit sheet,
  swipe Delete = archive, swipe Skip Next); `RecurringExpectationForm`
  (canonical payee and optional category pickers, type, account [cards
  allowed for bills], destination for transfers, cadence, next date, amount;
  "start from a recent transaction" prefill). Events surface in the existing
  Projections timeline rows automatically.
- Tests: 13 recurring tests. NetworthCore 189/189; generic-device Debug +
  Release builds.

- Device-data projection correction (2026-08-06): monthly recurring matches
  allow up to 14 days of posting drift, require the actual to be at least 50%
  of the expected amount, and rank amount proximity before date proximity.
  This matches all 12 observed $1,995 loan payments to the $2,040 expectation
  while rejecting the same-payee $5 fee. Matched recurring actuals now remain
  visible in observed/monthly totals and are labeled as removed from the
  everyday reserve; Projection Details reports that overlap instead of $0.
- Refund correction (2026-08-06): the everyday projection now nets approved
  `.refund` transactions in their posted month instead of forecasting gross
  charges forever. Projection Details reports the refund total, and monthly
  transaction drill-downs show the offset. Live-device replay moved the
  everyday median from $9,002.08 to $7,917.84 before installation.
- [ ] Required projection-audit CSV export: add a user-initiated local export
  from Projection Details with one row for every source transaction/split leg
  considered (including excluded rows), its stored treatment, signed amount,
  projection bucket, inclusion/exclusion reason, recurring match, and monthly
  sample. Include all dated forecast events, running balances, calculation
  settings, and reconciliation rows for every displayed total so the math can
  be reproduced independently. Keep stored facts separate from computed labels;
  never infer semantics such as reimbursement from payee/category. Exclude
  credentials and raw provider/account identifiers.

### Step-4 Codex review — 2 blockers + 5 majors, all fixed same session
- BLOCKER redesign: exactly-once is now ID-BASED. Every expectation summary
  is estimate-exempt (the theoretical backward-occurrence subtraction never
  runs for expectations — a new bill can no longer invent past occurrences
  that erase unrelated spending), and `matchedHistoricalIds` (authoritative)
  excludes matched actuals at their REAL amounts from the estimate via
  `excludedTransactionIds` (incl. split leg ids) and from the card
  variable-charge history fed to `upcomingPayments`.
- BLOCKER: card statement settings now configure Plaid cards —
  `CardSettingsTarget` (canonical vs legacy), CardSettingsForm reworked
  (payment accounts from CachedFinancialAccount on the canonical path;
  canonical ids persisted directly), Settings section lists Plaid cards
  post-cutover.
- Semimonthly = paired days of month via shared `SemimonthlyMath` (used by
  both `advance` and the ScheduleFrequency walker) — no drift; 24 steps
  from Jan 1 land exactly on next Jan 1.
- Advancement: rows processed chronologically; one approval advances at
  most ONE expectation (`bestOccurrenceMatch` by date then amount);
  cadence-capped match windows (weekly 3d, biweekly/semimonthly 6d, else
  7d) prevent re-confirm double-advance; category disambiguates same-payee
  expectations when both sides carry canonical categories.
- Form: preserves payee/category canonical ids from prefill (with
  programmatic-change guard on the name field); next date defaults to
  tomorrow (projection events start tomorrow); type change clears an
  incompatible account; canSave validates account against the type's
  allowed list; transfer destinations exclude cards; swipe archive/skip
  revert on failed save. Legacy YNAB schedules removed from BOTH paths.
- New tests: semimonthly no-drift, exactly-once with differing
  actual/expected amounts (real amounts removed, groceries reserve
  preserved), new-expectation-no-history estimate invariance, income dated
  inflow invariance.

### Step 3 — Spending History screen (this session)

- `NetworthCore/Models/SpendingHistory.swift`: `SpendingHistoryBuilder`
  aggregates approved entries into exactly-N months (oldest first, zero-
  filled): negative ordinary = spending, positive refunds offset within the
  category, income/transfers/card payments/investment contributions/
  exclusions never counted; timezone-safe month bucketing via supplied
  calendar; current month is MTD. 5 new tests (146 total pass).
- `Networth/Features/Spending/SpendingHistoryView.swift` (new group
  Features/Spending, registered in pbxproj) replaces BudgetView as the
  Spending tab: review card (grouped + one-by-one), swipeable month total,
  selectable per-group columns, and a 24-month monthly column chart (Swift
  Charts) with tap-to-group drill-down,
  `SpendingGroupDetailSheet` (categories → transactions → full editor).
  Off-main aggregation via `SpendingHistoryBuildActor` (@ModelActor) with
  0.6s-debounced save-notification rebuilds.
- Chart palette: `NwAppColors.chartCategorical` — 8 fixed dynamic
  light/dark colors validated with the dataviz palette validator (CVD ≥28ΔE
  adjacent; dark contrast ≥3:1; light-mode relief = labeled group rows).
  Hues assigned by group displayOrder, follow the entity, never re-cycled;
  9th+ group folds into `chartOther` ("Other") in the chart only.
- Retired: ContentView tab now SpendingHistoryView; BudgetView.swift
  unregistered from the build (file left on disk — delete from Xcode along
  with ResetChartHistorySheet.swift); Discretionary Budget settings row +
  sheet entry removed (dead `DiscretionaryBudgetSettingsSheet` struct still
  in SettingsView.swift pending deletion); header row now shows Projections
  horizon.
- Builds: Debug + Release + test bundle all pass.

### Step-3 Codex review — fixed same session
- Split legs now resolve canonical category via `categoryCanonicalId ??
  categoryId` (confirmed splits persist identity in categoryId) — was
  sending every confirmed split to "Other".
- Detail sheet shows the per-category leg amount for splits, never the
  parent total; category transaction lists dedupe shared parent ids.
- Builder enforces the strict sign matrix (negative ordinary counts;
  positive refund offsets; mismatched signs ignored).
- Chart uses explicit yStart/yEnd stack bounds so tap resolution walks the
  exact rendered order (no framework stacking-order assumption); "Other"
  detail merge matches the chart's positive-only fold.
- Build actor constructed inside Task.detached (aggregation off the UI
  executor); significant-time-change notification refreshes the window on
  month rollover; Settings .budget page retitled "Projections".
- 4 new builder tests (sign matrix, refund-over-spend, inclusive window
  boundaries, split dedupe) — NetworthCore 150/150.

### Step 2 — YNAB reference table + type-first review (this session)

- `ForecastTreatment.investmentContribution` added (outside spending, budget-
  skipped). `TransactionTypeRules` in NetworthCore is the type-first
  contract: which `CategoryReportingRole`s fit each type; transfers/card
  payments/exclusions take no category; ungrouped categories accepted
  leniently. Enforced in `confirmCanonicalTransaction` and the new batch
  `approveTransactions` — incompatible combos cannot save.
- `YNABReferenceSuggestion` (cache tier, wiped by FreshStart): matched
  Plaid/YNAB ids + suggested payee/category/treatment/split + confidence/
  score. Applied as the LOWEST layer inside `applyCanonicalDirectory`, so
  suggestions survive every sync, prefill unresolved rows, and never mark
  anything reviewed. User decisions and alias evidence always win.
- `YNABReferenceImportCoordinator` (`Services/YNABReferenceImport.swift`,
  registered in pbxproj): explicit "Build YNAB Reference" flow — budgets →
  seed canonical payees + `DurableCategoryGroup` rows (role heuristic:
  income/invest name → role, else spending) + categories with group refs →
  per reconciled binding fetch YNAB transactions scoped to that account's
  `PlaidAccountCoverage` window (+3d slack) → `HistoricalTransactionMatcher`
  → rebuild suggestion table. Raw YNAB rows are processed in memory and
  never persisted. Rebuildable; `.user` decisions untouched.
- Account mapping post-clean-start: `PlaidAccountMappingSheet` now live-
  fetches YNAB account options (`fetchAccountOptions`, in-memory only) when
  the YNAB cache is empty.
- Type-first editor: `PlaidTransactionReviewEditor` restructured — Type
  section first (picker + split toggle), then Contact, then Category (only
  when the type takes one; role-filtered groups via `visibleCategoryGroups`;
  type change clears an incompatible selection).
- Grouped review: `GroupedHistoricalReviewSheet` clusters unreviewed
  historical rows by suggested payee+category+type; per-cluster Approve
  calls `approveTransactions` (one `.user` decision per row, single save);
  drill-in edits go through the individual editor as training evidence.
- UI hooks: Settings YNAB section gains Build YNAB Reference + phase status
  + Review Imported History; AccountsView post-cutover nudge now offers
  grouped review first, one-by-one second.
- Tests: 3 NetworthCore rule tests (141 total pass) + 3 app tests (reference
  import end-to-end, batch approve, type/category rejection). Debug/Release
  + test bundle compile. App tests not RUN (no simulator from CLI — user
  runs ⌘U).

### Step-2 Codex review — fixed same session
- Import/sync mutual exclusion (shared main context): buildReference refuses
  to start during a Plaid sync; syncNow/forceFullResync refuse during an
  import; Settings disables Sync Now while importing.
- Suggestions apply only when alias evidence is EMPTY (conflicting evidence
  leaves the row unresolved); decision patterns clear stale split data.
- Split legs enforce the type/category role contract (coordinator + UI
  picker limited to spending-role groups).
- Re-import fills only a missing categoryGroupIdentity — never moves a
  category the user regrouped.
- Budget pick prefers most-recently-modified; YNAB fetch window gets −3d
  slack on the lower bound too.
- `.investmentContribution` excluded from toProjectionSummary (historical
  ordinary-spend estimate); dated modeling arrives in step 4.
- Category validated before payee creation (no orphan pending payee on
  rejected saves); cluster key uses a non-printable separator.
- Accepted deferrals: transfers/card payments don't yet store a destination
  account relationship (step 4's recurring model owns that); multi-budget
  users get the most-recent budget with no picker; test fakes don't record
  fetch arguments.

## Step 1 state (2026-08-04, committed 79fa7b2)

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
