Status: active

# Networth Agent Guide

## Project Overview
- App name: `Networth`
- Platform: iOS 26+, iPhone only (no iPad, no Catalyst)
- Distribution: personal use only — sideload via Xcode / TestFlight, not App Store
- Main app target: `Networth`
- Unit test target: `NetworthTests` (Apple Testing framework, not XCTest)
- Xcode project: `Networth.xcodeproj` is the source of truth. Add files via Xcode's UI (drag into the navigator or "Add Files to Networth..."). No project-generation tooling.
- Core domain package: `NetworthCore/` (local SPM package — pure Swift, no UI)

## Purpose
Personal financial radar that helps the user understand their real financial position today and see cash problems before they happen. Its primary daily job is near-term cash-flow confidence: explain what money is leaving, when it leaves, and whether upcoming obligations are safely covered. Credit-card statement and autopay forecasting is the core differentiator. Net worth is the supporting long-term scorecard, not a proxy for spendable cash. Keep forecasts conservative, understandable, and explainable. Plaid is the sole external financial-data source; the optional BL IBR bridge remains local-only and read-only. YNAB is retired and must not appear in UI, make network requests, or influence classifications or reports. See `docs/PLAN.md` for the product north star, full scope, locked decisions, and phase plan.

## Repo Layout
- `Networth/`: app source — models, views, services, design system, app entrypoint
- `Networth/DesignSystem/`: design tokens (`Nw*`) and shared view components — built first, screens compose from primitives
- `NetworthTests/`: app-level tests (SwiftData / integration)
- `NetworthCore/`: SPM package — pure Swift domain logic (models, milliunit math, projection calculators, formatters, API DTOs)
- `PlaidWorker/`: independently deployed Cloudflare Worker — private Plaid credential/token boundary, encrypted Item registry, and normalized Investments API
- `Networth.xcodeproj/`: Xcode project and schemes
- `docs/`: PLAN.md (durable scope), WORKING.md (volatile session state), other long-lived notes

## Key App Behavior
- Single-user app gated by a Face ID toggle that defaults ON when the device supports biometrics. A versioned migration on `DurableUserSettings.settingsSchemaVersion` flips legacy persisted rows forward so iCloud-restored or cross-device settings never silently leave the user unlocked.
- On launch, `AppContainerController` (`@Observable`, `@Environment`-injected) provisions `SecretStore`, `BiometricGate`, the `PlaidClient` actor, `ModelContainer`, `ConnectivityMonitor`, the read-only `IBRLoanStore`, and local `IBRLoanHistorySettingsStore`.
- 4-tab structure: Spending · Projections · Goals · Net Worth. Investment reporting is reached through the separately scoped Investments and Retirement categories on Net Worth; account details are reached through Balance Sheet categories. Settings is opened from the shared top-right menu (not a tab).
- Sync strategy: SwiftData local cache for re-fetchable Plaid data; CloudKit private DB for durable data only (manual assets, daily net worth snapshots, user settings, account identity decisions, merchant rules, and transaction corrections).
- Optional IBR loan sharing uses `group.com.bluelava.me.financial`. The decoded summary stays in memory; its dated balances overlay the chart locally and must never be copied into SwiftData or CloudKit.
- User-entered credit-card payments are one-cycle private-CloudKit overrides
  keyed by card and statement close date. They replace both projected amount
  and payment date only for that cycle; future cycles remain estimated.
- Closed-statement estimates treat only explicit card-payment transactions as
  reducing the prior statement. Other post-close credits reduce the current
  balance only and are added back to the conservative payment estimate.

## Startup Checks
- At the start of work in a repo, review the global instructions exposed through
  `~/.claude/CLAUDE.md` (source of truth: `~/dotfiles/claude/AGENTS.md`) before relying
  on project-local notes or memory.
- At the start of work in a repo, verify live repo state before repeating claims from notes or memory:
  - Check current branch and worktree state with git.
  - Inspect actual files on disk before making file/layout/code-path claims.
  - Treat `docs/WORKING.md`, plans, and memory files as orientation aids, not authoritative current state.
  - If docs conflict with live repo state, trust the live state and explicitly call out the docs as stale.
