# PLAN

## Project
- **Display name:** `BlueLava Networth`
- **Module / Xcode target:** `Networth`
- **Bundle ID:** `com.bluelava.me.networth`
- **Tests bundle ID:** `com.bluelava.me.networthTests`
- **CloudKit container:** `iCloud.com.bluelava.me.networth` (private DB only)
- **Minimum iOS:** 26
- **Purpose:** A private financial radar that explains the user's real financial position today, shows what is about to happen, and surfaces cash problems before they happen.
- **Audience:** Single user (the project owner). Personal use only, not distributed.

## Product North Star

**Primary question:** What can I safely do with my money between now and my next paycheck without losing sight of my long-term financial position?

The app combines two views that financial products usually separate:

- **Net worth:** what the user owns minus what the user owes. This is the long-term scorecard.
- **Forward cash position:** whether upcoming income, bills, transfers, spending, and credit-card payments leave enough accessible cash. This is the daily decision tool and the product's primary differentiator.

The product should answer, in order:

1. Can I safely cover the next few weeks?
2. When will cash be tight, and why?
3. What credit-card payments are coming?
4. Am I improving financially over time?
5. What changed my position?

The ideal headline is an interpreted answer, not merely a balance or chart. For example: "You're covered through August 18. Your lowest projected checking balance is $1,240 on August 12, after a $2,180 credit-card payment."

### Product Principles

- **Useful before comprehensive:** prioritize the few facts that support a real decision over a dashboard of available metrics.
- **Accessible language:** explain outcomes in everyday terms; keep financial mechanics available through drill-down rather than requiring the user to know them first.
- **Conservative interpretation:** clearly distinguish available cash, current bank balance, and total net worth. Never imply that illiquid assets are spendable or that a forecast is guaranteed.
- **Explain every forecast:** each projected low point or large payment should expose the income, bill, transfer, card cycle, or assumption that caused it. Unexplained precision is not trustworthy.
- **Credit-card timing is core:** statement periods and autopay dates must be modeled explicitly because the checking balance and current card balance alone do not reveal the next cash obligation.
- **Private and read-only:** preserve the local-first, read-only YNAB posture. The app interprets financial data; it does not move money or modify the budget in v1.

### Product Direction

The near-term priority is to make Projections the clearest and most trustworthy workflow in the app: one headline answer, a chronological timeline, transparent assumptions, and drill-down explanations. Net Worth remains the long-term scorecard supporting that workflow. The information architecture is fixed at four tabs; investment reporting is reached through Net Worth under the 2026-08-14 scope decision.

## Distribution & Scope
- iPhone only (no iPad, no Catalyst).
- Sideload via Xcode / TestFlight. No App Store submission planned.
- Plaid is the sole external financial-data source for banking, cards, transactions, and investments. The local App Group bridge remains the student-loan source. YNAB is retired: it has no UI, credentials, network access, imports, fallbacks, classification influence, or reporting role. Compatibility-only persisted fields may remain inert when required to protect SwiftData or CloudKit data.

## Locked Decisions

### Authentication
- The private Plaid backend credential is stored through `SecretStore`; Plaid provider credentials and Item access tokens never enter the app.
- **Face ID gate enabled by default** when the device supports biometrics; user can disable in Settings. A versioned migration on `DurableUserSettings.settingsSchemaVersion` flips legacy persisted rows (from before the default change) to the new default on bootstrap, so iCloud-restored or cross-device settings do not silently leave the user unlocked.

### Data Model
- **Net worth =** Plaid banking/card balances, manual assets, and confirmed non-duplicate Plaid investment balances, less an optional locally linked IBR student-loan balance.
- Manual asset types: real estate, vehicles, brokerage/retirement balances, crypto, collectibles.
- Investment accounts may come from manual entries or Plaid holdings. Plaid accounts remain excluded until duplicate reconciliation is complete.

### Persistence (Hybrid)
- **SwiftData (local-only):** re-fetchable normalized Plaid accounts, transaction deltas, and cursors. Legacy YNAB models may remain registered temporarily only to purge old local rows safely; they are never read by product logic.
- **SwiftData + CloudKit (private DB):** durable user data —
  - Manual assets and their balance history
  - Daily net worth snapshots
  - Daily per-account Plaid investment balances and inactive end markers
  - User settings, projection configuration, Face ID toggle
  - Canonical account mappings, editable Networth-owned contacts/categories,
    Plaid aliases, user-authored Plaid account nicknames, and
    transaction-specific decisions
- Daily net worth snapshot job runs once per day.
- **Local App Group only:** BL IBR's opt-in loan summary and dated balances remain in `group.com.bluelava.me.financial`. Networth holds the decoded document in memory and does not copy IBR fields into SwiftData or CloudKit.

### Historical Net Worth
- Preserve existing durable daily snapshots. New Plaid-only installs begin history with the first successful Plaid sync; retired-provider history is never reconstructed or re-imported.
- Manual assets snapshot **forward only** from install date.
- Snapshots persisted via CloudKit so history survives device wipes.
- Linked IBR balances are overlaid on the chart locally from IBR's dated App Group history. History defaults to the earliest cached Plaid transaction date, with a local override available. Earlier balances are estimated from IBR's earliest snapshot using $0 payments and its weighted rate as simple daily interest on principal; accrued interest is floored at zero and capitalization is not inferred. CloudKit snapshots intentionally exclude the contribution, rate, and override to preserve IBR's no-cloud policy.

