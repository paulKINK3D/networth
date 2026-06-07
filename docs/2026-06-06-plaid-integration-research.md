# Plaid Integration — Plan

## Context

The Networth iOS app reads from YNAB via a Personal Access Token. YNAB does not expose per-security investment holdings, so the Investments tab today only summarizes account balances and manual entries.

Researched Monarch Money, Copilot Money, and Plaid as data sources to fill that gap:

- **Monarch:** no official API; only reverse-engineered GraphQL (ToS violation, no Swift client). Off the table.
- **Copilot:** no public API; MCP beta is for AI agents, not iOS apps. Off the table.
- **Plaid:** real, official, well-documented. Trial plan (April 2026) is free, returns real production data, 10 connected institutions, no KYB. Native iOS Link SDK. Requires a small backend to hold secrets and exchange tokens. Investment holdings exposed at the security level (ticker, CUSIP, cost basis, market value).

**Decided direction:** add Plaid alongside YNAB, with a small Cloudflare Worker backend doing the secret-side work. YNAB stays as the primary source for everyday cash + transactions; Plaid drives the Investments tab and contributes its accounts to the net-worth total.

Current user-data assumption for the first pass: YNAB has no investment accounts, and existing manual assets do not include brokerage / retirement / crypto assets that Plaid would replace. Under that assumption Plaid investment balances can be added directly to net worth without reconciliation. If YNAB investment accounts or manual investment assets are added later, add a durable duplicate-prevention/mapping layer before counting both sources.

## Architecture

```
Networth iOS app  ──TLS──▶  Cloudflare Worker (Plaid proxy)
                                  │
                                  └──▶  Plaid API
                                        (token exchange, accounts, holdings,
                                         investment txns, transactions/sync,
                                         webhooks)
```

- iOS app holds: a per-user bearer token (random UUID) in Keychain for talking to the Worker. Never sees the Plaid `access_token`.
- Worker holds: Plaid `client_id` + `secret` in environment, plus a per-user collection of linked Plaid Items keyed by the bearer token. Each Item stores its own `item_id`, `access_token`, institution metadata, product set, per-product cursors, sync timestamps, and optional removal/tombstone state.

## Backend (Cloudflare Worker, separate repo / project)

Built outside this repo. TypeScript, deployed via `wrangler`.

Endpoints:

- `POST /plaid/link-token` — create a Link token for the iOS SDK.
- `POST /plaid/exchange` — body `{ public_token }`, exchange + append/update the returned Item and `access_token` in KV.
- `GET  /plaid/accounts` — return all accounts under the linked Items.
- `GET  /plaid/investments/holdings` — holdings + securities for the linked Items.
- `POST /plaid/transactions/sync` — forwards to Plaid `/transactions/sync` for each active Item with that Item's stored cursor; persists the new per-Item cursor.
- `DELETE /plaid/items/:item_id` — calls Plaid `/item/remove`, removes/tombstones the stored `access_token`, and allows iOS to clear cached data for that Item.
- `POST /plaid/webhook` — Plaid webhook receiver. No-op handler initially (logged only).

Secrets: `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV=production` (or `sandbox` initially) set via `wrangler secret put`.

Auth: every request from iOS includes `Authorization: Bearer <token>`. The Worker uses that token as the KV key under which Plaid Item records are stored. Tokens are minted by the iOS app on first launch and saved to Keychain (iCloud-synced like the YNAB PAT).

iOS Link setup: use a stable HTTPS domain for the Worker before production linking. Configure the Plaid Dashboard redirect URI, add the app Associated Domains entitlement (`applinks:<worker-domain>`), serve an Apple App Site Association file from `/.well-known/apple-app-site-association`, and pass the configured `redirect_uri` when creating Link tokens.

## iOS-side changes (this repo)

### New SPM dependency
- Add Plaid Link in Xcode (File → Add Package Dependencies…). The repo no longer uses XcodeGen — `Networth.xcodeproj` is the source of truth.
- Package URL: `https://github.com/plaid/plaid-link-ios-spm`
- Product: `LinkKit`

