# Plaid Integration — Plan

The concrete iOS/backend JSON boundary is documented in
[`PLAID_BACKEND_CONTRACT.md`](PLAID_BACKEND_CONTRACT.md).

## Context

The Networth iOS app reads cash and transaction data from YNAB via a Personal Access Token. Its Investments tab already reports YNAB investment accounts and manual investments, but YNAB does not expose per-security holdings.

Researched Monarch Money, Copilot Money, and Plaid as data sources to fill that gap:

- **Monarch:** no official API; only reverse-engineered GraphQL (ToS violation, no Swift client). Off the table.
- **Copilot:** no public API; MCP beta is for AI agents, not iOS apps. Off the table.
- **Plaid:** real, official, well-documented. Trial plan (April 2026) is free, returns real production data, 10 connected institutions, no KYB. Native iOS Link SDK. Requires a small backend to hold secrets and exchange tokens. Investment holdings exposed at the security level (ticker, CUSIP, cost basis, market value).

**Decided direction:** add Plaid alongside YNAB, with a small private backend doing the secret-side work. YNAB remains authoritative for cash, transactions, scheduled activity, and projections. Plaid adds optional investment-account and holding detail.

Do not assume linked accounts are unique. A new Plaid account is cached and shown as needing review, but remains excluded from Net Worth until the user marks it as a new source or maps it as a duplicate of a YNAB account/manual asset. Plaid account balances reconcile the portfolio total; holdings explain the account composition and are never summed on top of that balance.

## Architecture

```
Networth iOS app  ──TLS──▶  Cloudflare Worker (Plaid proxy)
                                  │
                                  └──▶  Plaid API
                                        (token exchange, accounts, holdings,
                                         Item management)
```

- iOS app holds: a pre-provisioned, high-entropy backend bearer token in Keychain. It never sees a Plaid `client_id`, `secret`, or Item `access_token`.
- Worker holds: Plaid `client_id` + `secret` as Worker secrets and a single-user collection of linked Plaid Items in Workers KV. Each Item stores its `item_id`, institution metadata, sync state, and an access token encrypted with a separate AES-256-GCM key before persistence.

The backend must validate the bearer token against a provisioned secret. It must not accept arbitrary client-generated UUIDs as authorization; doing so would expose billable Plaid endpoints to anyone who discovers the Worker URL.

## Backend (`PlaidWorker/`)

Built as an independently deployed TypeScript package inside this repository.

Endpoints:

- `POST /v1/plaid/link-token` — create a Link token for the iOS SDK.
- `POST /v1/plaid/exchange` — body `{ publicToken }`, exchange + append/update the returned Item and `access_token` server-side.
- `GET  /v1/plaid/items` — return linked Item metadata without access tokens.
- `GET  /v1/plaid/investments/holdings` — return a complete normalized Item/account/security/holding snapshot.
- `DELETE /v1/plaid/items/:item_id` — calls Plaid `/item/remove`, removes/tombstones the stored `access_token`, and allows iOS to clear cached data for that Item.
Secrets: `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_REDIRECT_URI`, `BACKEND_BEARER_TOKEN`, and `TOKEN_ENCRYPTION_KEY`. `PLAID_ENV` is a non-secret Worker variable and is `sandbox` initially.

Auth: every request from iOS includes `Authorization: Bearer <token>`. The token is generated outside the app, installed as a backend secret, and entered once into Networth's Keychain-backed settings. Even for this single-user app, the Worker rejects unknown tokens before calling Plaid.

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
- `CachedPlaidItem(id, institutionName, status, lastSyncedAt)`
- `CachedPlaidAccount(id, itemId, name, kindRaw, currentBalanceMU, availableBalanceMU)`
- `CachedPlaidSecurity(id, ticker, cusip, isin, name, typeRaw, lastPriceMU, lastPriceAsOf)`
- `CachedPlaidHolding(id, accountId, securityId, quantity, costBasisMU, institutionValueMU, asOf)`
- Register all in `ModelContainerFactory` cache schema (local-only, no CloudKit).
- Store `isoCurrencyCode` on Plaid account/holding/security rows where Plaid provides it. Parse Plaid monetary values as `Decimal`, convert major units to milliunits with a documented rounding rule, and do not use `Double` for persisted money conversion. First pass is USD-only for net-worth totals; cache but exclude non-USD/unofficial-currency rows and surface an unsupported-currency notice.

### New service boundary
- Protocol `PlaidClient: Actor` with: `configure(baseURL:bearerToken:)`, `createLinkToken()`, `exchangePublicToken(_:)`, `items()`, `holdings()`, and `removeItem(id:)`.
- `LivePlaidClient` actor: talks to the Worker over `URLSession`, bearer-token auth. Same shape as `LiveYNABClient`.
- `RecordedPlaidClient` actor fake for tests/previews.

### Sync (`Networth/Services/SyncCoordinator.swift`)
- Keep one user-facing "Sync Now" affordance, but split YNAB and Plaid into independent sync paths/statuses so a Plaid institution/API failure does not poison a successful YNAB sync.
- Plaid sync path: fetch Items, accounts, securities, and holdings; upsert the local cache; remove rows no longer returned; save each successful source independently from YNAB.
- Track separate phase/error/last-sync state for YNAB and Plaid. Save successful results from either source even if the other source fails.
- Same `safeSave` + phase-reporting pattern as YNAB.

### Secret storage (`Networth/Services/SecretStore.swift`)
- New key `.plaidBackendBearerToken`. Entered once after being provisioned on the backend; iCloud-synced like the YNAB PAT.
- The non-secret backend URL comes from the app target's `PlaidBackendBaseURL` Info.plist key.