### Projections
**Must-have (v1):**
- Upcoming **credit-card payment timeline** — for each card, estimate full-statement autopay debits from its statement-close day, payment-due day, current balance, recent activity, and scheduled transactions.
- Present expected debits chronologically so the user can answer what is leaving checking, when, and how much.
- Validate every known obligation against the specific cash account that must fund it. Aggregate savings can establish overall capacity, but must never hide an underfunded payment account; show the transfer amount and deadline when rebalancing is required. A configured payment account outside the selected cash pool makes coverage incomplete rather than silently dropping the card payment.

**Next product milestone:**
- Near-term cash-confidence headline using aggregate checking/savings: covered-through date or the first date projected cash turns negative.
- Safe-to-spend amount across the full selected projection horizon, after preserving projected ordinary spending, known obligations, and the user's minimum cash buffer.
- Lowest projected cash balance, its date, and the event that causes it.
- Horizon cash-flow bridge reconciling starting cash, income, scheduled outflows, card payments, unscheduled spending, and projected ending cash.
- Drill-down from each projected payment or low point to the contributing transactions and assumptions.
- Monthly spending drill-down showing every complete month used by the arithmetic mean, its scheduled/unscheduled split, included category totals, and excluded category list.
- Transaction-level expected-spending exclusions from monthly category details, persisted in CloudKit and reversible from the central Spending Exclusions screen. Split transactions are excluded by individual split leg.
- Plain-language uncertainty treatment so estimates are useful without appearing guaranteed.

**Deferred / optional:**
- Payday-to-bill alerts as a distinct notification surface.
- Category burn-down forecast ("Groceries will overspend by $120").

**Skipped:** Per-account 90-day running balance chart. Per-account known-commitment checks still run behind the aggregate chart and surface actionable funding warnings.

- **Projection horizon:** user-configurable from 30-180 days; default 90 days.
- **Read-only:** projections computed locally; we do NOT write forecast transactions back to YNAB. Architecture leaves the door open.

### CC Payment Forecast Algorithm (v1 spec)
**Inputs per card (cached from the selected banking source + Settings):**
- Current balance.
- Statement cycle day — **user-entered per card** in Settings (one-time setup, editable).
- Payment due/autopay day — **user-entered per card** in Settings (one-time setup, editable).
- Scheduled transactions on the card account.
- User-set minimum-payment params per card: percent (default 2%) and floor (default $25).

**Outputs per card:**
- **Upcoming full-statement autopay debit(s)** with statement-close and due dates.
- **Statement balance projection** = current balance + Σ(scheduled charges before next close date) − Σ(scheduled payments before next close date), adjusted for the relevant open/closed statement period.
- **Minimum payment** = max(floor, percent × statement balance projection).

**Algorithm lives in `NetworthCore.Projections.CCPaymentForecaster`** — pure Swift, fully unit-tested with `swift test`.

**Shipped extensions beyond the v1 spec above:** the cash projector maintains a known-commitment ledger and a projected cash curve. The main chart focuses on projected cash; scheduled detail remains in the event timeline and account checks. Estimated monthly spending is the arithmetic mean of complete monthly external outflows from up to 365 days of cash and funded-card activity, including scheduled spending. The projected curve adds only the mean unscheduled remainder because scheduled cash flows are already present in Known Commitments. Every observed expense therefore remains amortized into the reserve while known spending is still counted exactly once. Split categories, internal transfers, and the durable per-category exclusion list are honored. Short histories without a complete month temporarily use an equivalent daily-average fallback.
Known commitments are also projected per selected cash account. Scheduled transfers move money between those account trajectories without changing the aggregate curve, and an underfunded payment account overrides a misleading aggregate "Covered" result with a dated transfer instruction.
Safe to Spend reports only additional capacity available now through the lowest point identified across the full selected projection horizon. It subtracts the configured cash buffer from that lowest projected cash balance; ordinary spending, bills, card payments, and transfers are therefore already reserved. The card names the low-point date as the decision window rather than presenting the full horizon as the spending deadline.
Tapping Safe to Spend opens a reconciliation through that low point: starting cash plus known inflows, less scheduled outflows, card payments, and expected ordinary spending, followed by the buffer and final additional capacity. The same detail lists the dated events included before the low point.
When at least four complete monthly samples are available, Safe to Spend also shows a plain-language higher-spending case. It uses the 75th-percentile complete month and increases only the unscheduled reserve, since future scheduled obligations are already modeled directly. The downside amount appears as supporting text and in the detail sheet, not as a second chart line.

### Manual Asset Cadence
- **Monthly user-prompted updates.** App prompts on the 1st of each month to refresh values for any manual asset not edited in the past 30 days.
- Each manual asset stores a value-history series (one entry per edit, timestamped).
- Charts render at monthly resolution for individual assets.
- The **rolled-up net worth total snapshots daily**, using the last known manual-asset values between updates.

### Information Architecture
- **4-tab structure** (Accounts left the tab bar 2026-08-02; Goals added 2026-08-07; direct Net Worth account drill-down adopted 2026-08-11; Investments moved beneath Net Worth 2026-08-14):
  1. **Spending** — the initial tab and "where did the money go?" awareness surface: user-defined drillable groups, 24-month stacked history, judgment-free.
  2. **Projections** — chronological credit-card payment timeline, evolving into the near-term cash-confidence headline and explainable low-point workflow described above.
  3. **Goals** — named allocations backed by explicitly selected accounts; optional target progress, atomic staged allocation, and one optional goal that receives the live remainder. Goal spending is attributed through reviewed Goal Spend/Refund transaction types.
  4. **Net Worth** — current total, historical chart, and breakdown by account type; Balance Sheet categories drill into their contributing accounts and source-specific detail screens. Investments and Retirement each open a portfolio detail whose total, balance history, holdings, and review state are restricted to that category.