- At the start of work in a repo, also check whether the `~/dotfiles` repo is up to date with its remote before relying on shared templates or instructions. If it is behind, call that out so the user can decide whether to update it.

## Build And Test Commands
```bash
# List available simulators (run this first to find a valid destination)
xcodebuild -showdestinations -scheme Networth 2>&1 | head -30

# Build (replace DESTINATION with a simulator from the list above)
xcodebuild -scheme Networth -destination 'DESTINATION' build

# Run app-level tests
xcodebuild test -scheme Networth -destination 'DESTINATION'

# Run pure-Swift domain tests (fast, no simulator)
cd NetworthCore && swift test

# Validate the Plaid backend without deploying it
cd PlaidWorker && npm test && npm run check
```
- Do not assume the unit test target name is the same as the runnable test scheme. Verify actual scheme names before running test commands.
- Prefer `swift test` on `NetworthCore` for iteration on domain logic — it is dramatically faster than the simulator round-trip.
- Simulator runs are unreliable in this workspace. Do not launch or test on an iOS Simulator unless the user explicitly asks; validate with `NetworthCore` tests plus generic-device Debug/Release builds instead.

## Coding Guidelines For Agents
- Prefer small, focused edits over broad refactors.
- Preserve existing SwiftUI and naming patterns.
- Keep business logic testable; prefer pure helpers for branching logic.
- Add or update XCTest coverage when changing logic in models/utilities.
- Avoid changing project settings/schemes unless the task explicitly requires it.
- Treat code as source of truth if legacy docs conflict.
- **Design system first.** If a visual pattern appears in 2+ places, promote it into `Networth/DesignSystem/` before the second use. All `Nw*` tokens and components live there.
- **No view models.** Follow the inventory-app pattern: views read `@Query` directly; logic lives in services and pure helpers (in `NetworthCore` when domain logic, in `Networth/Services/` when SwiftData-coupled).
- **Protocol-based DI** for any IO boundary: `SecretStore`, `BiometricGate`, `PlaidClient`, `SnapshotScheduler`, `IBRLoanStore`, `IBRLoanHistorySettingsStore`. Always ship an in-memory / recorded fake alongside the production implementation.
- **Milliunit math lives in `NetworthCore.Money`.** Never do `÷1000` in views.
- **YNAB is retired.** Do not add YNAB credentials, clients, endpoints, imports, caches, fallbacks, classification evidence, or user-facing copy. Compatibility-only persisted fields may remain inert when removal would risk SwiftData or CloudKit migration safety.
- **Retire completed migration tooling.** A one-time import or reconciliation flow must be removed from production UI and runtime after its task is complete; do not leave legacy providers hidden in submenus or active classifiers.

## Data Safety And Persistence Requirements
- Treat user data as durable product data, not temporary UI state.
- Prefer `safeSave(source:)` over `try? save()` — never silently swallow save failures.
- Prefer model-backed state for user-entered values; avoid keeping critical data only
  in transient `@State`.
- Persist writes promptly so data survives accidental app closes, backgrounding, or interruptions.
- Ensure create/edit flows save deterministically with explicit save points and error handling.
- Do not remove or weaken existing persistence logic unless explicitly requested.
- Handle persistence failures safely: preserve in-memory edits when possible and surface actionable errors instead of silently discarding data.
- Route logs through `OSLog` with `.private` annotations for user-derived values.
- Keep sensitive user data handling conservative: avoid unnecessary logging of user content and follow least-exposure patterns.
- Do not export, transmit, or paste user-derived data outside the local repo/tooling context unless explicitly requested by the user.
- If the project has third-party integrations, treat credentials as potentially write-capable and verify endpoints are read-only before adding or changing sync/import code unless the user explicitly allows write behavior.
- For persisted-model field renames/deletions, document expected CloudKit behavior and
  handle legacy-field cleanup/read paths intentionally.
- **Two persistence tiers — keep them separate:**
  - **Local SwiftData store** caches Plaid data. Disposable; can be re-fetched.
  - **CloudKit private DB store** holds irreplaceable user data: manual assets, daily net worth snapshots, user settings, projection configuration.
  - Do not mix the two stores. Retired-provider compatibility rows must never enter CloudKit.