### New core models (`NetworthCore/Sources/Models/`)
- `Holding.swift`:
  - `SecuritySummary { id, ticker, cusip, isin, name, type, lastPrice, lastPriceAsOf }`
  - `HoldingSummary { id, accountId, securityId, quantity, costBasis, institutionValue, asOf }`

### New cache models (`Networth/Persistence/CachedPlaidModels.swift`)
- `CachedPlaidItem(id, institutionName, lastSyncedAt, cursor)`
- `CachedPlaidAccount(id, itemId, name, kindRaw, currentBalanceMU, availableBalanceMU)`
- `CachedPlaidSecurity(id, ticker, cusip, isin, name, typeRaw, lastPriceMU, lastPriceAsOf)`
- `CachedPlaidHolding(id, accountId, securityId, quantity, costBasisMU, institutionValueMU, asOf)`
- Register all in `ModelContainerFactory` cache schema (local-only, no CloudKit).
- Store `isoCurrencyCode` on Plaid account/holding/security rows where Plaid provides it. Parse Plaid monetary values as `Decimal`, convert major units to milliunits with a documented rounding rule, and do not use `Double` for persisted money conversion. First pass is USD-only for net-worth totals; cache but exclude non-USD/unofficial-currency rows and surface an unsupported-currency notice.

### New service (`Networth/Services/PlaidClient.swift`)
- Protocol `PlaidClient: Actor` with: `setBackendToken(_:)`, `createLinkToken()`, `exchangePublicToken(_:)`, `accounts()`, `holdings() -> ([CachedPlaidAccount-like], [CachedPlaidSecurity-like], [CachedPlaidHolding-like])`, `transactionsSync() -> SyncResult`, `rateLimit()`.
- `LivePlaidClient` actor: talks to the Worker over `URLSession`, bearer-token auth. Same shape as `LiveYNABClient`.
- `RecordedPlaidClient` actor fake for tests/previews.

### Sync (`Networth/Services/SyncCoordinator.swift`)
- Keep one user-facing "Sync Now" affordance, but split YNAB and Plaid into independent sync paths/statuses so a Plaid institution/API failure does not poison a successful YNAB sync.
- Plaid sync path: fetch accounts → fetch holdings → fetch investment transactions → upsert into the new cache models → save per-Item cursors.
- Track separate phase/error/last-sync state for YNAB and Plaid. Save successful results from either source even if the other source fails.
- Same `safeSave` + phase-reporting pattern as YNAB.

### Secret storage (`Networth/Services/SecretStore.swift`)
- New key `.plaidBackendToken`. Mints UUID on first launch if absent. iCloud-synced like the YNAB PAT.
- New key `.plaidBackendBaseURL` (defaults to the deployed Worker URL; configurable for sandbox testing).

### Settings (`Networth/Features/Settings/SettingsView.swift`)
- New "Connect a Bank" section. Tap a button → open Plaid Link via the SDK (`LinkController`) using the link token from the backend → on success, send `public_token` to the backend → mark the new `CachedPlaidItem` as linked.
- List of currently linked Items with a working "Unlink" swipe action that confirms, calls `DELETE /plaid/items/:item_id`, and clears cached accounts/holdings/securities for that Item.

### Investments tab (`Networth/Features/Investments/InvestmentsView.swift`)
- Replace the current "ynabInvestments + manualInvestments" model with three sections:
  1. **Brokerage / Retirement** — Plaid holdings grouped by account, each row shows ticker + name + quantity + market value + day-change colored.
  2. **YNAB investment-type accounts** — future fallback only if any ever exist; current user data has none.
  3. **Manual** — existing manual assets of brokerage/retirement/crypto kinds.
- Hero card total backed by Plaid `institutionValue` sums where available.

### Net Worth tab
- Net-worth calculation pulls Plaid account balances into the asset side (investment-type) in addition to YNAB cash + manual assets. Adjust `SnapshotScheduler.computeBreakdown()` to include Plaid balances.
- For the first pass this relies on the explicit assumption that there are no YNAB investment accounts and no existing manual investment assets representing the same Plaid accounts. Revisit before adding YNAB/manual investment overlap.

### Tutorial
- Add a step explaining that Plaid is optional and only needed for per-security investments.