- **Settings** opens from the shared top-right management menu on every tab (backend access, Face ID toggle, sync controls, manual asset CRUD) — not a tab. The freed tab slot remains intentionally empty.
- No transactions tab; transaction detail remains available through existing account and Spending drill-downs.
- No privacy mode (tap-to-blur amounts) in v1.

### Design Language
- **Theme:** "Deep Slate" — the primary navy (`#003E83`), parchment
  (`#EBD999`), and rust (`#A93400`) derive from the third combination in the
  sixth row of page 11 of the local Sanzo Wada reference. Navy is also used for
  positive/on-track and accent treatments; a derived amber (`#9A5700`) means
  watch, parchment highlights the featured Spending group, and rust means
  liability/at-risk. Interactive semantic colors use explicit light/dark
  variants; fixed navy is not used as a dark-mode foreground. The BlueLava
  launch/lock gradient remains a separate shared cross-app brand treatment.
- Daily dashboards lead with one bold adaptive Deep Slate hero, one large
  whole-dollar answer, and a single supporting visual. Secondary numbers use
  softly tinted surfaces and progressive disclosure rather than competing
  card boundaries.
- Spending overview colors follow familiar semantics: blue is informational
  under-budget progress, green is positive Retained, and clear red is
  overspending or negative Retained. Brown/amber and pale yellow are not used
  to communicate budget status; factual calendar pace stays in drill-down.
- Modeled on WorkoutApp's design-system patterns (`Lift*` token enums, card variants, modal scaffolds).
- Design system **built first**, screens assembled from primitives.

## Architecture Patterns (from inventory-app + WorkoutApp)
- **SwiftUI + SwiftData**, `@Observable` for app-wide state container.
- **No view models.** Logic lives in services + pure helpers; views read `@Query` directly.
- **Protocol-based DI** for testable boundaries:
  - `SecretStore` (Keychain) — production + in-memory fake.
  - `BiometricGate` (LAContext wrapper).
  - `PlaidClient` (actor-isolated private-backend networking) — production + recorded-response fake.
- **`safeSave(source:)`** on `ModelContext` — never silently swallow save failures; posts notifications for global alert handling.
- **Separate SPM package** for pure domain logic (`NetworthCore`): models, milliunit math, projection calculators, formatters. No SwiftUI / SwiftData imports. Enables fast `swift test` runs.
- **Apple Testing framework** (`@Suite`, `@Test`, `#expect`) — not XCTest.
- **Actor-isolated Plaid client** keeps private-backend configuration and requests concurrency-safe.
- **Cursor sync** through Plaid `/transactions/sync`; no recurring-prediction endpoint.

## Design System (built first)
Modeled directly on WorkoutApp's `Lift*` system, prefixed `Nw*`:
- **Tokens:** `NwSpacing`, `NwCornerRadius`, `NwTypography`, `NwShadow`, `NwOpacity`, `NwStrokeWidth`.
- **Colors:** `NwAppColors` — semantic (`positive`, `caution`, `liability`), neutral base, theme accent.
- **Card variants:** primary, secondary, glass, inset (via `.nwCardStyle(...)` modifier).
- **Buttons:** primary, secondary, tinted, destructive.
- **Reusable views:** `NwCard`, `NwSectionHeader`, `NwMetricCapsule`, `NwStatusBadge`, `NwEmptyState`, `NwLoadingState`, `NwInlineNotice`, `NwBanner`, `NwModalLayout`.
- **Iconography:** SF Symbols only, mapped via `NwIcon` enum.

## Phases
- [x] **Phase 0 — Bootstrap:** Xcode project, SPM `NetworthCore` package, design-system token files (`Nw*`).
- [x] **Phase 1 — Legacy bootstrap:** The original YNAB authentication and sync foundation was superseded and retired by the 2026-08-20 Plaid-only decision.
- [x] **Phase 2 — Net Worth tab:** Current total, account breakdown, 5-year historical reconstruction, daily snapshot job.
- [x] **Phase 3 — Manual Assets:** CRUD UI, CloudKit sync, integration into net worth total.
- [x] **Phase 4 — Projections tab rebuild:** Cash-confidence headline, Known Commitments and Expected Spending curves, configurable horizon and cash pool, explainable low point, multi-cycle card autopays, and drill-down details.
- [x] **Phase 5 — Accounts tab:** List + drill-down, recent activity (read-only from cache).
- [x] **Phase 6 — Polish:** Face ID toggle, error states, empty states, splash/onboarding, sync indicators.
- [x] **Phase 7 — Investment reporting:** Portfolio summary, reconstructed balance history, allocation, holding details, and manual value-update access. Originally shipped as a tab; moved beneath Net Worth by the 2026-08-14 decision.
- [x] **Phase 8 — Local IBR bridge:** Opt-in App Group student-loan summary, current liability reporting, local chart overlay, Accounts detail, and deep link back to BL IBR.
- [x] **Phase 9 — Plaid Investments:** Private backend contract, native Link flow, local investment cache, explicit duplicate reconciliation, holding-level reporting, and reconciled contribution to Net Worth.
- [x] **Phase 10 — Plaid Transactions foundation:** Product-aware Items, 24-month cursor sync, canonical account identity, local learning rules, opt-in privacy-bounded Claude fallback, and review inbox. The completed YNAB migration tooling was retired by the 2026-08-20 decision.

