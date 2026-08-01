# Networth Plaid Worker

Private, single-user Cloudflare Worker for Plaid Investments and the staged
Plaid Transactions migration. It is part of the Networth repository but
deploys independently from the iOS app.

The Production Trial deployment is `networth-plaid-worker` in the personal
BlueLava Cloudflare account. Its stable URL is
`https://networth-plaid.bluelava.me`, and the registered OAuth redirect is
`https://networth-plaid.bluelava.me/plaid/oauth`.

## Security Boundary

- Plaid `client_id`, secret, and Item access tokens never reach the iPhone.
- Every `/v1/plaid/*` route requires the provisioned backend bearer token.
- Item access tokens are encrypted with AES-256-GCM before Workers KV storage.
- `.dev.vars`, `.env`, Wrangler state, and dependencies are ignored by git.
- The Worker exposes normalized investment holdings and cursor-based banking
  transactions. It never exposes Plaid credentials or Item access tokens.
- Transaction inference is optional. Its request contract excludes amounts,
  dates, balances, account identifiers, and YNAB history.
- The Worker does not call Plaid Transactions Refresh or Recurring Transactions.

## Local Setup

```bash
npm install
cp .dev.vars.example .dev.vars
```

Generate independent random secrets:

```bash
openssl rand -base64 48   # BACKEND_BEARER_TOKEN
openssl rand -base64 32   # TOKEN_ENCRYPTION_KEY
openssl rand -base64 32   # CLAUDE_SNAPSHOT_ENCRYPTION_KEY
```

Fill `.dev.vars` with Plaid Sandbox credentials, the HTTPS redirect URI, and
the generated values. Never commit that file.

```bash
npm test
npm run check
npm run dev
```

## Deploy

Wrangler automatically provisions the `PLAID_STORAGE` KV namespace on the first
deployment and writes its ID back to `wrangler.jsonc`.

Set each required secret without putting it in shell history:

```bash
npx wrangler secret put PLAID_CLIENT_ID
npx wrangler secret put PLAID_SECRET
npx wrangler secret put PLAID_REDIRECT_URI
npx wrangler secret put BACKEND_BEARER_TOKEN
npx wrangler secret put TOKEN_ENCRYPTION_KEY
npx wrangler secret put CLAUDE_SNAPSHOT_ENCRYPTION_KEY
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler deploy
```

The checked-in deployment targets Plaid Production. Keep `PLAID_SECRET` matched
to that environment. Before deploying the Transactions build, confirm
Production Transactions access and its per-Item subscription price in the
Plaid Dashboard; exact pricing is contract-specific. Verify health, AASA, Link,
Item, transaction-sync, and unlink behavior after deployment.

## Transactions contract

- `POST /v1/plaid/link-token` accepts `investments`, `transactions`, or
  `updateTransactions` mode.
- `POST /v1/plaid/transactions/sync` returns normalized added, modified, and
  removed rows plus the next cursor and historical-import status.
- New Items request 730 days in Link. Existing investment Items collect
  additional consent in update mode, then request 730 days on their first
  `/transactions/sync` initialization call.
- `POST /v1/plaid/inference/transaction` calls the pinned Claude Haiku model
  only when the app's user-enabled fallback reaches the endpoint.

## Claude.ai connector

The connector is separate from transaction inference. The user explicitly
enables it in Networth under Settings → Claude.ai Access. The app then uploads
a full-replacement financial snapshot after successful local saves.

Add this custom connector URL in Claude.ai:

```text
https://networth-plaid.bluelava.me/mcp
```

Claude.ai uses OAuth 2.1 with PKCE and dynamic client registration. During
authorization, generate a six-character connect code in the app and enter it
on the Worker's authorization page. Codes expire after 10 minutes. Active
access grants use a rolling 60-day idle lifetime.

The five read-only tools expose:

- current account labels, types, institutions, and balances;
- effective manual assets and reconciled investment holdings;
- confirmed transaction dates, amounts, contacts, categories, and splits;
- daily asset, liability, and net-worth history;
- a compact financial summary.

The snapshot excludes credentials, account numbers and masks, provider IDs,
notes, raw bank descriptions, and unreviewed Plaid transactions. It is
AES-256-GCM encrypted in Workers KV with a key separate from Plaid Item-token
encryption. Turning access off in the app deletes the snapshot and revokes all
connect and access grants.
