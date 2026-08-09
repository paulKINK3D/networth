# WORKING

## Goals tab — full v1 implementation (2026-08-07)

Implements the plan agreed in-session (5 Codex review rounds, final sign-off
"ready to implement"). All work is uncommitted alongside the still-uncommitted
paycheck-detection changes below.

- **Domain (NetworthCore, 216/216 tests green)**: new `Models/Goals.swift` —
  `Goal`/`GoalKind`/`GoalTargetMode`, `GoalLedgerEntry` with 7 kinds
  (`manual, contribution, purchase, purchaseRefund, withdrawal,
  reallocationOut, reallocationIn`), `GoalMath` (balance, plan-sufficiency
  status bridging to `FundMath`, MTD contributions = positive
  manual+contribution only), `ReservePoolMath` (allocated = Σ max(balance,0)
  over active goals; canAllocate blocks during shortfall),
  `EmergencyFundMath` (median of complete months, months × reduction%,
  $100-rounding + ≥5%/≥$250 adoption hysteresis), `GoalPurchaseAdjuster`
  (per-transaction assignments, largest-leg-first + stable tie-break,
  adjustableAmount ceiling = negative ordinary entries only, synthetic
  Goal Purchases group `networth:goal-purchases`). New test suites:
  GoalReserve, EmergencyFundMath, GoalPurchaseAdjuster.
- **Report model** (`SpendingHistory.swift`): group totals carry
  `reportingRole` + `countsTowardHeadline` (Goal Purchases excluded from the
  Spent headline but visible as its own column, pinned last via the
  orderIndex Int.max fallback, "Other" fallback color so user hues never
  shift); months expose `ordinaryTotalMilliunits` (excludes
  transfer/investment roles and Goal Purchases — the emergency-median
  input); category totals carry `lineAmountsByTransactionId` (adjusted,
  raw-sign) consumed by drill-down `displayAmount`.
- **Shared pipeline** (`Services/SpendingEntryPipeline.swift`): assembly
  (no visibility) → ledger externalId→cached-row-id resolution (built from
  fetched rows, no format assumptions) → purchase/refund adjustment BEFORE
  hidden-group filtering → visibility. Consumed by both
  `SpendingHistoryBuildActor` (refactored to it) and `GoalsBuildActor`, so
  Spending display and the Goals emergency input are the same numbers.
  `remainingAdjustableAmount(row:)` is the purchase-marking ceiling.
- **Persistence**: four new CloudKit durable types — `DurableGoal`
  (targetMode fixed|emergencyMonths, emergencyMonths/reductionPercent,
  adoptedAt, archived, completedAt, timestamps), `DurableGoalLedgerEntry`,
  `DurableGoalReserveAccount` (snapshots name/institution/mask for
  disconnected display + user-confirmed re-attach), 
  `DurableGoalSuggestionDismissal`. Registered in durable + unified schemas
  and FreshStart delete/verify lists (NOT the purge list — legacy
  `DurableSinkingFund`/`DurableFundEvent` stay purged-on-sight and unused).
- **`Services/GoalLedgerService.swift`** — the single write path.
  Re-fetch → validate → `safeSave` or rollback + typed `Failure`.
  Invariants: contribution consumable once app-wide; purchase Σ ≤ adjustable
  amount; balances never negative on ANY mutation (incl. deleting an old
  contribution under a purchase); allocations respect pool;
  archive/complete with balance requires release-or-transfer (atomic
  reallocation pair, excluded from MTD and Spending).
- **UI**: 5th tab (`ContentView` tag 4, `NwIcon.goals` = "target").
  `Features/Goals/GoalsView.swift` (GoalsBuildActor + Sendable GoalsModel,
  detached-actor + 0.6s-debounced-save + significantTimeChange rebuild
  idiom; reserve header card with shortfall notice citing recent reserve
  outflows; suggestion inbox with confirm/dismiss; goal cards; archived
  section; empty state). `Features/Goals/GoalsSheets.swift` (GoalCard
  revived from git BudgetView with MTD line; detail sheet with ledger +
  orphan badges; entry sheet with cents-capable CurrencyInputFormatter and
  stays-open-on-failure; editor with kind picker, fixed vs
  months-of-spending target, archive/complete disposition dialog; reserve
  picker with USD-only + card-funding-account block + re-attach
  suggestions; contribution confirm; purchase picker defaulting to
  remaining adjustable amount). Emergency-target adoption runs through the
  service after each build when hysteresis passes.
