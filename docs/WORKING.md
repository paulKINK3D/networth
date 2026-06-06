# WORKING

## Current State (2026-06-06)
All seven phases (0-6) of `docs/PLAN.md` are implemented and validated.

- `Networth.xcodeproj` generated from `project.yml` via xcodegen.
- App target builds clean on the iPhone 17 / iOS 26.5 simulator with zero warnings.
- NetworthCore SPM package: 5 sub-modules plus an umbrella target — 17 Swift Testing tests pass under `swift test`.
- App-target unit tests: 4 Swift Testing tests pass under `xcodebuild test`.

## 2026-06-06 — Durable schema fix
- First on-device launch crashed in `NetworthApp.init` with `SwiftDataError.loadIssueModelContainer`. Underlying CloudKit error: "CloudKit integration does not support unique constraints" on `DurableCardSettings.accountId`.
- Stripped `@Attribute(.unique)` from all five durable models (`DurableManualAsset`, `DurableManualAssetValue`, `DurableNetWorthSnapshot`, `DurableCardSettings`, `DurableUserSettings`). The cache models keep `.unique` — they're in the local-only configuration.
- The two call sites that depended on dedupe (`DurableUserSettings` singleton in `AppContainerController.bootstrap`, `DurableCardSettings` per accountId in `CardSettingsForm.save`) already do fetch-or-create, so behavior is unchanged.
- **Lesson for any new durable model:** CloudKit-backed configurations forbid `@Attribute(.unique)`. Enforce uniqueness at the application layer via fetch-or-create instead.

## What ships
- Single ModelContainer with two ModelConfigurations:
  - `NetworthLocalCache` (no CloudKit) — `CachedBudget`, `CachedAccount`, `CachedTransaction`, `CachedScheduledTransaction`, `SyncCursor`.
  - `NetworthDurable` (CloudKit private DB) — `DurableManualAsset`, `DurableManualAssetValue`, `DurableNetWorthSnapshot`, `DurableCardSettings`, `DurableUserSettings`.
- `AppContainerController` (`@Observable`, `@MainActor`) owns `SecretStore`, `BiometricGate`, `YNABClient`, `ConnectivityMonitor`, `SnapshotScheduler`, `SyncCoordinator`.
- Every IO boundary is protocol-based with a production and in-memory/scriptable/recorded fake.
- `Nw*` design system: tokens (spacing, corner radius, typography, colors, shadow, opacity, stroke, icons) + components (card, section header, metric capsule, status badge, empty/loading state, inline notice, banner, modal layout, button styles, amount text).
- 4 tabs: Net Worth · Projections · Accounts · Settings. CC payment forecast card with selectable payoff scenarios, cash position chart with dip/overdraft alerts.
- Read-only YNAB v1 client (delta-sync aware via `last_knowledge_of_server`), Keychain-stored PAT with iCloud sync, optional Face ID gate.
- `safeSave(source:)` posts a notification on failure; container surfaces an alert.

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
- **App icon:** `AppIcon.appiconset` ships without a 1024×1024 PNG. Drop one in before TestFlight upload.
- **CloudKit container:** the entitlement names `iCloud.com.bluelava.me.networth`. The user must create this container in their developer portal once before CloudKit sync starts working on-device.
- **Numeric-first-tap-replaces-value:** the documented input pattern is stubbed in `ManualAssetForm.selectAllOnFirstTap()` — wire a UITextField responder coordinator if/when that polish is desired.