### Xcode project changes
- Add new Swift files to the project via Xcode (drag into the navigator or right-click group → Add Files...).
- Add the Plaid SPM dependency and `LinkKit` product via Xcode's File → Add Package Dependencies dialog.

## Implementation Phasing

1. **Phase 1 — Backend (~half day)**: scaffold the Worker, model multiple Items per bearer token, deploy to `sandbox`, smoke-test link-token + exchange against the Plaid sandbox.
2. **Phase 2 — iOS scaffolding (~half day)**: add the SPM dep via Xcode, create the cache models + core models, register in `ModelContainerFactory`, stub `PlaidClient`.
3. **Phase 3 — Link flow (~half day)**: configure redirect URI + Universal Links, implement Settings → Connect a Bank, run a live link against the Plaid sandbox institution `ins_109508`, confirm exchange persists an Item server-side.
4. **Phase 4 — Holdings sync (~half day)**: fetch and persist accounts + holdings + securities, rewrite InvestmentsView.
5. **Phase 5 — Unlink + transactions sync + webhook (~half day)**: working Item removal, investment transactions, and a webhook receiver.
6. **Phase 6 — Production flip**: switch Worker env to `production`, link a real institution from the Trial plan.

## Critical Files (will be modified or created)

- `Networth/Services/YNABClient.swift` — reference pattern for `PlaidClient`.
- `Networth/Services/PlaidClient.swift` — **new**.
- `Networth/Services/SyncCoordinator.swift` — add independent Plaid sync path/status alongside YNAB.
- `Networth/Services/SecretStore.swift` — add `.plaidBackendToken`, `.plaidBackendBaseURL`.
- `Networth/Persistence/CachedYNABModels.swift` — reference pattern.
- `Networth/Persistence/CachedPlaidModels.swift` — **new**.
- `Networth/Persistence/ModelContainerFactory.swift` — register new models.
- `NetworthCore/Sources/Models/Holding.swift` — **new**.
- `Networth/Features/Investments/InvestmentsView.swift` — rewrite around holdings.
- `Networth/Features/Settings/SettingsView.swift` — Connect a Bank section.
- `Networth/Features/Tutorial/TutorialStep.swift` — extra step.
- `Networth.xcodeproj` — add Plaid SPM package + `LinkKit` dependency via Xcode's package dialog.

## Verification

- **Backend smoke test**: `curl -X POST $WORKER/plaid/link-token -H 'Authorization: Bearer $TOK'` returns a valid `link_token`.
- **Universal Links**: `https://<worker-domain>/.well-known/apple-app-site-association` serves the expected app association, and Plaid Link succeeds with the configured redirect URI.
- **Link flow**: Settings → Connect a Bank → use Plaid sandbox creds (`user_good` / `pass_good`) → exchange returns a `CachedPlaidItem` row.
- **Multi-Item**: link two sandbox institutions, confirm both Items persist independently and holdings/accounts from both render.
- **Unlink**: unlink one Item, confirm Plaid `/item/remove` succeeds, server token is removed/tombstoned, and iOS cache rows for that Item disappear.
- **Holdings**: Investments tab shows at least one holding from the sandbox institution with ticker + market value.
- **Currency conversion**: Decimal-to-milliunit conversion is covered by tests; non-USD/unofficial-currency rows do not enter net-worth totals.
- **Transactions sync idempotency**: trigger sync twice in a row, confirm no duplicates and cursor advances.
- **Partial failure**: simulate Plaid failure after a successful YNAB response and confirm YNAB cache/last-sync still updates; simulate YNAB failure and confirm cached Plaid holdings still render.
- **Off-network**: airplane mode → Investments tab still renders cached holdings.
- **Net Worth**: confirm hero total reflects Plaid balances in addition to YNAB + manual.
- **Production flip**: after sandbox verification, switch Worker env to `production`, link a real institution from the Trial plan, confirm same flow works end-to-end.

## Out of Scope (for this pass)

- Liabilities, mortgages, student loans via Plaid (could come later).
- Push notifications from the webhook to the device.
- Multi-user support — design assumes a single user (the developer themselves).
