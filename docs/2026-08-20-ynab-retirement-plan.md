# YNAB Retirement Plan

## Decision

YNAB is retired from Networth. Plaid is the sole external financial-data source. The completed YNAB backlog-reference workflow must not remain visible, make network requests, influence classifications, or contribute to reports.

## Data-safety boundary

Preserve all approved Networth transaction decisions and splits, canonical contacts and categories, manual assets and history, Net Worth snapshots, settings, goals, projection/card configuration, Plaid connections and caches, and the read-only IBR App Group document.

Purge only disposable local YNAB caches, cursors, historical match rows, and reference suggestions. Keep provider-derived canonical IDs and CloudKit fields inert when changing them could break durable relationships or schema compatibility.

The synchronized YNAB Keychain token is removed only after the first Plaid-only release is verified on the physical device because Keychain contents are not part of an app-container backup.

## Rollout

1. [x] Secure and verify offline copies of both the physical-device app container and the shared financial App Group plus rollback source state. The App Group contains the active SwiftData stores; similarly named app-container stores are dormant legacy copies.
2. [x] Remove every YNAB UI, token API, runtime client/import, fallback, and classifier path. Noncompiled source history remains temporarily inside the renamed Plaid service files.
3. [x] Run an idempotent per-launch cleanup of disposable local YNAB rows before all other local migrations.
4. [x] Verify NetworthCore tests, app-test compilation, and generic-device Debug and Release builds.
5. [x] Install and launch the clean Release build on the physical device, then compare the active App Group stores before and after migration. The audit confirmed only 3,106 YNAB reference suggestions were removed; Plaid and durable data were preserved.
6. [x] Visually confirm the Plaid-only Accounts & Sync surface on the physical device.
7. [ ] Remove the synchronized YNAB token only with separate explicit approval; it is inert but is not covered by the container backups.
8. [ ] In a later release, remove now-empty compatibility-only local models and noncompiled source history where migration testing proves it safe. Durable CloudKit compatibility fields may remain inert indefinitely.
