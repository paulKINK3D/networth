# WORKING

## Current State (2026-06-07)
All seven phases (0-6) of `docs/PLAN.md` are implemented and validated. Post-phase additions also shipped: in-app tutorial, hidden-category exclusion for the spend projection, variable-spend extension of the CC forecaster, group rename, sticky group headers, Investments tab, app icon.

- `Networth.xcodeproj` is the source of truth. Add new files via Xcode's UI.
- App target builds clean on the iPhone 17 / iOS 26.5 simulator.
- NetworthCore SPM package: 5 sub-modules plus an umbrella target.
- App-target unit tests: 8 Swift Testing tests under `xcodebuild test`.

## What ships
- Single ModelContainer with two ModelConfigurations:
  - `NetworthLocalCache` (no CloudKit) — `CachedBudget`, `CachedAccount`, `CachedTransaction`, `CachedScheduledTransaction`, `CachedCategory`, `SyncCursor`.
  - `NetworthDurable` (CloudKit private DB) — `DurableManualAsset`, `DurableManualAssetValue`, `DurableNetWorthSnapshot`, `DurableCardSettings`, `DurableUserSettings`, `DurableExcludedSpendCategory`.
- `AppContainerController` (`@Observable`, `@MainActor`) owns `SecretStore`, `BiometricGate`, `YNABClient`, `ConnectivityMonitor`, `SnapshotScheduler`, `SyncCoordinator`.
- Every IO boundary is protocol-based with a production and in-memory/scriptable/recorded fake.
- `Nw*` design system: tokens (spacing, corner radius, typography, colors, shadow, opacity, stroke, icons) + components (card, section header, metric capsule, status badge, empty/loading state, inline notice, banner, modal layout, button styles, amount text).
- 4 tabs: **Net Worth · Projections · Accounts · Investments**. Settings opens from a sheet behind the Net Worth toolbar. CC payment forecast card with selectable payoff scenarios, cash position chart with dip/overdraft alerts.
- Read-only YNAB v1 client (delta-sync aware via `last_knowledge_of_server`), Keychain-stored PAT with iCloud sync, Face ID gate on by default when biometrics are available.
- `safeSave(source:)` posts a notification on failure; container surfaces an alert.

## Historical net-worth backfill
- `SyncCoordinator.runHistoryBackfillIfNeeded(budgetId:)` runs at the end of `syncAll` and reconstructs 24 months of daily snapshots from cached YNAB transactions via `NetworthCore.AccountHistoryReconstructor` + `NetWorthHistoryAggregator`.
- Gated by `DurableUserSettings.historyBackfillVersion` (default `0`, flipped to `1` after a successful run). The marker lives in the CloudKit-backed durable store so a device reinstall or iCloud restore doesn't re-trigger it.
- Reconstructed rows are stamped `source = .backfill` (manual assets aren't included — their history doesn't extend that far back). When a `.backfill` row collides with a `.live` row from `SnapshotScheduler.recordIfNeeded`, the dedupe pass keeps `.live` so manual-asset totals are preserved.
- `AppContainerController.forceFullResync()` clears all `SyncCursor` rows AND resets `historyBackfillVersion = 0`, so the next sync redoes the full 24-month fetch and reconstruction.

## Build & Test
```bash
# Pure-Swift domain tests (fastest):
cd NetworthCore && swift test

# App target build (iOS 26 simulator):
xcodebuild -project Networth.xcodeproj -scheme Networth \
  -destination 'platform=iOS Simulator,id=51F1E9A0-59D3-4021-A264-A706679CBD55' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# App target tests:
xcodebuild test -project Networth.xcodeproj -scheme Networth \
  -destination 'platform=iOS Simulator,id=51F1E9A0-59D3-4021-A264-A706679CBD55' \
  CODE_SIGNING_ALLOWED=NO
```

## Known follow-ups
- **First-build provisioning:** running on a real device (not the simulator) requires the user to set their development team in Xcode signing & capabilities. Use a personal Apple ID in `Xcode → Settings → Accounts`.
- **CloudKit container:** the entitlement names `iCloud.com.bluelava.me.networth`. The user must create this container in their developer portal once before CloudKit sync starts working on-device.
- **Numeric-first-tap-replaces-value:** the documented input pattern is stubbed in `ManualAssetForm.selectAllOnFirstTap()` — wire a UITextField responder coordinator if/when that polish is desired.
- **Historical chart math when accounts close:** the 24-month reconstruction excludes closed YNAB accounts, which means transfers from a now-closed account into a still-open one get treated as external income. Walking the open account's balance backwards subtracts those inflows, producing artificially low (sometimes negative) historical values. Deferred — revisit after Plaid integration lands. Options when revisiting: detect YNAB-side transfers via `transfer_account_id` and skip them when the matching account isn't in the contributing set, or include closed accounts in reconstruction with a "closure shouldn't look like a drop" treatment. Diagnostic surface for inspecting the data is the ⓘ button on the Net Worth Trend card → `TrendDetailView`.