- **Projections**: `ProjectionsDataActor` derives reserve exclusion —
  `ProjectionCashSelection.selectedAccounts` (unit-tested) filters active
  reserve canonical ids from the cash pool; no override rows written; the
  Settings cash-accounts sheet shows reserve-backed accounts as locked
  ("Backs goals — managed in Goals") and preserves the stored preference.
- **App tests** (`NetworthTests/GoalLedgerServiceTests.swift`, ⌘U): schema
  registration, contribution-once, pool-capacity, mixed-split ceiling,
  delete-blocked-below-zero, archive dispositions + reallocation pair,
  pipeline id resolution end-to-end, derived projection exclusion/restore.
- **Validation done**: `swift test` 216/216; generic-device Debug AND
  Release builds; `build-for-testing` compiles the app-test target. Not
  run: ⌘U app tests and on-device manual pass (user).
- New files registered directly in `project.pbxproj` (Goals group,
  Services entries, test target entry).

### Residual goal REMOVED (2026-08-08)
Built the residual/"whatever's left" catch-all, user tried it and asked to
remove it — the reserve header showing "$137.3K Unallocated" while a residual
goal simultaneously displayed the same $137.3K was confusing (same money, two
labels). Reverted: core `Goal.isResidual` gone, service create/update no
longer take it, `validateFundable`/`residualGoalNotFundable` removed, build
actor back to simple pool math, all UI (editor toggle, detail branch, card
badge, allocate/transfer exclusions) reverted, residual tests deleted.
`DurableGoal.isResidual` field KEPT (defaulted, unread) so on-device rows that
set it stay valid and just behave as normal goals — avoids a CloudKit schema
removal on the live device.

### (removed) Residual (catch-all) goal — superseded by the removal above
- Core `Goal` + `DurableGoal` gain `isResidual` (additive, defaulted).
- `GoalsBuildActor`: pool summary computed from NON-residual active balances;
  the residual item's balance = `pool.unallocated`, status `.openEnded`, no
  progress/MTD.
- Service: create/update take `isResidual` (forces target/planned/mode to
  neutral); `clearOtherResiduals` enforces the single-residual rule (demotes
  any other, its allocations stay). `validateFundable` blocks
  allocate/withdraw/move/purchase on a residual (`Failure
  .residualGoalNotFundable`).
- UI: editor toggle (hides target/kind/planned when on, warns if another
  goal is the current catch-all); detail sheet replaces funding actions with
  an explanation; residual excluded from allocate targets, move/transfer
  targets, and the allocate-button gating; card shows an info badge +
  "holds the unallocated remainder" subtitle, no progress bar.
- Tests: `residualGoalRejectsAllocation`, `onlyOneActiveResidualGoal`.
- Note: adding a defaulted param to `Goal.init` changed its mangled symbol —
  required `swift package clean` + xcodebuild clean to clear a stale-link.

### Taxable investment accounts can back goals (2026-08-07)
User's ETF money for goals sits in Plaid *investment* accounts, a different
source than the cash reserve model. Verified via live device data: taxable
brokerage ****5609 ($100k) + Robinhood individual are `CachedPlaidAccount`
rows (subtype `brokerage`), not `CachedFinancialAccount`. Scope agreed with
user: taxable brokerage + Fidelity Cash Plus only (Cash Plus already a cash
account). Retirement accounts (IRA/Roth/401k) deliberately excluded — can't
fund near-term goals without penalty, so backing one would falsely read as
funded.
- `ReserveBalance.conservative(...)` (in GoalLedgerService.swift) resolves a
  reserve row's balance from `CachedFinancialAccount` first, else
  `CachedPlaidAccount` by id — shared by the service and `GoalsBuildActor`.
  Investment balance = market value (no "available"); volatility surfaces
  honestly as a shortfall if it drops below allocations.
- `GoalLedgerService.addReserveAccount` gained a source-neutral overload
  (canonicalAccountId/name/institution/mask); the Plaid account `id` is the
  reserve key for investments.