The foundational capabilities have shipped. Projections serves the cash-confidence north star, while Net Worth and its account and investment drill-downs provide the supporting scorecard. The 2026-08-14 four-tab consolidation is implemented. Plaid's Worker and iOS implementation are complete on `feature/plaid-integration`; Sandbox linking and unlinking were validated before the Worker moved to Production Trial, where Link, account review, and real investment holdings were validated on-device.

## Future Work
- **Consolidate account management.** Account controls are currently scattered
  across Net Worth drill-downs, Settings → Accounts & Sync, Projection
  settings, Goal reserve setup, investment review, and per-account Spending
  visibility. Design one clear management entry point while preserving the
  focused account-detail screens and the fixed four-tab structure.

## Key Decisions Log
- **2026-08-30** — Up to four checking, savings, cash, or credit-card accounts
  may be explicitly shown on Spending. Selection uses a text-labeled account
  detail toggle rather than a favorite symbol and persists only canonical
  account IDs plus presentation order in private CloudKit. Current and
  available balances remain disposable Plaid cache data. Spending presents the
  selected accounts as compact two-column cards: cash-like accounts prefer
  available balance, while credit cards show amount owed.
- **2026-09-03** — One user-designated Spending budget acts as the Savings
  bucket. It contains no ordinary categories, and its repeating target behaves
  like every other monthly target. A Savings Choice reallocates one selected
  month's budget from another group into Savings without creating a bank
  transaction or changing the total budget. Actual progress comes from an
  explicit `Savings` transaction type on the outgoing budgeted-cash side of a
  transfer; the receiving deposit remains an Internal transfer, whether or not
  the destination account is linked. Savings is valid only for negative whole
  transactions and negative split lines and takes a required Savings Month,
  but no ordinary category, Goal, or Expense Source. One outgoing transfer may
  be split across multiple Savings months. Savings activity reduces the
  selected month's Savings remaining and Retained like an expense while staying
  outside ordinary-spending totals, trends, and historical projection-spending
  estimates. Month attribution never changes the real posted date, account
  balance, account history, Net Worth, or Projection timing. Every outstanding
  closed month remains independently due until one or more explicit Savings
  entries fulfill it. Spending surfaces one closed month at a time, oldest
  first, in a full-width transfer prompt whose separate read-only detail shows
  that month's total, each completed transfer with its posted date, and the
  remainder. New entries default to the oldest outstanding month but may select
  any outstanding prior month or the posted month. The type is offered only
  while a Savings bucket is configured. Already
  assigned legacy receiving-side deposits remain grandfathered compatibility
  activity because Plaid supplies no durable transaction pairing; unassigned
  account-type-inferred transfers stop counting and are surfaced for one-time
  review. Historical assignments retain their recorded group identity if the
  current Savings designation later changes. The regular month-scoped Savings
  detail keeps Transferred and user-entered Savings visibly separate in its
  hero, including an explicit `$0` transfer when none exists. It shows the
  repeating monthly amount as Available, the month's Savings entries as
  Assigned, and combines dated Savings entries and transfers in one activity
  table. Savings entries use favorable green, remain independently editable
  and swipe-deletable, and are added through the fixed bottom `Add Savings`
  action. Add/Edit Savings follows the Reserve form pattern and accepts
  trailing-aligned whole-dollar currency values. This regular detail remains
  distinct from the closed-month transfer prompt's read-only detail.
- **2026-09-04** — Spending Reserves have two distinct lifecycle actions.
  Archive preserves the Reserve and every assignment and purchase interaction,
  removes it from active planning, and moves it to the Archived Reserves area
  reached from the Reserves overflow menu. Archived Reserves retain read-only
  ledger access and may be restored. Delete permanently removes the Reserve
  and all Reserve-specific assignment and purchase-link records; it never
  removes or rewrites the imported financial transactions beneath those links.
