# PLAN

## Project
- **Display name:** `BlueLava Networth`
- **Module / Xcode target:** `Networth`
- **Bundle ID:** `com.bluelava.me.networth`
- **Tests bundle ID:** `com.bluelava.me.networthTests`
- **CloudKit container:** `iCloud.com.bluelava.me.networth` (private DB only)
- **Minimum iOS:** 26
- **Purpose:** Personal iPhone app that augments YNAB with net worth tracking, manual asset entry, and forward-looking financial projections — especially credit card payment forecasts.
- **Audience:** Single user (the project owner). Personal use only, not distributed.

## Distribution & Scope
- iPhone only (no iPad, no Catalyst).
- Sideload via Xcode / TestFlight. No App Store submission planned.
- YNAB is the only external data source. App is read-only against YNAB.

## Locked Decisions

### Authentication
- **YNAB Personal Access Token (PAT)** entered once by the user.
- Stored in **iCloud-synced Keychain** (`kSecAttrAccessibleWhenUnlocked` + `kSecAttrSynchronizable: true`).
- API client abstracted so OAuth + write endpoints can be added later without rewriting call sites.
- **Optional Face ID gate, off by default**, user toggle in Settings.

### Data Model
- **Net worth =** sum of YNAB account balances (assets − liabilities) **plus manual assets**.
- Manual asset types: real estate, vehicles, brokerage/retirement balances, crypto, collectibles.
- Investment accounts handled as **manual balance entries** (no per-symbol positions, no live prices in v1).

### Persistence (Hybrid)
- **SwiftData (local-only):** cache of YNAB data — accounts, transactions, scheduled transactions, categories. Re-fetchable, no CloudKit cost.
- **SwiftData + CloudKit (private DB):** durable user data —
  - Manual assets and their balance history
  - Daily net worth snapshots
  - User settings, projection configuration, Face ID toggle
- Daily net worth snapshot job runs once per day.

### Historical Net Worth
- On first sync, **reconstruct 24 months** of YNAB account balances day-by-day from transaction history.
- Manual assets snapshot **forward only** from install date.
- Snapshots persisted via CloudKit so history survives device wipes.

### Projections
**Must-have (v1):**
- Upcoming **credit card payment forecast** — for each CC account, project next statement balance (full / minimum / custom payoff scenarios) based on activity since last statement + scheduled transactions.

**Nice-to-have (v1 if cheap, else v1.1):**
- End-of-month cash position (aggregate checking/savings).
- Payday-to-bill alerts ("on March 15 your checking dips to $230").
- Category burn-down forecast ("Groceries will overspend by $120").

**Skipped:** Per-account 90-day running balance chart.

- **Projection horizon:** 90 days.
- **Read-only:** projections computed locally; we do NOT write forecast transactions back to YNAB. Architecture leaves the door open.

### CC Payment Forecast Algorithm (v1 spec)
**Inputs per card (cached from YNAB + Settings):**
- Current balance.
- Statement cycle day — **user-entered per card** in Settings (one-time setup, editable).
- Scheduled transactions on the card account.
- User-set minimum-payment params per card: percent (default 2%) and floor (default $25).

**Outputs per card:**
- **Statement balance projection** = current balance + Σ(scheduled charges before next close date) − Σ(scheduled payments before next close date).
- **Minimum payment** = max(floor, percent × statement balance projection).
- **Payoff scenarios** — full / minimum / custom amount; show resulting carryover. Interest impact deferred to v1.1.

**Algorithm lives in `NetworthCore.Projections.CCPaymentForecaster`** — pure Swift, fully unit-tested with `swift test`.

### Manual Asset Cadence
- **Monthly user-prompted updates.** App prompts on the 1st of each month to refresh values for any manual asset not edited in the past 30 days.
- Each manual asset stores a value-history series (one entry per edit, timestamped).
- Charts render at monthly resolution for individual assets.
- The **rolled-up net worth total snapshots daily**, using the last known manual-asset values between updates.

### Information Architecture
- **4-tab structure:**
  1. **Net Worth** — current total, historical chart, breakdown by account type, manual assets list.
  2. **Projections** — credit card payment cards, cash position, alerts, burn-downs.
  3. **Accounts** — YNAB accounts + manual assets, drill-down to balance and recent activity.
  4. **Settings** — token entry, Face ID toggle, sync controls, manual asset CRUD.
- No transactions tab; users open YNAB if they need to browse transactions.
- No privacy mode (tap-to-blur amounts) in v1.