### Settings (`Networth/Features/Settings/SettingsView.swift`)
- New "Connect a Bank" section. Tap a button → open Plaid Link via the SDK (`LinkController`) using the link token from the backend → on success, send `public_token` to the backend → mark the new `CachedPlaidItem` as linked.
- List of currently linked Items with a working "Unlink" swipe action that confirms, calls `DELETE /plaid/items/:item_id`, and clears cached accounts/holdings/securities for that Item.

### Investments tab (`Networth/Features/Investments/InvestmentsView.swift`)
- Replace the current "ynabInvestments + manualInvestments" model with three sections:
  1. **Brokerage / Retirement** — Plaid holdings grouped by account, each row shows ticker + name + quantity + market value + day-change colored.
  2. **YNAB investment-type accounts** — future fallback only if any ever exist; current user data has none.
  3. **Manual** — existing manual assets of brokerage/retirement/crypto kinds.
- Each Plaid account row reconciles its account balance to the sum of holdings and reports residual cash/difference rather than hiding it. The hero uses included account balances, not a second sum of holdings.

### Net Worth tab
- Net-worth calculation pulls only user-confirmed, non-duplicate Plaid account balances into the asset side. Duplicate mappings remain visible in Investments but contribute zero incremental value.

### Tutorial
- Add a step explaining that Plaid is optional and only needed for per-security investments.

### Xcode project changes
- Add new Swift files to the project via Xcode (drag into the navigator or right-click group → Add Files...).
- Add the Plaid SPM dependency and `LinkKit` product via Xcode's File → Add Package Dependencies dialog.

## Implementation Phasing

1. **Phase 1 — Backend foundation:** complete and deployed in Sandbox at `networth-plaid.bluelava.me`; authenticated Link/exchange/Items/holdings/unlink routes, encrypted KV persistence, AASA/OAuth routes, tests, and smoke checks pass.
2. **Phase 2 — iOS scaffolding:** complete; core/cache models, reconciliation rules, backend client, independent sync path, Keychain token storage, and tests are implemented.
3. **Phase 3 — Link flow:** complete and validated on-device with LinkKit 7.0.3, the registered custom-domain redirect, public-token exchange, and immediate holdings sync.
4. **Phase 4 — Holdings reporting:** complete and validated on-device; a Sandbox account moved from Needs Review to Separate Account and its security-level holdings rendered in Investments.
5. **Phase 5 — Reconciliation + unlink:** reconciliation is validated; unlink is implemented but still needs one on-device cleanup check. Webhooks and investment transactions remain later enhancements.
6. **Phase 6 — Production flip:** after unlink verification, switch the Worker environment and secret to `production` deliberately, then use one Trial Production Item addition for a real institution.

## Critical Files

- `Networth/Services/YNABClient.swift` — reference pattern for `PlaidClient`.
- `Networth/Services/YNABClient.swift` — currently hosts the Plaid backend boundary so the app target remains buildable without hand-editing the Xcode project; split it into `PlaidClient.swift` through Xcode when LinkKit is added.
- `Networth/Services/SyncCoordinator.swift` — add independent Plaid sync path/status alongside YNAB.
- `Networth/Services/SecretStore.swift` — `.plaidBackendBearerToken` Keychain key.
- `Networth/Persistence/CachedYNABModels.swift` — currently hosts local Plaid cache models.
- `Networth/Persistence/DurableModels.swift` — durable per-account treatment decisions.
- `Networth/Persistence/ModelContainerFactory.swift` — registers Plaid cache and durable models.
- `NetworthCore/Sources/Models/PlaidInvestments.swift` — normalized investment and reconciliation models.
- `Networth/Features/Investments/InvestmentsView.swift` — combined portfolio and Plaid holding detail.
- `Networth/Features/Settings/SettingsView.swift` — native Link and account-review flows.
- `Networth.xcodeproj` — LinkKit 7.0.3 package dependency.

## Verification

- **Backend smoke test**: `curl -X POST $WORKER/plaid/link-token -H 'Authorization: Bearer $TOK'` returns a valid `link_token`.
- **Universal Links**: `https://<worker-domain>/.well-known/apple-app-site-association` serves the expected app association, and Plaid Link succeeds with the configured redirect URI.
- **Link flow — passed 2026-07-19**: Settings → Connect Investment Account → Sandbox phone/credentials → exchange produced a cached Item and account in Needs Review.
- **Multi-Item**: link two sandbox institutions, confirm both Items persist independently and holdings/accounts from both render.
- **Unlink**: unlink one Item, confirm Plaid `/item/remove` succeeds, server token is removed/tombstoned, and iOS cache rows for that Item disappear.
- **Holdings — passed 2026-07-19**: after choosing Separate Account, Investments displayed holdings from the Sandbox institution.
- **Currency conversion**: Decimal-to-milliunit conversion is covered by tests; non-USD/unofficial-currency rows do not enter net-worth totals.
- **Sync idempotency**: trigger holdings sync twice in a row, confirm no duplicate Items/accounts/securities/holdings and stale rows are removed only after a successful complete response.
- **Partial failure**: simulate Plaid failure after a successful YNAB response and confirm YNAB cache/last-sync still updates; simulate YNAB failure and confirm cached Plaid holdings still render.
- **Off-network**: airplane mode → Investments tab still renders cached holdings.
- **Net Worth**: confirm hero total reflects Plaid balances in addition to YNAB + manual.
- **Production flip**: after sandbox verification, switch Worker env to `production`, link a real institution from the Trial plan, confirm same flow works end-to-end.

## Out of Scope (for this pass)

- Liabilities, mortgages, student loans via Plaid (could come later).
- Ordinary bank transactions and `/transactions/sync`; YNAB remains authoritative.
- Investment transactions and performance attribution; holdings are the first release.
- Push notifications from the webhook to the device.
- Multi-user support — design assumes a single user (the developer themselves).
