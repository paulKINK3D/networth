# Plaid Backend Contract

Status: deployed Sandbox contract on `feature/plaid-integration`.

## Boundary

The iOS app never receives or stores Plaid `client_id`, `secret`, or Item
`access_token` values. A private backend owns every direct Plaid API call. The
app sends a separately provisioned bearer token in the `Authorization` header;
the backend must reject unknown tokens before calling Plaid.

Plaid is investment-only in this release. YNAB remains authoritative for cash,
transactions, scheduled activity, credit-card payments, and projections.

The base URL is supplied to the app through the `PlaidBackendBaseURL` Info.plist
key. The bearer token is entered once and stored under
`plaid.backend_bearer_token` in the iCloud-synced Keychain. The non-secret base
URL is committed; the bearer token is not.

## Endpoints

All response dates use ISO 8601. Monetary values are JSON decimal numbers in
major currency units; `NetworthCore` converts them directly from `Decimal` to
milliunits without a `Double` intermediate.

### Create Link token

`POST /v1/plaid/link-token`

```json
{
  "linkToken": "link-sandbox-...",
  "expiration": "2026-07-19T20:00:00Z"
}
```

The backend calls Plaid `/link/token/create` with the `investments` product, a
stable `client_user_id`, and the production HTTPS redirect URI.

### Exchange public token

`POST /v1/plaid/exchange`

```json
{
  "publicToken": "public-sandbox-..."
}
```

```json
{
  "item": {
    "id": "item-id",
    "institutionName": "Example Brokerage",
    "status": "healthy",
    "lastSyncedAt": "2026-07-19T19:00:00Z"
  }
}
```

The public token is short-lived. The backend exchanges it immediately and
stores the returned Item access token; the access token is never returned.

### List Items

`GET /v1/plaid/items`

```json
{
  "items": [
    {
      "id": "item-id",
      "institutionName": "Example Brokerage",
      "status": "healthy",
      "lastSyncedAt": "2026-07-19T19:00:00Z"
    }
  ]
}
```

### Get holdings snapshot

`GET /v1/plaid/investments/holdings`

```json
{
  "items": [],
  "accounts": [],
  "securities": [],
  "holdings": []
}
```

Each account includes `id`, `itemId`, `institutionName`, `name`, optional
`officialName`, `mask`, and `subtype`, `currentBalance`, optional
`availableBalance`, `isoCurrencyCode`, and `unofficialCurrencyCode`.

Each security includes `id`, optional `name`, `tickerSymbol`, and `type`,
optional `closePrice` and `closePriceAsOf`, `isoCurrencyCode`, and
`unofficialCurrencyCode`.

Each holding includes `accountId`, `securityId`, `quantity`,
`institutionValue`, optional `costBasis`, and optional `asOf`.

The response is a complete snapshot across every active Item. If any Item
cannot be represented safely, return a non-2xx response instead of a partial
success; the app preserves its prior cache on failure. This lets a successful
response remove stale rows without deleting data because of a transient Item
error.

### Remove Item

`DELETE /v1/plaid/items/{item_id}`

The backend calls Plaid `/item/remove`, deletes or tombstones the stored access
token, and returns any 2xx response. The app ignores the response body.

## Reconciliation Rules

- New Plaid accounts begin as `pendingReview` and contribute zero to Net Worth.
- `included` USD accounts contribute their current account balance.
- `duplicateYNAB`, `duplicateManualAsset`, `excluded`, non-USD, unofficial
  currency, and missing-balance accounts contribute zero.
- Holdings are explanatory detail. They never add value on top of the account
  balance.
- Account balance minus summed holding value is shown as residual cash or an
  institution reconciliation difference.

## Current Deployment

- Worker: `networth-plaid-worker` in the personal BlueLava Cloudflare account.
- Base URL: `https://networth-plaid.bluelava.me`.
- OAuth redirect: `https://networth-plaid.bluelava.me/plaid/oauth`.
- Environment: Plaid Sandbox.
- iOS SDK: LinkKit 7.0.3 through `plaid-link-ios-spm`.
- Validated on-device 2026-07-19: app build, private backend-token bootstrap,
  native Link, public-token exchange, Needs Review staging, Separate Account
  inclusion, holdings sync, and holdings display.
- Remaining: verify unlink cleanup, then replace the Worker environment and Plaid
  secret with Production/Trial values and connect one real institution.

Official references: [Plaid iOS Link](https://plaid.com/docs/link/ios/),
[Plaid OAuth](https://plaid.com/docs/link/oauth/), and
[Plaid Investments](https://plaid.com/docs/api/products/investments/).
