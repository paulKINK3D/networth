# Networth Plaid Worker

Private, single-user Cloudflare Worker for the optional Plaid Investments
connection. It is part of the Networth repository but deploys independently
from the iOS app.

The Sandbox deployment is `networth-plaid-worker` in the personal BlueLava
Cloudflare account. Its stable URL is `https://networth-plaid.bluelava.me`, and
the registered OAuth redirect is
`https://networth-plaid.bluelava.me/plaid/oauth`.

## Security Boundary

- Plaid `client_id`, secret, and Item access tokens never reach the iPhone.
- Every `/v1/plaid/*` route requires the provisioned backend bearer token.
- Item access tokens are encrypted with AES-256-GCM before Workers KV storage.
- `.dev.vars`, `.env`, Wrangler state, and dependencies are ignored by git.
- The Worker exposes investment accounts and holdings only. It does not expose
  ordinary transactions or feed Networth's cash projections.

## Local Setup

```bash
npm install
cp .dev.vars.example .dev.vars
```

Generate independent random secrets:

```bash
openssl rand -base64 48   # BACKEND_BEARER_TOKEN
openssl rand -base64 32   # TOKEN_ENCRYPTION_KEY
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
npx wrangler deploy
```

Before switching to Production, update `PLAID_ENV` and the matching Plaid secret
deliberately, redeploy, and verify the health, AASA, and Link-token routes before
using one of the limited Production Item additions.
