# Plan — Resolve review findings (doc drift + historical backfill)

## Context

An independent review of the codebase against `docs/PLAN.md` and `AGENTS.md`/`CLAUDE.md` surfaced five findings:

1. **IA drift (High).** Plan locks tabs as Net Worth · Projections · Accounts · Settings; the app ships Net Worth · Projections · Accounts · Investments with Settings opened from a toolbar sheet.
2. **Face ID default drift (High).** Plan says biometric is off by default; `DurableUserSettings.faceIDEnabled` defaults to `true` and a bootstrap migration flips existing installs to `true` when biometrics are available.
3. **24-month historical reconstruction never wired (Medium).** `AccountHistoryReconstructor` + `NetWorthHistoryAggregator` exist in `NetworthCore` and are tested, but no caller invokes them. The Net Worth chart only grows from install date forward, breaking the promise in `PLAN.md:39-42`.
4. **Stale planning docs.** `PLAN.md` phase checkboxes are unchecked while `WORKING.md` says "all phases shipped." `AGENTS.md`/`CLAUDE.md` still say the Xcode project doesn't exist. `WORKING.md` lists Settings as a tab and claims the 1024 PNG icon is missing — both false today.
5. **Project guide IA constraint also stale.** `AGENTS.md` says the four-tab IA is fixed at NW/Projections/Accounts/Settings; needs to match shipped IA so future agents don't try to "fix" the Investments tab.

User decisions captured before drafting:
- **Keep current 4-tab IA** (Net Worth · Projections · Accounts · Investments, Settings as a NW-toolbar sheet) and ratify it in the plan.
- **Keep Face ID default ON** when biometrics are available, and **keep the one-time migration in place** to protect against an older `DurableUserSettings` row arriving via iCloud restore.
- **Wire the historical reconstruction in this plan** rather than punting it. Anchor idempotence in CloudKit-synced durable state (not the disposable local cache) and add a small self-healing dedupe pass for the case where CloudKit hydration races with the backfill.
- **Scope to the actual app:** sideloaded, single user, iPhone-only, single YNAB budget in practice. Defensive engineering against multi-device CloudKit hydration races and multi-budget state churn is intentionally out of scope. If either of those assumptions changes, revisit before adding bank-link or shared-iCloud features.

Outcome: docs match shipped reality, biometric default is intentional and documented (with the legacy-settings safety net preserved), and the Net Worth chart actually shows up to 24 months of history after the first sync. Duplicate-day defenses are present at the write paths; the system is not engineered for arbitrary post-write CloudKit hydration races.

## Approach

### 1. Wire historical net-worth backfill into first sync

**Where it runs.** Add a new private method `runHistoryBackfillIfNeeded(budgetId:)` on `SyncCoordinator` (`Networth/Services/SyncCoordinator.swift`). Call it from `syncAll(budgetId:)` immediately after the Transactions phase completes successfully, before the cache save.

**Idempotence guard.** Add a `historyBackfillVersion: Int = 0` field to `DurableUserSettings` (the CloudKit-backed singleton). Run the backfill only when `historyBackfillVersion < 1`; set it to `1` on success. The marker must live in durable, iCloud-synced storage — not in the disposable `SyncCursor` cache — so the gate stays consistent across device restores and app reinstalls. Bumping the constant later lets us trigger a one-shot re-backfill if the algorithm changes.

**Backfill algorithm.** Inside the method:
1. Fetch all `CachedAccount` rows for `budgetId` where `!deleted` (closed accounts kept — they had non-zero balances earlier in the window).
2. For each account, fetch its `CachedTransaction` rows, map via `toSummary()`, and call `AccountHistoryReconstructor().reconstruct(currentBalance:transactions:from:to:)` with `from = 24 months ago, to = today`. `NetworthCore/Sources/Projections/HistoricalNetWorth.swift:27` is the entry point.
3. Build `[String: [DailyBalance]]` keyed by account ID and `[String: AccountKind]` keyed by account ID using `CachedAccount.kind`.
4. Call `NetWorthHistoryAggregator().aggregate(dailyBalancesByAccount:kindsById:manualAssetSeries:)` with an empty `manualAssetSeries` (manual assets snapshot forward-only per plan).
5. Bulk-insert `DurableNetWorthSnapshot` rows into `durableContext` with `source = .backfill`. Skip any day where a `.live` row already exists; within the run, skip days already covered by another backfill row from this pass.
6. Run `dedupeSnapshotsForDuplicateDays()` once at the end of the method.
7. `durableContext.safeSave(source: "sync.backfill")`, then set `historyBackfillVersion = 1` and `durableContext.safeSave(source: "sync.backfill.marker")`. Any thrown error before the marker save leaves it at `0` and the next sync retries.

**Phase reporting.** Add a `phase = .syncing(label: "Reconstructing history")` line before the backfill so the sync HUD reflects the (potentially multi-second) work.

