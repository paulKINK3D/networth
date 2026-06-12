# Networth Agent Guide

## Project Overview
- App name: `Networth`
- Platform: iOS 18+, iPhone only (no iPad, no Catalyst)
- Distribution: personal use only — sideload via Xcode / TestFlight, not App Store
- Main app target: `Networth`
- Unit test target: `NetworthTests` (Apple Testing framework, not XCTest)
- Xcode project: `Networth.xcodeproj` is the source of truth. Add files via Xcode's UI (drag into the navigator or "Add Files to Networth..."). No project-generation tooling.
- Core domain package: `NetworthCore/` (local SPM package — pure Swift, no UI)

## Purpose
Personal iPhone app that augments YNAB with net worth tracking (YNAB accounts + manual assets), a 5-year historical net worth chart, and forward-looking financial projections — primary differentiator is credit card payment forecasting. Read-only against YNAB. See `docs/PLAN.md` for the full scope, locked decisions, and phase plan.

## Repo Layout
- `Networth/`: app source — models, views, services, design system, app entrypoint
- `Networth/DesignSystem/`: design tokens (`Nw*`) and shared view components — built first, screens compose from primitives
- `NetworthTests/`: app-level tests (SwiftData / integration)
- `NetworthCore/`: SPM package — pure Swift domain logic (models, milliunit math, projection calculators, formatters, API DTOs)
- `Networth.xcodeproj/`: Xcode project and schemes
- `docs/`: PLAN.md (durable scope), WORKING.md (volatile session state), other long-lived notes

## Key App Behavior
- Single-user app gated by a Face ID toggle that defaults ON when the device supports biometrics. A versioned migration on `DurableUserSettings.settingsSchemaVersion` flips legacy persisted rows forward so iCloud-restored or cross-device settings never silently leave the user unlocked.
- YNAB Personal Access Token entered once in Settings, stored in iCloud-synced Keychain so a future device swap is zero-friction.
- On launch, `AppContainerController` (`@Observable`, `@Environment`-injected) provisions `SecretStore`, `BiometricGate`, `YNABClient` (actor), `ModelContainer`, `ConnectivityMonitor`.
- 4-tab structure: Net Worth · Projections · Accounts · Investments. Settings is opened from a sheet behind the Net Worth toolbar (not a tab).
- Sync strategy: SwiftData local cache for YNAB data (re-fetchable); CloudKit private DB for durable data only (manual assets, daily net worth snapshots, user settings).

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
```
- Do not assume the unit test target name is the same as the runnable test scheme. Verify actual scheme names before running test commands.
- Prefer `swift test` on `NetworthCore` for iteration on domain logic — it is dramatically faster than the simulator round-trip.

## Coding Guidelines For Agents
- Prefer small, focused edits over broad refactors.
- Preserve existing SwiftUI and naming patterns.
- Keep business logic testable; prefer pure helpers for branching logic.
- Add or update XCTest coverage when changing logic in models/utilities.
- Avoid changing project settings/schemes unless the task explicitly requires it.
- Treat code as source of truth if legacy docs conflict.
- **Design system first.** If a visual pattern appears in 2+ places, promote it into `Networth/DesignSystem/` before the second use. All `Nw*` tokens and components live there.
- **No view models.** Follow the inventory-app pattern: views read `@Query` directly; logic lives in services and pure helpers (in `NetworthCore` when domain logic, in `Networth/Services/` when SwiftData-coupled).
- **Protocol-based DI** for any IO boundary: `SecretStore`, `BiometricGate`, `YNABClient`, `SnapshotScheduler`. Always ship an in-memory / recorded fake alongside the production implementation.
- **Actor-isolate the YNAB client** for thread-safe token access and rate-limit bookkeeping.
- **Milliunit math lives in `NetworthCore.Money`.** Never do `÷1000` in views. Prefer `..._formatted` / `..._currency` fields from YNAB when present.
- **Delta sync (`last_knowledge_of_server`) on supported endpoints** to stay well under YNAB's 200 req/hour limit.
- **Read-only against YNAB in v1.** Do not add any POST/PATCH/DELETE call sites; the client should expose only read methods publicly.

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
  - **Local SwiftData store** caches YNAB data (accounts, transactions, scheduled transactions, categories). Disposable; can be re-fetched.
  - **CloudKit private DB store** holds irreplaceable user data: manual assets, daily net worth snapshots, user settings, projection configuration.
  - Do not mix the two stores. Do not put cached YNAB data in CloudKit.
- **YNAB PAT is high-sensitivity.** Store via the `SecretStore` protocol backed by iCloud-synced Keychain (`kSecAttrAccessibleWhenUnlocked` + `kSecAttrSynchronizable: true`). Never log token values, never write them to SwiftData, never include them in diagnostic exports.
- **YNAB API is read-only in v1.** This is a security posture: even if the token had write scope, the client must not expose write endpoints. Future write support requires explicit user approval and a separate review.

## UX And Design Consistency Requirements
- Match the visual and interaction style already established across views.
- Prefer large, readable typography and high-clarity layout hierarchy.
- Keep calls to action obvious and prominent. Use concise copy.
- Minimize non-essential on-screen text and keep interfaces focused on primary tasks.
- Reuse established spacing, component patterns, and tone from existing core views when adding new screens/components.
- Prefer icon-based close/confirm controls where appropriate: red `xmark.circle.fill` for close/cancel and green `checkmark.circle.fill` for confirm/done.
- Use the right confirmation surface for the context:
  - System `.alert()` for simple destructive confirms and info-only dialogs.
  - Custom confirmation sheets for positive/completion actions and dialogs with text input.
  - `.confirmationDialog()` for multi-option pickers with 3+ actions.
- For numeric entry fields, first numeric tap should replace existing value by default.
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
- **Theme:** "Deep Slate" — navy/teal accent (`#1E3A8A` family); teal for positive deltas, muted red for liabilities/regressions. Defined in `NwAppColors`.
- **Currency display:** never show raw milliunits. Always route through `NetworthCore.Money` formatters. Hide cents where the design calls for compact metrics; show full precision in detail rows.
- **Information architecture is fixed at 4 tabs:** Net Worth · Projections · Accounts · Investments. Settings is opened from a sheet behind the Net Worth toolbar (not a tab). Do not add tabs without a scope decision logged in `docs/PLAN.md`.
- **No privacy/blur mode** in v1 (explicitly scoped out).
- **No transactions tab** in v1 (explicitly scoped out — users open YNAB to browse transactions).

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
- YNAB API quirks worth re-reading before any networking change: 200 req/hr rolling rate limit, milliunit amounts, `since_date` defaults to one year ago (pass explicit dates for history reconstruction), delta sync via `last_knowledge_of_server` on 9 endpoints.