- **Back up the resolved store location, not an assumed app-container path.** On the physical device, both active SwiftData stores currently resolve under `group.com.bluelava.me.financial`; similarly named files in the ordinary app container may be dormant legacy copies. Before any destructive migration, verify the live configuration URLs and copy the shared App Group as well as the app container.
- **BL IBR bridge is local-only and read-only.** Networth may decode the opt-in versioned App Group document but must not write to it, upload its fields, or generate a second projected loan payment. Plaid checking activity remains the cash-flow source for payments.
- **Plaid is server-mediated and read-only.** The app may receive Link tokens plus normalized investment and banking data from the private backend, but Plaid `client_id`, `secret`, and Item `access_token` values must never enter the app, Keychain, logs, fixtures, or repository. Investments remain on their dedicated reconciliation path; Transactions is the sole banking and card transaction source.
- **Plaid Transactions does not use Plaid recurring predictions.** Sync only through `/transactions/sync`; do not add `/transactions/refresh` or `/transactions/recurring/get` without a new product/cost decision.
- **Transaction inference is layered and privacy-bounded.** Apply confirmed local merchant rules first, then Apple on-device inference. Claude fallback is opt-in and may receive only transaction description, merchant/counterparty, Plaid category, payment channel, and direction—never amount, date, balance, account identifiers, or transaction history.
- **Plaid Worker secrets never enter git.** Use `.dev.vars` locally and `wrangler secret put` when deployed. Item access tokens must be AES-GCM encrypted before Workers KV persistence; the encryption key is a separate Worker secret.
- **Plaid balances require review before inclusion.** A newly linked investment account remains excluded from Net Worth until the user confirms whether it is separate, already represented by a manual asset, or intentionally excluded. Account balances reconcile totals; holdings explain their composition and must not be added again.
- **Account nicknames are durable display overrides.** Key them by Plaid
  account ID in the private CloudKit store; never overwrite the disposable
  provider cache name. User-facing account labels resolve the nickname first,
  while detail and reset flows preserve the imported name.
- **Spending account pins are durable preferences, not balance records.** Store
  only the canonical account ID, visibility decision, and display order in the
  private CloudKit store; current and available balances remain in the local
  Plaid cache. Spending may show at most four eligible cash or credit accounts.
  Use the explicit `Show on Spending` toggle rather than a star or other
  ambiguous favorite symbol.
- **IBR history overrides are presentation-only.** With no override, linked-loan history begins on the earliest cached Plaid transaction date. A user-selected replacement date stays in local preferences. Before IBR's first dated balance, estimate backward from the earliest snapshot using $0 payments and IBR's shared weighted rate as simple daily interest on principal. Never persist the estimated balances or infer capitalization events.

## UX And Design Consistency Requirements
- Match the visual and interaction style already established across views.
- Prefer large, readable typography and high-clarity layout hierarchy.
- Keep calls to action obvious and prominent. Use concise copy.
- Minimize non-essential on-screen text and keep interfaces focused on primary tasks.
- Avoid emojis and unfamiliar symbols as carriers of meaning. Do not rely on
  icon-only status indicators: different users may interpret them differently.
  Prefer concise visible language or self-evident visual relationships. Reserve
  standalone icons for established system controls, and always provide an
  accessibility label.
- Do not add explanatory or instructional sentences to UI by default. Prefer
  self-explanatory labels and controls; if a choice needs prose to be
  understood, redesign the interaction. Ask before making an exception.
- Before applying a cross-screen UX consistency choice when multiple valid
  patterns exist, discuss the recommendation and tradeoff with the user before
  implementing it.
- Reuse established spacing, component patterns, and tone from existing core views when adding new screens/components.
- Prefer icon-based close/confirm controls where appropriate: red `xmark.circle.fill` for close/cancel and green `checkmark.circle.fill` for confirm/done.
- Use the right confirmation surface for the context:
  - System `.alert()` for simple destructive confirms and info-only dialogs.
  - Custom confirmation sheets for positive/completion actions and dialogs with text input.
  - `.confirmationDialog()` for multi-option pickers with 3+ actions.