- Reserve picker: new "Taxable Investments" section listing non-retirement
  investment/brokerage Plaid accounts (retirement subtype denylist), with a
  market-volatility footer. Projection cash-pool exclusion is unaffected —
  brokerage was never in the cash pool. Net worth isn't double-counted —
  goals only label existing balances.
- Test: `taxableBrokerageContributesToReservePool`.

### Goals funding model simplified to envelope allocation (2026-08-07)
User rejected transaction-attributed funding ("why do I have to attribute a
transaction to a goal? I should be able to allocate any amount of the total
fund to any goal"). Agreed model, then implemented:
- **Funding = pure allocation.** Reserve pool = real savings balance (already
  reflects interest, transfers, everything). Goals divide that total. Deposits
  and withdrawals in the real account are never traced to a goal — they only
  change Unallocated. A transfer into savings shows in Spending (Savings
  Transfers category) and is invisible in Goals except as more to allocate.
- **Removed**: the entire transaction inbox — contribution suggestions,
  withdrawal suggestions, reserve-flow detection in `GoalsBuildActor`, the
  `GoalFlowConfirmSheet`, `confirmContribution`/`confirmWithdrawal`/
  `dismissSuggestion` service methods, `DurableGoalSuggestionDismissal` model
  (dropped from schema + FreshStart — never shipped so safe), and the
  `GoalsModel.Suggestion`/`GoalFlowDirection` types.
- **Added**: `GoalAllocateSheet` (reserve card → "Allocate to a Goal": pick
  goal + amount from Unallocated, "Allocate All" shortcut) and
  `moveBetweenGoals` (atomic reallocation pair). Per-goal detail keeps Add
  Money (allocate) / Withdraw (release to unallocated) / Record Purchase.
- **Kept transaction-linked**: only "spent from goal" (purchases), because it
  also pulls the purchase out of Spending. `manual` positive entries are
  allocations; MTD "this month" counts them. Shortfall message simplified
  (balance dropped below allocations → lower an allocation).
- GoalsView body is now a `List` (needed for the earlier swipe request, still
  useful) with clear-background card rows. 217/217 core + app tests compile;
  new service tests: release-to-unallocated, move-between-goals.

### Paycheck-detector fix from on-device data (2026-08-07)
- User reported a phantom recurring ~$576 Gusto inflow. Verified against the
  LIVE device store (app-group container `group.com.bluelava.me.financial`,
  copied via `xcrun devicectl device copy from`, queried with sqlite3 — the
  app-container copies are stale/pre-cutover): pay moved from account
  `0DF90838…` to `4F1DDDE2…` in January; the old account's final deposit was
  $576.06 on Jan 30. Payer-level freshness stayed green (deposits continue),
  but per-account portions had NO freshness rule, so the dead account kept
  projecting $576.06 every payday.
- Fix in `IncomeAnalyzer.detectPaycheck`: `portionIsFresh` applies the same
  missed-payday rule (tolerate 1, retire at 2) to each account's own series
  before it becomes a `PaycheckPortion`. New test
  `accountSwitchRetiresStalePortion` reproduces the switch (old portion
  retired at 6 months stale, still present one missed payday after the
  switch). 217/217 core tests green.

### Post-implementation fixes from on-device testing (same session)
- Reserve picker eligibility broadened from `.savings` to all cash-like
  types (Plaid maps money-market/CD/most "savings-purpose" accounts to
  `.cash` or `.checking`; user's dedicated accounts were checking-type).
  Savings sort first; per-row type caption (Plaid subtype when present).
  User then decided to consolidate: one true savings account is the sole
  reserve; other checking accounts revert to cashflow.
- Outflow suggestions added (was a fast-follow, promoted after the user hit
  it immediately): reserve outflows — internal transfers out AND investment
  contributions funded from a reserve account — appear in the inbox;
  confirm → "withdraw from which goal?" via `confirmWithdrawal` (once
  app-wide per transaction, capped by goal balance); dismiss = "came from
  unallocated". `GoalContributionConfirmSheet` generalized to
  `GoalFlowConfirmSheet` with a direction. Shuffle suppression applies only
  to internal-transfer pairs. Withdrawal service test added.

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