- **2026-09-02** — Reserves are distinct from Goals and ordinary monthly
  budgets. Spending presents one aggregate Reserves card; individual reserves
  carry their balances forward and require only a name. Target, due date,
  monthly plan, and opening balance are optional. A target plus date calculates
  a suggested monthly plan, but plans never allocate money automatically. The
  user explicitly assigns affordable amounts from selected active Spending
  budgets. A reserve may receive multiple assignments in one month, including
  from different source groups; each entry remains independently editable and
  removable. Assignments cannot exceed their source groups' currently unspent
  amounts, and each source card includes them in its lighter-blue reallocation
  segment.
  The aggregate card shows the total carried balance beside up to three slim
  Reserve columns. The columns use a lighter reallocation blue on one shared
  balance scale; targeted Reserves add a subtle outline up to the target while
  open-ended Reserves show only their saved balance. They prioritize nearest
  due date, then highest percentage complete, then largest saved balance, with
  a `+N` count for additional Reserves. One budget group may be the effective-
  dated automatic remainder;
  its target is confirmed funding minus every other repeating target, so all
  funding is assigned without rewriting historical months. The remainder is
  signed rather than clamped: a shortfall remains visible and can be covered
  by residual checking cash or a real savings transfer. Retained derives from
  the reconciled remaining monthly budget balances, so assigning money to a
  reserve reduces the selected source budget and Retained exactly once in that
  month. A transaction or split line draws from a reserve only after explicit
  user confirmation; that later purchase drains the carried reserve without
  reducing a monthly budget or Retained again, and without rewriting imported
  activity or cash balances. Reserve money remains as a virtual earmark in the
  main checking cash; it is not tied to a holding account, moved into savings,
  or duplicated in a Goal. Opening Reserves from Spending uses the displayed
  month: balances and activity stop at that month, new assignments belong to
  it, and existing assignments retain their original month when edited. A
  historical assignment changes that month's source budget and Retained, then
  carries the resulting balance forward. Projections treat the aggregate
  carried Reserve balance as unavailable in Safe to Spend and tight-status
  calculations while leaving the chart and account warnings on real bank
  balances. Spending Room lists the Reserve balance separately. Confirmed
  Reserve-funded purchases are excluded from historical expected spending so
  using an earmark is not deducted a second time; future plans have no
  projection effect until an assignment is explicit. Transaction review calls
  the
  independent funding choice `Source`; every ordinary outgoing split line has
  its own Source. New records use an additive private-CloudKit schema and do
  not revive the retired pre-goals sinking-fund models. An additive assignment-
  origin field treats rows from the pre-release automatic trial as inactive
  legacy data until the user makes an explicit assignment.
- **2026-08-30** — Spending and Projections use a glance-first dashboard
  hierarchy. Spending leads with the remaining or overspent budget amount and
  a 270-degree progress arc, keeps the separate funding comparison as Funded
  versus Retained, shows every active budget group in a compact two-column
  card grid in user order, separates monthly spending under Budgets from
  Savings and Reserves under Future, represents ordinary budgets with
  a vertical draining column aligned to the displayed remaining amount, and
  keeps Trends plus Transactions in a compact action strip.
  Projections leads with the most actionable amount (Available, Buffer gap,
  Transfer needed, or Projected balance), embeds a simplified scrub-capable
  cash curve, and shows the first three upcoming events as a visual timeline.
  Spending overview progress uses blue while under budget and red only when
  overspent; positive Retained uses green. Calendar pace is available after
  opening a budget rather than encoded with brown or pale-yellow treatments.
  Financial calculations, detail sheets, event actions, and the four-tab
  information architecture are unchanged.
- **2026-08-30** — Projection timing corrections never rewrite imported Plaid
  dates. Weekly and biweekly paycheck detection uses the dominant recent
  weekday so an isolated holiday shift does not move the future schedule. A
  user may override only the detected cadence and next payday in Projections;
  confirmed history continues to determine amount and receiving accounts.
  Expected income due today is visible but stays outside projected cash until
  confirmed. Credit-card purchases and non-payment credits within three days
  of a statement close expose their posted and differing authorized dates and
  may be assigned to either adjacent statement cycle. That private-CloudKit
  assignment affects statement estimates only and can be removed to restore
  posted-date behavior. Predicted paycheck and recurring-income events remain
  visible and editable from the Projections timeline.
- **2026-08-22** — The monthly Spending summary follows the user's
  one-month-ahead funding model. `Funded` is the preceding calendar month's
  confirmed Income, `Spent` is the selected month's actual ordinary spending,
  and `Remaining` is Funded minus Spent. Income received during the selected
  month does not change that month's funding comparison. When preceding-month
  history is unavailable, Funded and Remaining remain unavailable rather than
  silently falling back to an estimate. Expected income remains a Projections
  concept.
- **2026-08-20** — YNAB is fully retired. The completed one-time backlog reference workflow is superseded by a Plaid-only runtime: no YNAB UI, token management, network client, account mapping, reference import, cached-data fallback, classification evidence, or report contribution remains. An idempotent per-launch local cleanup purges disposable YNAB cache/reference rows while preserving every approved Networth decision, contact, category, split, snapshot, goal, setting, and Plaid/IBR record. The synchronized Keychain token is removed only after the data-preserving release is verified on the physical device. Provider-derived canonical IDs and optional CloudKit fields may remain inert when rewriting or deleting them would risk durable relationships or schema compatibility.
- **2026-08-19** — A user-entered credit-card payment amount and payment
  date override the forecast for one statement cycle only. The confirmation
  is private-CloudKit durable, keyed by card plus statement close date, and
  stops applying automatically after that cycle leaves the forecast. Later
  cycles remain estimates until independently confirmed. Card-payment detail
  reconciles the estimate from the exact current balance and transactions
  since statement close; post-close purchases belong to the next statement,
  actual card payments reduce the prior-statement obligation, and other
  credits are treated as current-balance-only. Statement or email ingestion
  is deferred because entering the authoritative amount and date from the
  issuer email is faster and avoids transmitting documents.
- **2026-08-19** — Spending budgets are optional monthly guides on existing
  user-created Spending groups, never categories. Any group may participate,
  and one budgeted group may be explicitly pinned on the Spending screen.
  Targets repeat until changed, changes take effect in the current month while
  preserving prior months, and each month resets with no carryover. The screen
  reports actual spent, target, remaining or over, days left, and the
  then-existing actual Retained cash-flow number; that last portion is
  superseded by the 2026-08-22 funding decision. A factual calendar comparison colors budget
  progress navy when on track, amber when up to ten percentage points ahead,
  and rust when materially ahead or over budget; it never projects a
  finish or uses historical behavior. The budgeted-group total and detailed budget list
  replace the historical average
  on the main Spending surface. Historical averages and the former multi-month
  controls live in Spending Trends. Budgets do not move money or write to a
  provider. This supersedes the 2026-08-12 placement of multi-month summaries
  on the main Spending screen without changing its arithmetic-mean rule.