### Design Language
- **Theme:** "Deep Slate" — navy/teal accent (≈ `#1E3A8A` primary, teal for positive deltas, muted red for liabilities/regressions).
- Modeled on WorkoutApp's design-system patterns (`Lift*` token enums, card variants, modal scaffolds).
- Design system **built first**, screens assembled from primitives.

## Architecture Patterns (from inventory-app + WorkoutApp)
- **SwiftUI + SwiftData**, `@Observable` for app-wide state container.
- **No view models.** Logic lives in services + pure helpers; views read `@Query` directly.
- **Protocol-based DI** for testable boundaries:
  - `SecretStore` (Keychain) — production + in-memory fake.
  - `BiometricGate` (LAContext wrapper).
  - `YNABClient` (actor-isolated networking) — production + recorded-response fake.
- **`safeSave(source:)`** on `ModelContext` — never silently swallow save failures; posts notifications for global alert handling.
- **Separate SPM package** for pure domain logic (`NetworthCore`): models, milliunit math, projection calculators, formatters. No SwiftUI / SwiftData imports. Enables fast `swift test` runs.
- **Apple Testing framework** (`@Suite`, `@Test`, `#expect`) — not XCTest.
- **Actor-isolated YNAB client** for thread-safe token access and rate-limit bookkeeping.
- **Delta sync** via `last_knowledge_of_server` on supported endpoints (9 endpoints) to stay under 200 req/hour.

## Design System (built first)
Modeled directly on WorkoutApp's `Lift*` system, prefixed `Nw*`:
- **Tokens:** `NwSpacing`, `NwCornerRadius`, `NwTypography`, `NwShadow`, `NwOpacity`, `NwStrokeWidth`.
- **Colors:** `NwAppColors` — semantic (`positive`, `caution`, `liability`), neutral base, theme accent.
- **Card variants:** primary, secondary, glass, inset (via `.nwCardStyle(...)` modifier).
- **Buttons:** primary, secondary, tinted, destructive.
- **Reusable views:** `NwCard`, `NwSectionHeader`, `NwMetricCapsule`, `NwStatusBadge`, `NwEmptyState`, `NwLoadingState`, `NwInlineNotice`, `NwBanner`, `NwModalLayout`.
- **Iconography:** SF Symbols only, mapped via `NwIcon` enum.

## YNAB API Notes
- Base URL: `https://api.ynab.com/v1`
- Rate limit: **200 req/hour** rolling — must respect; build in client-side throttle + delta sync.
- All amounts in **milliunits** (`÷1000` for display). Use `..._formatted` / `..._currency` fields where available.
- Dates: ISO 8601 UTC.
- `since_date` defaults to 1 year ago — pass explicit dates for full history reconstruction.
- Endpoints we read: budgets, accounts, categories, transactions, scheduled_transactions, payees, months.

## Phases
- [ ] **Phase 0 — Bootstrap:** Xcode project, SPM `NetworthCore` package, design-system token files (`Nw*`).
- [ ] **Phase 1 — Auth + sync:** Settings screen, PAT entry, Keychain storage, YNAB client, initial budget/account fetch, SwiftData cache.
- [ ] **Phase 2 — Net Worth tab:** Current total, account breakdown, 24-month historical reconstruction, daily snapshot job.
- [ ] **Phase 3 — Manual Assets:** CRUD UI, CloudKit sync, integration into net worth total.
- [ ] **Phase 4 — Projections tab:** Credit card payment forecasts (must-have), then cash position / alerts / burn-downs.
- [ ] **Phase 5 — Accounts tab:** List + drill-down, recent activity (read-only from cache).
- [ ] **Phase 6 — Polish:** Face ID toggle, error states, empty states, splash/onboarding, sync indicators.

## Key Decisions Log
- **2026-06-05** — Initial Q&A locked: PAT, iPhone-only, personal-use, hybrid persistence, 4-tab Net Worth–first IA, Deep Slate theme, read-only YNAB integration with write-capable architecture, 90-day projection horizon.
- **2026-06-05** — Project identity locked: display name `BlueLava Networth`, bundle ID `com.bluelava.me.networth`, CloudKit container `iCloud.com.bluelava.me.networth`, iOS 26 minimum.
- **2026-06-05** — CC payment forecast: user-entered statement cycle day per card; algorithm = balance + scheduled charges − scheduled payments before close.
- **2026-06-05** — Manual asset cadence: monthly user-prompted updates, full value-history retained.