**Snapshot dedupe (defense-in-depth).** `DurableNetWorthSnapshot` cannot carry `@Attribute(.unique)` (CloudKit forbids it), so schema-level uniqueness on `date` is impossible. Two changes make conflicts semantically resolvable:
- **Add `sourceRaw: String = "live"` and `createdAt: Date = .now` fields to `DurableNetWorthSnapshot`.** Source cases: `.live` (written by `SnapshotScheduler.recordIfNeeded`, includes manual assets) and `.backfill` (written by reconstruction, excludes manual assets because their history doesn't extend that far back). `createdAt` records first-write time per device.
- **Source-aware dedupe rule.** Add `dedupeSnapshotsForDuplicateDays()` on `SnapshotScheduler`. For each duplicate day, keep `.live` over `.backfill`; if multiple of the same source, keep the highest `createdAt`; fall back to lowest UUID only when both source and createdAt tie. Call it at the end of `runHistoryBackfillIfNeeded` and at the end of `recordIfNeeded`.

The durable marker prevents unnecessary work; the per-day pre-insert skip prevents most duplicates within a single run; the source-aware dedupe pass guarantees that when duplicates do occur the more authoritative row survives. Coverage of post-write CloudKit hydration races is intentionally out of scope (see Context).

**Re-trigger.** Update `forceFullResync()` on `AppContainerController` to also reset `DurableUserSettings.historyBackfillVersion = 0` (it already clears all local `SyncCursor` rows). The next sync redoes the reconstruction; the dedupe pass ensures the second run merges cleanly with any snapshots already present.

### 2. Keep the Face ID bootstrap migration in place

The original draft of this plan called for deleting the `settingsSchemaVersion < 2` migration block in `Networth/AppContainer/AppContainerController.swift:70-76`. **Do not delete it.**

The migration is the only thing protecting against a future iCloud restore (or a second device coming online) that surfaces an older `DurableUserSettings` row with `settingsSchemaVersion < 2` and `faceIDEnabled = false`. Without the migration, that row would silently leave the device unlocked while every doc claims biometrics default on. The migration cost on a steady-state install is one predicate check per bootstrap — effectively free — and it preserves the safety net for restores and cross-device skew.

**Code change in this section: none.** The doc-refresh work in Section 3 still applies: the planning docs must describe Face ID as on-by-default and explicitly note that `settingsSchemaVersion` exists to migrate legacy persisted rows into that default.

### 3. Refresh planning docs to match shipped reality

**`docs/PLAN.md` edits:**
- Authentication section (lines 20-25): change "Optional Face ID gate, off by default" to "Face ID gate enabled by default when the device supports biometrics; user can disable in Settings. A versioned migration on `DurableUserSettings.settingsSchemaVersion` flips legacy persisted rows (from before the default change) to the new default on bootstrap, so iCloud-restored or cross-device settings do not silently leave the user unlocked."
- Information Architecture section (lines 78-86): update the four tabs to `Net Worth · Projections · Accounts · Investments`. Add a bullet noting Settings is opened from a sheet on the Net Worth toolbar. Add an Investments-tab bullet describing current scope (placeholder for Plaid-fed holdings + manual investment assets).
- Projections section: add a sub-bullet noting the v1 forecaster now also estimates variable spend from a configurable historical lookback, and supports per-category hide/exclude lists (`DurableExcludedSpendCategory`).
- Phases (lines 122-129): tick all six checkboxes. Add a closing line: "All initial phases shipped. Next initiative: Plaid integration — see `docs/2026-06-06-plaid-integration-research.md`."
- Decisions Log: append three dated entries — IA change (Investments tab + Settings as sheet), Face ID default flip, and historical backfill wiring.

**`docs/WORKING.md` edits:**
- Update "Current State" to dated today; replace the four-tab claim with the shipped IA.
- Add a "Historical backfill" section describing the new method, the durable marker, and that `forceFullResync()` re-triggers it.
- Remove the 1024-PNG follow-up (`AppIcon-1024.png` exists in `Networth/Resources/Assets.xcassets/AppIcon.appiconset/`).
- Remove the "Settings tab" wording everywhere.
- Keep the dev-team / CloudKit-container follow-ups (still real).

**`AGENTS.md` edits (and therefore `CLAUDE.md` via symlink):**
- Project Overview: change "Xcode project: `Networth.xcodeproj` (not yet created…)" to "Xcode project: `Networth.xcodeproj` (generated from `project.yml` via XcodeGen — regenerate after any `project.yml` change)."
- Key App Behavior: change "4-tab structure: Net Worth · Projections · Accounts · Settings." to "4-tab structure: Net Worth · Projections · Accounts · Investments. Settings is opened from the Net Worth toolbar."
- UX section "Information architecture is fixed at 4 tabs": same update; keep the "do not add tabs without a `docs/PLAN.md` decision" rule.

### 4. Add regression tests for the backfill

Add four Swift Testing cases to `NetworthTests/AppContainerTests.swift`:
- **Wiring.** Seed a `CachedAccount` (cash, +$1000 balance) and a couple of `CachedTransaction` rows dated within the last 24 months in a `makePreview()` container. Invoke the backfill method (expose `internal` for tests). Expect a non-trivial set of `DurableNetWorthSnapshot` rows, all stamped `source = .backfill`.
- **Marker idempotence.** Run the backfill, confirm `historyBackfillVersion == 1` afterward, then run it again — expect no additional snapshot rows because the durable marker gates it.
- **In-run dedupe.** Pre-seed the durable store with a handful of `DurableNetWorthSnapshot` rows for known dates inside the backfill window, then run the backfill with `historyBackfillVersion = 0`. After the run, fetch all snapshots and assert no two rows share the same start-of-day.
- **Source-aware tiebreak preserves the richer live snapshot.** Pre-seed the durable store with a `.live` snapshot for a given day whose assets include a $500k manual asset (so it's richer than what reconstruction will produce for that same day). Run the backfill so a `.backfill` row is also created for that day. After dedupe, assert the surviving row for that day is the `.live` one and the manual-asset value is preserved.

Pure-Swift coverage of the underlying reconstruction algorithm already exists in `NetworthCoreTests/HistoricalNetWorthTests.swift`; these new cases verify the wiring.

## Critical files

- `Networth/Services/SyncCoordinator.swift` — add backfill method + call site; gate on durable marker, not `SyncCursor`.
- `Networth/Services/SnapshotScheduler.swift` — add `dedupeSnapshotsForDuplicateDays()` with the source-aware tiebreak; invoke it from `recordIfNeeded` and from the new backfill method.
- `Networth/Persistence/DurableModels.swift` — on `DurableUserSettings` add `historyBackfillVersion: Int = 0`. On `DurableNetWorthSnapshot` add `sourceRaw: String = "live"` and `createdAt: Date = .now`. New `SnapshotSource` enum in `NetworthCore` (`.live`, `.backfill`).
- `Networth/AppContainer/AppContainerController.swift` — `forceFullResync()` also resets `historyBackfillVersion`. **Face ID migration block stays — do not delete.**
- `NetworthCore/Sources/Projections/HistoricalNetWorth.swift` — reused as-is.
- `Networth/Persistence/CachedYNABModels.swift` — reused for `CachedAccount.kind`, `CachedTransaction.toSummary()`, `SyncCursor` (cursor still used for YNAB delta sync, not for the backfill flag).
- `NetworthTests/AppContainerTests.swift` — new wiring, marker idempotence, in-run dedupe, and source-aware tiebreak tests.
- `docs/PLAN.md` — IA/Face-ID/projections/phases/log updates.
- `docs/WORKING.md` — current-state + follow-ups refresh.
- `AGENTS.md` — Xcode-project line + tab IA lines.

## Verification

1. **Domain tests still green.** `cd NetworthCore && swift test` — should report 17 passing as before (no changes to that package).
2. **App tests pass including the new cases.** `xcodebuild test -project Networth.xcodeproj -scheme Networth -destination 'platform=iOS Simulator,id=51F1E9A0-59D3-4021-A264-A706679CBD55' CODE_SIGNING_ALLOWED=NO` — expect 8 passing app-level tests (4 existing + 4 new).
3. **Backfill produces history.** Build and run on the iPhone 17 simulator with the existing PAT-equipped install: on a clean SwiftData cache (delete the app, reinstall), open the Net Worth tab after the first sync — the 2Y chart should show ~24 months of data instead of starting at install date.
4. **In-run idempotence.** Pull-to-refresh on the Net Worth tab after the first sync; snapshot count should be unchanged (no duplicate days).
5. **Force resync redoes backfill.** Trigger `forceFullResync()` (existing Settings affordance); confirm `historyBackfillVersion` is reset, the backfill runs again, and the chart re-renders with the same shape and snapshot counts.
6. **Source-aware dedupe preserves the richer snapshot.** In a debug build, pre-seed a `.live` snapshot for an arbitrary date inside the backfill window with a manual-asset-inclusive total. Run `forceFullResync()`. After the backfill, confirm the surviving snapshot for that date is the `.live` one and that its assets total still reflects the manual asset.
7. **Face ID still gates launch.** Cold-launch with biometrics enabled → lock screen appears; toggle off in Settings → next cold-launch goes straight into the tabs.
8. **Legacy settings still migrate.** In a debug build, manually write a `DurableUserSettings` row with `settingsSchemaVersion = 0` and `faceIDEnabled = false`, relaunch — bootstrap should flip `faceIDEnabled = true` (when biometrics are available) and bump the schema version.
9. **Doc/code alignment scan.** Grep `PLAN.md`, `WORKING.md`, `AGENTS.md` for "Settings tab", "off by default", "not yet created" — expect zero hits.