- **2026-08-16** — Imported Plaid account names remain unchanged in the local
  provider cache. A user may assign a durable display name from banking, card,
  or investment account detail; the additive private-CloudKit override is
  keyed by Plaid account ID and applies consistently throughout the app and to
  the optional Claude financial snapshot. Restoring the imported name deletes
  the override. All fields have defaults, no legacy-field cleanup is required,
  and removing an override immediately falls back to the current provider
  name.
- **2026-08-16** — Account-specific projection warnings use
  `[Account name] may be overdrawn` and `Projected to fall $X below $0 on
  [date].` The amount and date describe the same projected low point. This
  approves only account-underfunding copy; exact language for other projection
  scenarios remains a separate product decision.
- **2026-08-14** — The four tabs are ordered Spending, Projections, Goals, and
  Net Worth. Spending is the initial tab, reflecting the app's everyday review
  flow; Net Worth remains the supporting long-term scorecard at the trailing
  position. No destinations or capabilities change.
- **2026-08-14** — **Investments moves beneath Net Worth.** Remove Investments
  as a top-level tab and leave the app with four tabs: Net Worth, Spending,
  Projections, and Goals. The Net Worth Investments and Retirement Balance
  Sheet categories open separately scoped portfolio details. Each headline,
  30-day balance movement, history, holdings list, review count, and account
  drill-down must reconcile to the category row that opened it. The former
  source/type Allocation section is removed because it was not asset-class
  allocation and repeated Holdings. The freed tab slot remains intentionally
  empty. This supersedes the 2026-08-07 five-tab decision without changing
  Plaid investment sync, reconciliation, or contribution-to-Net-Worth behavior.
- **2026-08-12** — **All Transactions** moves from the bottom of Net Worth to
  the bottom of Spending. The destination, search, category filter, paging,
  and transaction editing behavior are unchanged; only its top-level entry
  point moves so transaction activity lives with spending analysis rather
  than the long-term balance sheet.
