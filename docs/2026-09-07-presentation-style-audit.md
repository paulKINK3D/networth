# Presentation-Style Audit (2026-09-07)

Audit of every sub-view presentation site against the rule noted in
`PLAN.md` (Information Architecture): **places** (drill-into-data,
read-mostly) should be pushes; **tasks** (create/edit/confirm with save
semantics) should be sheets; **quick adjustments** (small pickers/tweaks)
should be partial-height detent sheets.

**Totals: 115 sites audited — 93 conforming, ~22 outliers.** No
`.fullScreenCover` exists anywhere; only two sheets use detents today
(`PlaidBackendTokenSheet`, `PlaidMatchSourceSheet` — both correct and good
models to copy).

Structural finding: **Settings-as-a-sheet is architecturally sound.** The
Settings sheet hosts one `NavigationStack` whose internal navigation is
consistently push-based over genuine places (Accounts, Contacts,
Categories, Manual Assets, settings hubs). It is a browsable place-tree
inside a modal; no restructure needed.

## Pattern A — places presented as full sheets (should be pushes)

The dominant, most user-visible problem: the main dashboards' tappable
cards open modal sheets over read-mostly drill-down content.

| Site | Screen | Notes |
|---|---|---|
| SpendingHistoryView:281 | `SpendingGroupDetailSheet` (group card) | TRICKY — sheet embeds own NavigationStack + sub-sheets |
| SpendingHistoryView:1603 | `SpendingGroupDetailSheet` (from Trends) | TRICKY — host `SpendingTrendsView` lacks own stack and omits `.environment(container)` present at :281 |
| SpendingHistoryView:285 | `SavingsBucketDetailSheet` (Savings card) | TRICKY — own stack, sub-sheets |
| SpendingHistoryView:298 | `SpendingSinkingFundsSheet` (Reserves card) | TRICKY — own stack, internal pushes + sub-sheets |
| ProjectionsView:259 | `ProjectionAssumptionsSheet` (Projection Details) | TRICKY — three entry points plus an onDismiss handoff that chains into the paycheck sheet |
| ProjectionsView:272 | `SafeToSpendDetailSheet` (Spending Room) | Clean — single trigger, most straightforward conversion |
| ProjectionsView:282 | `CardPaymentDetailSheet` | TRICKY — hosts nested editor sheet + statement-cycle dialog |
| GoalsView:96 | `GoalDetailSheet` (goal card) | TRICKY — `GoalSheetShell` wraps its own stack + close toolbar |
| NetWorthView:210 | `TrendDetailView` ("About Net Worth") | Borderline — help/about content; modal help is a common idiom. Optional |

## Pattern B — quick adjustments as full sheets (should be partial-height)

Cheap, low-risk conversions: add `.presentationDetents([.medium, .large])`
following the `PlaidBackendTokenSheet` model.

| Site | Screen |
|---|---|
| AccountsView:1196, InvestmentsView:646 | `AccountNicknameSheet` (single rename field) |
| SettingsView:888 | `MinimumCashBufferSheet` (single currency field; its twin token sheet already has detents) |
| SettingsView:885 | `ProjectionCashAccountsSheet` (toggle list) |
| SettingsView:131 | `GoalReservePickerSheet` (account toggles; also inconsistent with sibling "Projections" push) |
| SpendingHistoryView:2512 | `CategoryGroupPickerSheet` (destination-group picker) |
| SpendingHistoryView:2520 | `SpendingGroupBudgetEditorSheet` (single amount; borderline task) |

## Pattern C — tasks pushed instead of sheeted (mostly leave as-is)

`PlaidTransactionReviewEditor` is pushed from review/history lists
(AccountsView:1137, :1663; SettingsView:1900, :2608;
SpendingHistoryView:6215). Strictly these are tasks arriving as pushes, but
drill-in editors inside a review navigation stack are a standard iOS
pattern, the editor's save/dismiss contract (`dismissAfterSave`,
`onSaved`) is built for the stack, and several sit inside sheets' own
stacks where sheet-over-sheet would be worse. **Recommendation: keep, and
amend the rule** (see below).

Real inconsistency to fix: `CanonicalPayeeEditor` and
`CanonicalCategoryEditor` are **pushed on edit** (AccountsView:2397, :2660)
but **sheeted on create** (AccountsView:2429, :2691). Same task, two
styles. Normalizing on push-for-both fits the list-drill context; TRICKY
because the editors host nested pushes.

## Rule refinements adopted by this audit

1. Inside a modal form or review flow that owns a `NavigationStack`,
   drill-in pickers and row editors are conforming as pushes (standard iOS
   form idiom) — do not convert to sheet-over-sheet.
2. Read-only help/about screens may present modally.
3. Confirmation dialogs are acceptable for 2–3 option picks
   (ProjectionsView:2083).

## Dead code found

`GroupedHistoricalReviewSheet` (SettingsView:2265) and
`TransactionSearchReclassifySheet` (SettingsView:2702) have **no call
sites anywhere** — candidates for removal under the retire-completed-
tooling rule.

## Suggested execution order

1. **Detents batch (Pattern B)** — 7 sites, mechanical, low risk. Under an
   hour of work plus device check.
2. **Dashboard sheet→push batch (Pattern A)** — 8–9 screens; each needs its
   inner `NavigationStack` unwrapped, close button replaced by back, and
   sub-presentations rehosted. The Spending trio plus Projections trio are
   the daily-visibility wins. One to two focused sessions.
3. **Editor consistency (Pattern C)** — unify payee/category editor
   edit-vs-create style. Small, separate change.
4. **Dead-code removal** — separate cleanup commit.
