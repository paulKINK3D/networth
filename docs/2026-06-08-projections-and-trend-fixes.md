# Projections + Trend Chart Improvements

## Context

The app's projection and trend surfaces have five user-reported shortcomings, all
clustered around two themes: the cash forecast doesn't surface enough detail for
the user to trust or act on it, and historical net-worth math undercounts when
closed accounts are involved. The intent is to make Projections genuinely useful
for day-by-day cash planning ("on the 22nd checking dips to $X because that's
when the Citi statement is due") and to stop the Net Worth Trend chart from
showing impossible negatives in months where the user clearly had $50K+.

User-confirmed decisions during planning:
- Per-card "payment due day-of-month" added to Card Settings (matches statements).
- Cash chart annotates discrete events; full chronological list lives in a new tap-to-open detail view.
- Spending lookback default flips from 60 → 365; no new Settings UI.
- The Projections-page category filter is unified with `DurableExcludedSpendCategory` (Settings + Projections become one source of truth).

---

## Fix 1 — Forward checking trajectory with actual CC payment & rent dates

**Problem:** `CashPositionProjector` already plots a daily curve (scheduled-only +
scheduled-with-variable-drain), but credit-card payments are not modeled as
discrete future events — only as a flat run-rate inside `dailyVariableNet`.
There's no representation of "Citi statement closes on the 5th, payment due on
the 28th, draws $1,840 from checking that day."

**Approach:**
1. Add `paymentDueDay: Int` (1–31, same wrap-to-month-end rule as
   `statementCycleDay`) to `CardStatementSettings` and `DurableCardSettings`.
2. Extend `CCPaymentForecaster` with `projectedPayments(asOf:horizonDays:)`
   returning `[(dueDate: Date, amount: Money, cardName: String, source: PaymentEventSource)]`.
   The algorithm walks **per statement cycle** with an explicit forward
   ledger so neither (a) the gap-window prior statement nor (b) running
   balance accounting fails the way Codex flagged. Existing
   `CCPaymentForecaster.forecast` is **not** reused for the per-cycle
   amount — it starts from `currentOwed` every time, which would re-charge
   the same balance into every cycle's payment over the horizon.

   **Step A — pending prior statement** (only emitted if
   `mostRecentClose ≤ asOf` and the matching due date hasn't passed).

   - `mostRecentClose = previousCloseDate(before: asOf)`
   - `priorDue = nextOccurrence(of: paymentDueDay, after: mostRecentClose)`
   - If `priorDue ≤ asOf` or `priorDue > horizonEnd`: skip Step A.

   Reconstruct the close-date balance from observed transactions instead
   of using `currentOwed` directly (which already reflects post-close
   activity):

   ```
   postCloseCharges  = sum of card charges with date in (mostRecentClose, asOf]
                       (debits to the card — positive milliunit sign convention)
   postClosePayments = sum of payment-side amounts of cash→card transfers
                       with date in (mostRecentClose, asOf]
   statementCloseBalance = max(0, currentOwed - postCloseCharges + postClosePayments)
   ```

   YNAB doesn't tag whether a post-close payment applied to the prior
   statement or to a post-close purchase. Convention: payments apply to
   oldest debt first (statement before post-close charges):

   ```
   paymentsAppliedToStatement = min(postClosePayments, statementCloseBalance)
   unpaidStatement            = statementCloseBalance - paymentsAppliedToStatement
   pendingAmount              = policy(unpaidStatement)   // full → unpaidStatement
   ```

   Emit `(priorDue, pendingAmount, .pendingPriorStatement)`. The ledger
   (Step B) treats `pendingAmount` as a payment landing at `priorDue` for
   carry-forward purposes.

   **Step B — future cycles in horizon, with explicit ledger** (Codex
   finding: a cycle-by-cycle re-application of `forecast()` repeatedly
   bakes `currentOwed` into every cycle).

   State carried forward:
   - `owed` — running card balance owed; initialized to `currentOwed`.
   - Apply Step A's `pendingAmount` against `owed` at `priorDue` via the
     same "earlier-emitted payments land in this cycle" pathway below.
   - `events: [PaymentEvent]` — emissions so far (used for carry-forward).

   For each `closeDate` walking forward starting at
   `nextCloseDate(after: asOf)` until `closeDate > horizonEnd`:

   ```
   cycleStart = max(asOf, previousClose iteration's closeDate)
   cycleEnd   = closeDate

   cycleCharges = dailyAverageCharge × days(cycleStart, cycleEnd)
                + sum(scheduled charges to this card with date in (cycleStart, cycleEnd])

   cyclePayments = sum(scheduled YNAB cash→card payments to this card
                       with date in (cycleStart, cycleEnd])
                 + sum(events.amount where event.dueDate in (cycleStart, cycleEnd])
                       // i.e. carryforward of payments emitted in earlier iterations

   owed += cycleCharges - cyclePayments
   statementBalance = max(0, owed)
   dueDate = nextOccurrence(of: paymentDueDay, after: closeDate)
   if dueDate ≤ horizonEnd:
       paymentAmount = policy(statementBalance)
       events.append((dueDate, paymentAmount, .futureCycle(closeDate)))
       // Do NOT also write owed -= paymentAmount here.
       // The next cycle's cyclePayments sum already includes this event via
       // the carryforward term above, so subtracting now would double-count
       // and erase that cycle's new charges. The carryforward IS the single
       // source of truth for "emitted payments affecting later cycles."
   ```

   **Single-mechanism invariant (Codex finding):** the carryforward sum in
   `cyclePayments` is the *only* path by which emitted payments affect
   subsequent cycles' ledger state. Do not also decrement `owed` at emit
   time — the two paths together turn into a double-subtract that erases
   the cycle's new charges (verified: with `currentOwed = $1000`, `dailyAvg = $20`,
   the double-subtract makes cycle 2's statement balance evaluate to `max(0, -480) = 0`).

   This produces the user-visible "Citi statement closed on the 5th;
   payment due on the 28th will draw $1,840 from checking" event, *and*
   the "this card's last statement closed two days ago, payment is
   landing on the 28th of this month even though there's no future close
   in that window" event — both with correct amounts.

3a. **Dedupe scheduled cash → card transfers vs generated CC events**
    (Codex medium finding: today's `CashPositionProjector` suppresses
    scheduled transfers whose `transferAccountId` is in `spendAccountIds`
    — which includes CC accounts at the call site. That means a scheduled
    YNAB cash → CC payment vanishes from the cash chart. Once we also
    emit generated CC events, we'd quietly double-count or quietly
    drop, depending on which path wins.)

    The fix has three coordinated parts:

    - **Projector — change `project()`'s scheduled-expansion rule:**
      take a new `cardAccountIds: Set<String>` argument. Scheduled
      transfers where `accountId ∈ cashIds && transferAccountId ∈ cardAccountIds`
      are **no longer suppressed** — they become real cash outflows on
      the chart. Only true intra-cash transfers
      (`transferAccountId ∈ cashIds`) remain internal.

    - **Variable-rate computation — unchanged:** historical cash → card
      transactions continue to count as "internal" for
      `computeDailyVariableNet`, so a user's typical monthly cash → CC
      payment is excluded from the smeared daily rate. (Otherwise the
      rate would smear those payments AND the discrete events would
      reapply them — the same kind of double-count.)

    - **Generated CC events — amount-aware residual against the
      due-window (NOT the accrual window).** Codex flagged that
      deduping over the accrual window `(cycleStart, cycleEnd]` is wrong:
      the generated event lands at `dueDate`, which is *after*
      `cycleEnd`, so (a) a user-scheduled payment on the actual due date
      is missed by the check and applies on top of the generated event,
      and (b) a tiny pre-close partial payment silently suppresses the
      entire generated event. The correct rule is amount-aware,
      window-correct:

      ```
      // Step B, after computing statementBalance for this cycle:
      coverage = sum(scheduled cash→card transfers to this card
                     with date in (closeDate, dueDate])
      residual = max(.zero, statementBalance - coverage)
      if residual > .zero && dueDate ≤ horizonEnd:
          events.append((dueDate, residual, .futureCycle(closeDate)))
      ```

      **Pre-close** scheduled transfers (date ≤ `closeDate`) are
      ledger reductions only — they're already in this cycle's
      `cyclePayments` and have already reduced `owed` before
      `statementBalance` was computed.

      **(closeDate, dueDate]** scheduled transfers are payment-event
      coverage for this cycle. They reduce the generated event's amount
      via `residual`. They are also picked up by the NEXT cycle's
      `cyclePayments` (since `(closeDate, dueDate] ⊂ (closeDate, nextClose]`)
      — that's correct because those scheduled transfers really do
      reduce next cycle's starting `owed`. The carryforward of the
      emitted residual handles the rest of the payment's impact on
      next-cycle `owed` (see the single-mechanism invariant).

    Net effect: every CC payment on the cash chart comes from real
    scheduled transfers (now visible because the projector stopped
    suppressing them) plus a residual generated event sized to whatever
    portion of the statement wasn't covered by scheduled payments. Full
    coverage → no generated event. Partial coverage → smaller generated
    event. No coverage → full generated event. No double-counts, no
    silent suppressions.

3. New per-card payoff policy field on `DurableUserSettings`:
   `defaultPayoffPolicy` (rawValue: `full | minimum | fixed:<amount>`). User pays
   in full per memory, so default is `full`; the field is plumbing so the cash
   forecast can use the right number per card and the user can override later.
4. `ProjectionsView.cashProjection(history:)` (line 168–186) merges the CC
   payment events into a new `extraScheduled: [(Date, Money, String)]` argument
   that `CashPositionProjector.project()` applies on the right day, alongside
   the existing scheduled-transactions expansion.
5. Form work: `CardSettingsForm.swift` grows a "Payment due day" wheel mirroring
   the existing close-day wheel.

**Test matrix for `projectedPayments` (must all pass before Fix 1 is "done"
— Codex flagged the prior-statement gap, the prior-amount math, and the
multi-cycle ledger as blocking misses across two review passes):**

Calendar/cycle structure tests:

| Scenario | Close day | Due day | `asOf` relative to last close | Horizon | Expected events |
| --- | --- | --- | --- | --- | --- |
| Gap window: closed but unpaid | 5 | 28 | 2 days after close | 90d | `.pendingPriorStatement` on the 28th of current month + future cycles |
| Due day after close day (same-month due) | 5 | 28 | day before close | 90d | Future-cycle events only |
| Due day before close day (wrap-around due) | 28 | 22 | day after close | 90d | `.pendingPriorStatement` on the 22nd of next month + future cycles |
| Same close/due day | 15 | 15 | day before close | 90d | All events on day-15 of each month after close |
| Multi-cycle horizon | 5 | 28 | mid-cycle | 90d | At least 3 cycle events emitted |
| Month-end clamping | 31 | 31 | early February | 90d | Events clamped to Feb 28/29 |

Amount-math tests (the ones Codex flagged most pointedly):

| Scenario | Setup | Expected pending amount | Expected future-cycle amounts |
| --- | --- | --- | --- |
| Post-close purchases + partial payment | Close balance $1000, then $500 new purchases and $200 payment between close and `asOf` | **$800** (= $1000 statement − $200 applied), NOT $1100, NOT $1300 | n/a for prior; future cycle reflects the carryforward |
| Partial pre-payment, no new charges | Close balance $1000, $300 paid between close and `asOf` | **$700** | $0 next-cycle (no new charges, no new balance) |
| Full pre-payment | Close balance $1000, $1000 paid between close and `asOf` | **$0** — event NOT emitted | $0 next-cycle |
| Multi-cycle, NO new charges after first close | `currentOwed = $1000`, `dailyAverageCharge = $0`, no scheduled activity, 90d horizon | First emitted event clears $1000 | Subsequent cycles emit $0 (do NOT re-charge the $1000) |
| Multi-cycle with steady spend, full-payoff policy | `dailyAverageCharge = $20`, 90d horizon, ~3 cycles | Each emission ≈ $20 × days_in_cycle | Cumulative checking outflows match cumulative spend, not 3× current balance |
| Scheduled YNAB transfer (cash → card) within a cycle | Existing scheduled $500 cash→card on day N | Cycle ledger debits this payment from `owed` before computing `statementBalance`; generated CC event NOT emitted for that cycle | The scheduled $500 appears once on the cash chart (no double-count, no silent drop) |
| Future-cycle carryforward of an earlier emission | First emitted event ($1,840) lands on day 28; close-day 5 of the following month | Second cycle's `cyclePayments` includes that $1,840 | Second cycle's `statementBalance` reflects only new charges since the first close |
| Single-mechanism invariant verification | `currentOwed = $1000`, `dailyAvg = $20`, full-payoff policy, 90d horizon | Cycle 2 emits ≈ $600 (a month's spend) | Cycle 2 must NOT emit $0 (which is the double-subtract failure mode) |

**Projector-level cash-curve tests (separate from `projectedPayments` tests
— Codex finding: the cash chart itself, not just the payment generator,
needs end-to-end coverage):**

- **Scheduled cash → card transfer appears on the cash curve.** Starting cash $5,000,
  scheduled YNAB transfer $1,840 from checking → CC on day 15. Expected:
  `pointsWithVariable` and `scheduledPoints` both show a $1,840 drop at day 15. No generated CC event for that card's cycle.
- **Generated CC event appears on the cash curve when no scheduled transfer exists.**
  Starting cash $5,000, no scheduled cash → card transfer, card has `currentOwed = $1,840` with close-day 5 / due-day 28. Expected: `pointsWithVariable` shows a $1,840 drop at day 28.
- **Both present → no double-drop.** Starting cash $5,000, scheduled $1,840 transfer on day 28 (the due date) AND the projected statement balance is $1,840. Expected: exactly one $1,840 drop, sourced from the scheduled transfer (generator emits $0 residual). Verifies the dedupe window is `(closeDate, dueDate]`, not the accrual window.
- **Partial due-date coverage → residual generated.** Statement balance projected at $1,840. Scheduled cash → card $500 on day 28 (the due date). Expected: two events on day 28 — scheduled $500 + generated residual $1,340 = $1,840 total cash outflow on that date. Generated event must NOT be suppressed by the small partial.
- **Pre-close partial does NOT suppress the generated due-date payment.**
  Statement balance would be $1,840 at close; user has a scheduled $200 cash → card on day 3 (before close on day 5). Expected: pre-close payment reduces `owed` via `cyclePayments` → `statementBalance = $1,640` → generated event $1,640 on the due date. Codex specifically called out the failure mode where a small pre-close payment in the accrual window would silently zero out the generated event.
- **Variable rate does not also smear a scheduled cash → card payment.** Lookback
  window includes one $1,840 historical cash → CC payment. `dailyVariableNet`
  must exclude that historical transfer (so it doesn't show up as a daily
  drain on top of the discrete events going forward).

**Files:**
- `NetworthCore/Sources/Models/CardSettings.swift` (add field, init, defaults)
- `NetworthCore/Sources/Projections/CCPaymentForecaster.swift:17` (extend with `projectedPayments`)
- `NetworthCore/Sources/Projections/CashPositionProjector.swift:49` (new `extraScheduled` argument; merges into `scheduledByDay`)
- `Networth/Persistence/DurableModels.swift:125` (`DurableCardSettings`: new column + `toCore()`)
- `Networth/Persistence/DurableModels.swift:164` (`DurableUserSettings`: `defaultPayoffPolicyRaw: String`)
- `Networth/Features/Settings/CardSettingsForm.swift` (new wheel)
- `Networth/Features/Projections/ProjectionsView.swift:168` (`cashProjection` wires CC events in)

**Reuse:** `ScheduledTransactionSummary.occurrences(from:through:calendar:)`
already produces the per-day event list for rent/recurring; same shape used for
CC events.

**SwiftData migration:** adding nullable/default-valued columns to existing
`@Model`s is non-breaking. New columns default to sentinel values (`paymentDueDay = 0`
treated as "use statement day + 21" until user sets it; `defaultPayoffPolicyRaw = "full"`).

---

## Fix 2 — Trend chart: include selected closed accounts (REVISED)

**Problem:** The chart shows a fake smooth decline because closed YNAB
accounts (Robinhood, Vanguard staging, T-Bills, I-Bonds, etc.) are filtered
out of the historical reconstruction. The user's actual sequence over a
year was:

1. **Transfer** brokerage → checking (internal in YNAB; aggregate unchanged).
2. **Expense** checking → real Vanguard (categorized "Investments"; this is
   a real outflow that takes the money outside the YNAB universe).

Repeating that cycle removed value from YNAB step by step. With closed
accounts excluded, the chart loses their pre-transfer-out balance entirely
and only sees checking — which (with the earlier sign-aware skip design) was
walked back through expense outflows, inflating historical checking
artificially. Net effect: a smooth $150K → $50K decline that doesn't match
real events.

**New approach — abandon the asymmetric skip rule; walk selected closed
accounts instead.** The historical data is in YNAB. Including the closed
accounts in the walk recovers their real history pre-closure. Once they hit
$0 at the transfer-out date, they contribute $0 going forward — which is
correct, since after the expense-out the money has genuinely left YNAB.

User-controlled: a per-closed-account opt-in toggle in Settings. Default is
**off** (matches the original "closed accounts hidden" behavior). User
flips on for the ones whose historical balance they want represented
(Robinhood, Vanguard staging, T-Bills, I-Bonds). Old closed accounts they'd
rather forget stay off.

### Code

1. `DurableIncludedClosedAccount` model in
   `Networth/Persistence/DurableModels.swift`: `accountId: String`,
   `addedAt: Date`. CloudKit-synced.

2. `Networth/Persistence/ModelContainerFactory.swift` — register the new
   model in both schemas.

3. `Networth/Services/SyncCoordinator.swift` — bump
   `currentHistoryBackfillVersion` from 2 to **3**. Replace the
   role-map logic with: fetch open accounts and the closed accounts the
   user opted in; walk both sets via a single loop. Reconstructor returns
   `[DailyBalance]` (no `counterpartRole:`).

4. `NetworthCore/Sources/Projections/HistoricalNetWorth.swift` — strip the
   `CounterpartRole` enum, `CrossClosedAdjustments`, and `Result` type.
   Revert `reconstruct` signature to the pre-Fix 2 shape. Restore the
   simple `balance -= txn.amount` walk.

5. `Networth/Features/Settings/IncludedClosedAccountsSheet.swift` — new
   file. `@Query CachedAccount` filtered to `closed && !deleted`. Per-row
   `Toggle` writes `DurableIncludedClosedAccount` (or deletes it) and resets
   `historyBackfillVersion = 0` so the next sync re-runs the backfill with
   the new set.

6. `Networth/Features/Settings/SettingsView.swift` — new row in the Sync
   section: "Include Closed Accounts…" with the current count and an
   opening sheet.

7. `Networth/Features/NetWorth/TrendDetailView.swift` — drop the
   "Cross-Closed Adjustments" diagnostic section.

8. `Networth/Persistence/DurableModels.swift` — remove the
   `lastBackfillClosedAssetInflowsSkipped` and
   `lastBackfillClosedLiabilityPayoffsSkipped` fields from
   `DurableUserSettings`. Update
   `Networth/AppContainer/AppContainerController.swift` and
   `Networth/Features/Settings/ResetChartHistorySheet.swift` to drop the
   references.

### Tests

| Scenario | Setup | Expected |
| --- | --- | --- |
| Walked closed account contributes its historical balance | Closed brokerage with one closing transfer-out of $5K; open checking with the matching transfer-in | Aggregate stays flat at $5K across the transfer-out date — brokerage drops to $0, checking spikes |
| Original walk-back behavior preserved | Two transactions on one account, no transfers | Same byDay balances as the pre-Fix 2 test |
| Asset / liability aggregation | One cash account series + one credit-card series | Assets and liabilities tally correctly |

### Migration

- `DurableIncludedClosedAccount` is a CloudKit-safe `@Model` with
  default-valued properties — non-breaking schema add.
- Dropped `DurableUserSettings` Int fields are a non-breaking property drop
  in SwiftData. Existing on-disk values become unused.
- Backfill version 2 → 3 means every existing install re-runs the walk once
  with the new behavior, then settles.

### Downsides / accepted limitations

- Once the included closed account hits $0 and the user "expenses out" the
  money to a real external broker, the chart will drop by that expense
  amount on the expense date. That drop is honest: the money truly left the
  YNAB universe on that day. Reading the chart as "what's in YNAB" rather
  than "what I really own" is the trade-off — manual-asset entries can
  bridge it in a follow-up.
- The toggle defaults to "off" so the chart doesn't silently change for
  any future closed account the user hasn't reviewed.

---

## Fix 3 — Cash Position detail view (tap ⓘ for derivation)

**Problem:** The "≈ $X/day net inflow/drain" label at `ProjectionsView.swift:197`
is a black box. No way to see what historical window, what categories, what
scheduled offsets produced it.

**Approach:** Mirror `TrendDetailView`'s pattern exactly.

1. New file: `Networth/Features/Projections/CashPositionDetailView.swift`. Same
   `NavigationStack` + `List` + sections shape as `TrendDetailView` (line 34–131).
2. ⓘ button on the Cash Position card opens it as a `.sheet`, using the same
   `@State private var showingCashDetail = false` + `.sheet(isPresented:)`
   pattern from `NetWorthView.swift:67-69, 176-177`.
3. Sections to surface:
   - **Lookback & horizon** — window used, asOf date.
   - **Contributing cash accounts** — current balances summing to starting balance.
   - **Daily run-rate derivation** — historical signed total (over lookback),
     scheduled signed total subtracted, divided by lookback days = `dailyVariableNet`.
   - **Inflow vs outflow breakdown** of the historical signed total.
   - **Excluded categories applied** (read-only list with link to Settings).
   - **Upcoming events over horizon** — chronological merge of scheduled
     transactions + CC payments + scheduled income, each with date, amount,
     source. This is also the data the chart markers reference (Fix 4).

**Files:**
- `Networth/Features/Projections/CashPositionDetailView.swift` (new)
- `Networth/Features/Projections/ProjectionsView.swift:188` (`cashCard` adds ⓘ + sheet)
- `NetworthCore/Sources/Projections/CashPositionProjector.swift:29` (expand `Result`
  with two helper fields the detail view needs:
  `historicalSignedTotal: Money`, `scheduledSignedTotal: Money`. Already computed
  inside `computeDailyVariableNet` — just plumb them out.)

**Reuse:** `NwSectionHeader`, `NwCard`, `NwModalLayout`, `CurrencyFormatter.compact`,
`Money` formatters — all already in use across detail screens.

---

## Fix 4 — Chart event markers on the Cash Position chart

**Problem:** Even with the projector modeling CC payments and scheduled txns
correctly (Fix 1), the chart at `ProjectionsView.swift:188-257` is two smooth
lines — discrete events are invisible step changes hiding inside them.

**Approach:**

1. `CashPositionProjector.Result` grows a third field:
   `events: [CashEvent]` where
   `CashEvent { date: Date, amount: Money, kind: .ccPayment | .scheduledIn | .scheduledOut, label: String }`.
   Built from the same data the projector already iterates over — no new math.
2. `ProjectionsView.cashCard` adds `PointMark` annotations to the existing
   `Chart`, one per event, colored by kind (teal for inflows, muted red for
   CC/outflows, per the Deep Slate theme guidance in `CLAUDE.md`). Show only
   events whose absolute amount exceeds a threshold (e.g. > $200) so the chart
   doesn't get noisy.
3. The same `events` array powers the "Upcoming events" section in
   `CashPositionDetailView` (Fix 3).

**Files:**
- `NetworthCore/Sources/Projections/CashPositionProjector.swift:29` (`Result` + populate)
- `Networth/Features/Projections/ProjectionsView.swift:188` (`PointMark` annotations)

**Reuse:** `NwAppColors.positive` (teal), `NwAppColors.liability` (muted red),
existing `Chart` block, `CurrencyFormatter.compact`.

---

## Fix 5 — Spend by Category filter persists (single source of truth)

**Problem:** `CategorySpendingCard` holds an ephemeral `@State private var selection: Set<String>? = nil`
at `ProjectionsView.swift:466`. `CategoryFilterSheet.toggle` mutates it but
nothing writes to `DurableExcludedSpendCategory`. Settings'
`ExcludedCategoriesSheet` writes the durable model. Two surfaces, two states.

**Approach:** Unify on the durable model — exactly the user's "yes of course"
ask.

1. `CategoryFilterSheet` swaps its `@Binding var selection: Set<String>?` for
   `@Query private var exclusions: [DurableExcludedSpendCategory]` + a
   `modelContext` write path that mirrors `ExcludedCategoriesSheet.toggle` at
   line 104–120 (fetch by `categoryId`, delete-if-exists / insert-if-not,
   `ctx.safeSave(source: "projections.filter.toggle")`).
2. `CategorySpendingCard` drops `@State selection` entirely. It already has
   access to the exclusions via `ProjectionsView`'s `@Query` at line 29.
   "Selected = not excluded" becomes the rule everywhere.
3. The "Select all / Deselect all" buttons in `CategoryFilterSheet` (line 28–37)
   become bulk insert / bulk delete against `DurableExcludedSpendCategory`.
4. Semantic consequence: deselecting a category in the Projections filter now
   removes it from the spend projection math (because excluded categories are
   already passed to the projector at `ProjectionsView.swift:150`). That's the
   intended behavior per the user — filter and exclusion are unified.

**Files:**
- `Networth/Features/Projections/CategoryFilterSheet.swift` (rewrite to use durable model)
- `Networth/Features/Projections/ProjectionsView.swift:466,632,687` (drop `selection` state; derive `selectedRows` from `exclusions`)

**Reuse:** the exact `toggle` block in
`Networth/Features/Settings/ExcludedCategoriesSheet.swift:104-120`.

---

## Fix-adjacent: extend spend lookback default 60 → 365

**Approach:** One-line default change in `DurableUserSettings`:

```swift
public var spendingLookbackDays: Int = 365
```

Existing installs keep their current value; only fresh installs see 365.
No migration needed because the field already exists. Document the change so
users know they can shorten it back via Settings (the existing Settings control
remains, per the user's "just change the default" choice).

**File:** `Networth/Persistence/DurableModels.swift:164`.

---

## Verification

```bash
# Pure-Swift domain tests (fastest iteration on projector/forecaster math):
cd NetworthCore && swift test

# App target build + tests:
xcodebuild -project Networth.xcodeproj -scheme Networth \
  -destination 'platform=iOS Simulator,id=51F1E9A0-59D3-4021-A264-A706679CBD55' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

xcodebuild test -project Networth.xcodeproj -scheme Networth \
  -destination 'platform=iOS Simulator,id=51F1E9A0-59D3-4021-A264-A706679CBD55' \
  CODE_SIGNING_ALLOWED=NO
```

**Manual smoke (in-app review):**
1. Card Settings → set a payment due day on one card. Net Worth tab → Projections
   tab → confirm the CC payment dot appears on the Cash chart on that day-of-month
   and the daily balance steps down by the projected statement balance.
2. Tap ⓘ on the Cash Position card → confirm the derivation rows reconcile to
   the headline `$/day` number (historical signed − scheduled signed) ÷ lookback.
3. Settings → Force Full Resync → return to Net Worth → confirm Trend chart no
   longer shows negatives in months the user clearly had positive net worth.
   Tap the Trend ⓘ button and confirm the new "skipped cross-closed transfers"
   diagnostic count is non-zero where it should be.
4. Projections → Spending by Category → tap filter → deselect a category →
   close sheet → reopen → confirm category stays deselected. Open Settings →
   Excluded Categories → confirm same category appears excluded there.

**Both Debug and Release builds** for the SwiftData schema additions
(`paymentDueDay`, `defaultPayoffPolicyRaw`) since persistence changes are in scope.

---

## Out of scope (deferred, per project decisions)

- Plaid integration (`docs/2026-06-06-plaid-integration-research.md` — separate
  decision).
- Per-symbol investment positions / live prices (locked scope decision).
- Writing forecast transactions back to YNAB (read-only posture in v1).
- Closed-account "include with desaturation" treatment (Option 2 from
  `WORKING.md:48` — not chosen; Option 1 preserves the cleaner UX).

---

## Implementation order (suggested)

1. Fix 5 (category filter) — smallest blast radius, validates plumbing.
2. Fix 2 (closed-account reconstruction) — pure domain change, add tests first.
3. Fix 1 (CC payment due dates) — needs SwiftData column add + form work.
4. Fix 4 (chart event markers) — depends on Fix 1's event data.
5. Fix 3 (detail view) — depends on Fix 1's plumbing and Fix 4's events array.
6. Lookback default change — one-line, batch with whichever PR is open.