- **2026-08-12** — Historical spending and funding calculations use arithmetic means, not medians, so lumpy purchases, savings-funded repairs, annual obligations, and payment-timing shifts remain amortized into the user's real monthly cost. This applies to Spending comparisons, projection spending reserves, the operating necessities envelope, emergency-fund math, and variable-bill suggestions. Medians remain only in anomaly-resistant signal detection: paycheck/bill cadence, paycheck phase clustering, and stability thresholds. Multi-month Spending shows actual total plus `Avg/mo = total ÷ month count`; it never presents `median × months` as a companion total. This supersedes median-based calculation language in the 2026-08-07 decision and the earlier projection implementation notes.
- **2026-08-11** — Every top-level tab uses one consistent top-right overflow menu with Settings and Refresh. Tab-specific management stays in that menu: Spending Groups, Projection Settings, Investment Accounts, and Goal Accounts. Net Worth adds no contextual item. Goals keeps New Goal as the only separate toolbar action; management controls no longer move between opposite toolbar corners.
- **2026-08-11** — Goal allocation editing uses a compact staged allocation table. Tapping a non-automatic goal opens focused amount entry; one separately selected automatic-remainder goal is visibly locked and derives the live remainder. The header reconciles available, allocated, and remaining value, and Apply commits the complete snapshot atomically. Changing the automatic-remainder goal preserves the staged allocations. Manual assets classified as **Other** may explicitly back goals and use their effective reconciled value; property, vehicle, retirement, and other non-account manual asset kinds remain ineligible. This replaces the temporary always-visible multi-field/toggle sheet and does not restore the rejected per-goal Add/Remove interaction.
- **2026-08-11** — Net Worth Balance Sheet categories drill into their contributing accounts, and each account row opens its source-specific detail. The redundant "All Accounts" card is removed; Contacts and Categories move to Settings → Accounts & Sync. "All Transactions" remains as the cross-account history entry (moved from Net Worth to Spending by the 2026-08-12 decision). This supersedes the 2026-08-02 placement of Accounts behind a dedicated card while retaining account detail as a drill-down capability rather than a tab.
- **2026-08-09** — Goals use a live pool of explicitly selected accounts, regardless of provider account type. Allocation is edited as one staged snapshot and committed atomically; it does not record internal transfers or expose an allocation timeline. At most one active goal may receive all remaining unallocated value, so balance growth (including investment growth) flows to it automatically. Goal creation keeps only a name and optional amount/date target; goal kinds, monthly plans, emergency formulas, Add Money/Withdraw, and the separate Record Purchase flow are retired. This supersedes the 2026-08-07 reserve-ledger interaction model; Goal Spend/Refund transaction types are the only spending attribution path.
- **2026-08-09** — Transaction classification is type-first. `Goal Spend` and `Goal Refund` require an explicitly selected active goal on the transaction or each split leg; goal balances derive directly from those signed transactions, and both types remain visible in account history while staying outside monthly Spending and Projections. `Reimbursement` is a direction-neutral high-level type whose outflow and repayment also stay outside monthly Spending and Projections. Persisted `forecastTreatmentRaw` field names remain unchanged for CloudKit compatibility, but unrecognized raw values fail closed and require review.
- **2026-08-09** — Spending groups are always visible; group hiding is retired. Unused canonical categories remain visible and manageable. Deleting a user group rechecks current state, moves every category copy to Unassigned, and removes every duplicate row for the logical group in one atomic save.
- **2026-08-09** — Investment contribution remains a high-level transaction type and is **not a category**. Spending derives a fixed, non-ordinary **Investment Contributions** reporting group directly from `.investmentContribution`; it never creates or assigns a canonical-category row for that type. Internal transfers, including transfers between savings accounts, are not Spending activity.
- **2026-08-07** — IA change: **Goals** becomes the fifth tab (Net Worth · Spending · Projections · Investments · Goals), superseding the four-tab decision and the 2026-08-02 plan's placement of sinking funds inside Spending. Goals are backed by a **reserve pool** of user-selected dedicated savings accounts (single-device assumption; Plaid-primary only). Money never moves by itself: contributions are confirm-first (suggested from confirmed internal transfers into reserve accounts), purchases are explicit per-transaction assignments capped by the transaction's *adjustable* (ordinary-spending) amount, and every ledger mutation flows through one validating service that keeps balances nonnegative and allocations within the pool. An account actively backing goals is **derived out of the Projections cash pool** (no override rows are written; the user's stored setting is preserved and restores on deselection). Goal-funded purchases move into a synthetic, non-headline **Goal Purchases** column in Spending — visible, but the Spent headline reads out-of-pocket only — and drill-downs display report-adjusted line amounts. The emergency-fund target originally derived from the median of complete-month **ordinary** Spending totals (excludes savings transfers, investment contributions, and goal purchases) × months × a reduction factor, adopted with hysteresis (nearest $100, ≥5% or ≥$250 moves); its median basis is superseded by the 2026-08-12 arithmetic-mean decision. The legacy sinking-fund record types remain purge-on-sight; four new durable record types store goals, ledger entries, reserve selections, and suggestion dismissals. Linked-category auto-drain is retired. Refund-into-goal UI, withdrawal suggestions, and swipe-action purchase marking are fast-follows.
- **2026-08-05** — Spending remains the product and navigation label, but its report answers the broader question “where did the money go?” Spending groups are entirely user-defined: the user creates groups and assigns individual categories; Networth seeds no destination names. YNAB group identities are reference metadata only and never become Spending columns or cleanup work. Assigned and Unassigned lists retain unused categories so the directory remains fully user-controlled. Credit-card payments and internal transfers remain excluded; investment contributions are type-derived information outside ordinary spending. Internal reporting roles are not exposed as user-facing controls.
- **2026-08-02** — IA change: the Accounts tab is replaced by **Spending** (Net Worth · Spending · Projections · Investments); Accounts moved behind an "All Accounts" card on Net Worth. Spending is a judgment-free awareness surface — per-category monthly spending with YNAB envelope "Available" imported read-only (per-month `budgeted/activity/balance` via the months endpoint, reversing the earlier no-budgeted-import stance at the user's explicit request) — plus Monarch-style opt-in sinking funds (save-to-spend vs keep-filled, linked-category drains, manual ledger). The interim "operating budget" model (income − fixed − necessities − surplus margin) was built, user-tested, and rejected the same day: the user does not budget with limits. No coaching copy anywhere on the surface.
- **2026-07-30** — Networth may expose an opt-in read-only financial snapshot to the user's Claude.ai account through a private remote MCP connector modeled on LiftLog. Enabling requires explicit consent; the app uploads full-replacement snapshots after successful saves and offers a manual sync. The encrypted Worker copy may include account labels/balances, effective manual assets, reconciled holdings, confirmed transaction dates/amounts/contacts/categories/splits, and aggregate net-worth history. It excludes credentials, provider IDs, account numbers/masks, notes, raw bank descriptions, unreviewed Plaid transactions, and the local IBR bridge. OAuth uses dynamic registration, PKCE, one-time 10-minute app codes, and revocable hashed access grants. Turning access off deletes the server snapshot and every grant before clearing the local opt-in.
- **2026-07-25** — Plaid Transactions replaces YNAB only for banking and credit-card data after a staged comparison. YNAB is the canonical migration source: Networth first imports stable payee/category/transaction/transfer IDs, builds editable durable contact and category directories, and preserves exact historical transaction decisions. Plaid identity evidence becomes many aliases pointing to those contacts; it is not itself a contact or a merchant-wide category rule. A one-way migration discards the prior review/rule output but preserves raw YNAB/Plaid caches, account mappings, and user-created categories. Historical matching uses exact account/amount constraints plus a maximum-cardinality assignment so one candidate cannot consume another row's only match. Hidden historical categories and exact split legs remain valid on their matched transactions. The PAT is removed only after contacts, categories, account mappings, historical import/reconciliation, and reviews are complete. Plaid recurring predictions and Transactions Refresh remain excluded. Transactions is subscription-billed per connected Item under the user's Plaid agreement; exact Production pricing is a manual gate.
- **2026-07-25** — Transaction approval remains manual after migration. Exact YNAB matches are already confirmed; uncertain history and every newly posted transaction require individual confirmation. Pending rows do not enter review. Confirmations attach Plaid aliases to an editable canonical contact and persist one transaction-specific decision. All confirmed decisions contribute future category evidence, but conflicting categories/treatments deliberately produce no preselection instead of a last-write-wins rule. Apple or optional privacy-bounded Claude inference may prefill, never approve. Card payments and internal transfers have no category. The picker uses the editable YNAB-seeded/Networth category directory, and splits remain transaction-specific.
- **2026-07-20** — Plaid runs against the free Production Trial through the existing private Worker and stable OAuth domain. Sandbox Items are removed before an environment switch because their access tokens cannot be used against Production. Duplicate reconciliation uses a dedicated source-selection sheet with source and balance context rather than a compact menu; selecting a duplicate never silently defaults to the first candidate. When one or more Plaid accounts match a manual asset, their supported live balances replace that asset's current contribution without overwriting its durable valuation history. The manual asset remains authoritative for classification because institutions can expose cash-like products through Plaid Investments; for example, a matched manual Other asset stays in Other Assets rather than moving to Investments. The manual value remains the fallback if the Plaid replacement becomes unavailable. Successful Plaid syncs persist one private-CloudKit balance point per contributing account per day; manual history supplies pre-link and post-unlink values, multiple matched accounts are summed without double-counting, and inactive end markers preserve linked history after an account is excluded or unlinked. This is an additive CloudKit model with defaulted fields and requires no legacy-field cleanup.
- **2026-07-19** — Plaid launched as optional and investment-only. YNAB continued to own cash balances, transactions, scheduled activity, and every projection input. The investment-specific reconciliation and token-security decisions remain active; the source limitation was superseded by the 2026-07-25 staged Transactions decision.
- **2026-07-19** — BL IBR is the sole source of truth for student-loan balances because those loans are not represented by the banking provider. IBR publishes only a minimal, versioned summary through an explicit local App Group opt-in. Networth reads but never writes it, counts the liability once, overlays dated balances locally instead of persisting them to CloudKit, and relies on Plaid checking activity for actual payment cash flow.
- **2026-07-19** — Linked IBR history begins automatically on the earliest cached YNAB transaction date unless the user overrides it locally. Before the first dated IBR balance, Networth estimates backward from the earliest snapshot using $0 payments and IBR's shared weighted rate as simple daily interest on principal. It floors accrued interest at zero, does not infer capitalization, and keeps every estimated balance out of CloudKit.
- **2026-07-19** — Net Worth is the default tab shown after launch and unlock. Projections remains the primary cash-decision workflow but is opened intentionally from the tab bar.
- **2026-07-19** — Investments is a portfolio reporting surface, not a placeholder: it combines investment-typed YNAB accounts with manual brokerage, retirement, and crypto balances; reports total value and 30-day movement; reconstructs historical balances from YNAB transactions and dated manual valuations; and exposes allocation plus holding details. Generic Other assets remain in Net Worth/Accounts rather than Investments.
- **2026-07-19** — Cash-confidence reporting distinguishes aggregate capacity from account liquidity. The main chart remains an aggregate selected-cash view, while known commitments are validated against their actual cash account so savings cannot mask a checking-account payment failure.
- **2026-07-19** — Net Worth is the long-term scorecard: current net worth and 30-day movement first, historical trend second, and a reconciled balance sheet third. Asset and liability categories drill into their contributing YNAB accounts and manual assets.
- **2026-07-19** — Accounts is the detailed inventory behind the scorecard. YNAB accounts use broad reconciled sections and report cleared/pending balances plus 30-day activity; manual assets open to value history and expose an explicit update action instead of editing immediately.
- **2026-07-19** — Safe to Spend means additional capacity now through the lowest point found across the full selected horizon, not a replacement for the monthly spending estimate. It is the lowest projected cash balance less the configured minimum buffer; the card names that low-point date as the actionable window.
- **2026-07-19** — Product north star clarified: the app is a private financial radar focused on near-term cash-flow confidence. Projections is the primary daily decision tool; net worth is the supporting long-term scorecard. Forecasts must be conservative, understandable, and explainable.
- **2026-06-05** — Initial Q&A locked: PAT, iPhone-only, personal-use, hybrid persistence, 4-tab Net Worth–first IA, Deep Slate theme, read-only YNAB integration with write-capable architecture, 90-day projection horizon.
- **2026-06-05** — Project identity locked: display name `BlueLava Networth`, bundle ID `com.bluelava.me.networth`, CloudKit container `iCloud.com.bluelava.me.networth`, iOS 26 minimum.
- **2026-06-05** — CC payment forecast: user-entered statement cycle day per card; algorithm = balance + scheduled charges − scheduled payments before close.
- **2026-06-05** — Manual asset cadence: monthly user-prompted updates, full value-history retained.
- **2026-06-06** — IA change: replaced the planned Settings tab with an Investments tab (placeholder for Plaid-fed holdings); Settings now opens from a sheet behind the Net Worth toolbar.
- **2026-06-06** — Face ID default flipped from off to on when the device supports biometrics; a versioned migration on `DurableUserSettings.settingsSchemaVersion` flips legacy persisted rows forward so iCloud-restored or cross-device settings never silently leave the user unlocked.
- **2026-06-07** — Historical net-worth backfill wired into the first successful sync. Reconstruction lives in `NetworthCore`, is invoked from `SyncCoordinator.runHistoryBackfillIfNeeded`, writes `.backfill`-stamped `DurableNetWorthSnapshot` rows, and is gated by `DurableUserSettings.historyBackfillVersion` (CloudKit-synced, re-runnable via `forceFullResync()`). Source-aware dedupe preserves `.live` rows (which include manual assets) over `.backfill` rows on collision.