- For numeric entry fields, first numeric tap should replace existing value by default.
- Currency fields use the shared staged numeric-entry sheet: payment-terminal
  cent shifting, Clear in the lower-left keypad position, backspace in the
  lower-right, and explicit Cancel/Done actions. Do not attach dismissal
  controls to the system keyboard for currency entry.
- For controls that invalidate multi-year chart calculations, stage edits locally and commit with an explicit Apply action instead of recalculating on every picker change.
- For high-frequency actions, prefer always-visible large tap targets over hidden menus.
- For list-row management actions, prefer swipe actions.
- Treat long-press menus as optional secondary access, not the primary path for common actions.
- For lightweight date fields in sheets/cards, prefer native compact date/time pickers and keep scheduling editing patterns consistent across create/edit flows.
- When a date is optional, prefer a clear inline empty state like `Select Date`.
- For any tappable list/card row, ensure whitespace taps trigger reliably by using a full-row tap area helper or equivalent content shape.
- For visual tweaks, keep changes scoped to shared component files first so all entry
  points stay consistent.
- Prefer design-system tokens and shared UI helpers over inline styling; if a visual pattern appears in 2+ places, promote it into the design system first.
- When adding metadata that appears in multiple views, prefer a shared display component so surfaces stay aligned automatically.
- History views should reuse the same entry display formatting used in logging/detail screens so wording, units, and layout stay consistent.
- Avoid duplicating cross-cutting helpers across views; prefer one shared utility so
  fixes apply globally.
- **Theme:** "Deep Slate" — the primary navy (`#003E83`), parchment
  (`#EBD999`), olive (`#505423`), and rust (`#A93400`) derive from the third
  combination in the sixth row of page 11 of the local Sanzo Wada reference.
  Navy means brand, interaction, and informational/on-track progress; olive
  means protected or allocated money; parchment highlights protected or
  reallocated money and supplies the warm planning surface; green means an
  actual favorable outcome such as Retained or an inflow; a derived amber
  (`#9A5700`) means watch; and rust means liability/at-risk. Defined in
  `NwAppColors`. Brand and semantic colors must use adaptive light/dark
  definitions there; never use a fixed navy as an interactive foreground in
  dark mode.
- **Depth:** Keep financial content on solid, legible surfaces. Heroes use the
  strongest elevation, standalone tappable cards use moderate elevation, and
  repeated peer rows share one grouped surface with internal dividers. Do not
  apply custom Liquid Glass to content cards or segmented planning controls,
  and do not add decorative moving screen backgrounds. System navigation and
  controls may retain the platform's native glass treatment.
- The BlueLava launch/lock gradient is a shared cross-app brand treatment, not
  part of Networth's screen palette. Do not change it during Networth palette
  work without explicit user approval.
- For palette planning, consult `docs/2026-08-21-color-planning-reference.md`
  and its local Sanzo Wada PDF before introducing unrelated hues. Sample exact
  swatches from a rendered page, then adapt them in `NwAppColors` for semantic
  meaning, contrast, and light/dark appearance.
- **Currency display:** never show raw milliunits. Always route through `NetworthCore.Money` formatters. Hide cents where the design calls for compact metrics; show full precision in detail rows.
- **Information architecture is fixed at 4 tabs:** Spending · Projections · Goals · Net Worth. Spending is the initial tab. Investments moved beneath Net Worth by scope decision 2026-08-14; its reporting remains available by opening the Investments Balance Sheet category. Accounts remain Balance Sheet drill-downs rather than a tab. Settings opens from the shared top-right menu (not a tab). Do not add or restore tabs without a scope decision logged in `docs/PLAN.md`.
- **No privacy/blur mode** in v1 (explicitly scoped out).
- **No transactions tab** in v1 (explicitly scoped out — transaction browsing stays in account and Spending drill-downs).
- **Spending budgets are group-level guidance only.** A user may opt any
  existing Spending group into a repeating monthly target and explicitly
  feature one group. Months never carry over, category-level budgets and
  projected finishes are excluded. Once all funded money is assigned through
  the automatic-remainder group, Retained is derived from the reconciled
  remaining monthly budget balances rather than calculated independently from
  raw transactions. Each Reserve assignment reduces its selected source budget
  and therefore Retained exactly once; a Reserve may receive multiple
  independently editable assignments in one month, including from different
  groups. Reserve management uses the month selected on Spending: new
  assignments belong to that month, while an existing assignment always keeps
  its original month when edited. Historical changes revise that month's
  budget and carry the resulting balance forward. A later Reserve- or
  Goal-funded purchase drains only that earmark and stays outside monthly
  budgets and Retained.
  Reserve lifecycle actions are intentionally distinct: Archive removes a
  Reserve from active planning but preserves its complete ledger in the
  user-visible Archived Reserves area, where it can be reviewed or restored.
  Delete permanently removes the Reserve plus every associated assignment and
  purchase-link record, but never removes or rewrites imported transactions.
  The aggregate Spending card shows up to three parchment Reserve columns
  on one shared balance scale, ranked by nearest due date, then highest
  percentage complete, then largest saved balance. Targeted Reserves add a
  subtle target outline; open-ended Reserves show only their saved balance.
  Historical averages belong in Spending Trends, not the main monthly budget
  summary. Factual calendar pace may compare
  percent used with percent of the current month elapsed, but the Spending
  overview does not encode that pace with brown/amber or pale-yellow status
  treatments. Under-budget progress is blue, overspending is a clear
  Wada-family red, positive Retained is green, and negative Retained is red.
  Pace remains available in the tapped detail. Never extrapolate that
  comparison into a projected finish.
- **Carried Spending Reserves are protected cash, not a bank balance change.**
  Projections keeps the cash curve and per-account warnings on real balances,
  but Safe to Spend and tight-status calculations protect the aggregate active
  Reserve balance in addition to the configured cash buffer. The Spending Room
  reconciliation shows Reserves separately. Confirmed Reserve-funded whole
  transactions and split lines are excluded from historical expected-spending
  estimates so assigning and later using the earmark never creates a second
  deduction. Future Reserve plans are not projected before explicit assignment.
- **Savings is a designated budget group, not ordinary spending.** Its
  repeating target behaves like every other group target, it contains no
  ordinary categories, and new actual progress comes only from an explicit
  `Savings` type on the outgoing budgeted-cash transaction or split line. The
  receiving deposit remains an Internal transfer. Savings requires a budget
  month, reduces that month's Savings remaining and Retained, and stays outside
  ordinary-spending totals, trends, and historical projection-spending
  estimates. A savings-choice entry reallocates the selected month only from
  another budget group into Savings, preserving the total budget and never
  creating a bank transaction. A posted transfer may be assigned to any still-
  outstanding prior month or its posted month for presentation, but its real
  transaction date, balances, and projection timing never change. Previously
  month-assigned receiving deposits remain grandfathered; do not revive broad
  savings-account inference.

## Validation Checklist
- App target builds.
- Relevant tests pass (if applicable).
- For security, persistence, or `#if DEBUG` guard changes, verify both Debug and
  Release builds.
- No accidental changes to unrelated files.
- Avoid running full build/test suites unless the change has meaningful breakage risk, but always run at least a build for security, persistence, model/schema, startup, or configuration changes.

## Agent Collaboration Rules
- Keep `AGENTS.md` as the canonical local instruction file. Expose `CLAUDE.md` as a
  symlink to `AGENTS.md` so the repo has one source of truth.
- Before implementing, ask clarifying questions whenever requirements are ambiguous.
- Keep communication concise and audience-appropriate: non-technical by default, but include technical detail for audits, debugging, migrations, and security reviews.
- Give the user only one step at a time when providing action items or instructions.
- Do not provide detailed implementation walkthroughs in routine updates.
- Summarize completed work using short bullet-point highlights only.
- After making changes, call out key in-app areas the user should review or test.
- During work, propose useful new `AGENTS.md` instructions that could improve future speed and consistency.
- If removing or replacing a UI surface, remove obsolete view state, selection state, and navigation logic in the same pass so code stays aligned with the product.
<!-- Add project-specific collaboration rules. -->

## Notes
- Reference apps in sibling directories — `~/projects/inventory-app` (architecture model) and `~/projects/WorkoutApp` (design-system model). Their `Lift*` token/component naming is the direct template for our `Nw*` system.
