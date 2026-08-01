# Claude.ai Financial Data Connector

## Decision

Networth supports an optional, read-only Claude.ai custom connector modeled on
LiftLog's remote MCP flow. This is distinct from the privacy-bounded Claude
transaction-classification fallback.

The connector is off by default. Enabling it requires an explicit disclosure
in Settings and creates an encrypted financial copy in the user's private
Cloudflare Worker. Turning it off must first delete that copy and revoke every
OAuth grant; local and CloudKit data remain intact.

## Data boundary

The uploaded full-replacement snapshot may contain:

- account labels, institutions, types, balances, and available balances;
- effective manual asset values;
- reviewed, contributing Plaid holdings;
- confirmed transaction dates, amounts, contacts, categories, treatments, and
  split allocations;
- daily asset, liability, and net-worth totals.

It excludes:

- YNAB, Plaid, backend, and Anthropic credentials;
- Plaid Item access tokens;
- provider IDs, account numbers, and account masks;
- transaction notes, memos, and raw bank descriptions;
- pending, deleted, or unreviewed Plaid transactions;
- the local-only BL IBR bridge document.

The selected banking source controls account and transaction rows: YNAB before
cutover, Plaid after cutover. Manual assets, reconciled investments, and daily
net-worth history remain source-independent.

## Sync lifecycle

`ClaudeDataSyncCoordinator` observes successful model-context saves. While the
feature is enabled it debounces saves for 1.5 seconds, builds a fresh snapshot,
and replaces the encrypted Worker copy. The app also offers Sync Now. Successful
uploads update a CloudKit-safe last-sync timestamp; failures preserve the
opt-in state and surface a retryable status.

The additive `DurableUserSettings` fields default to disabled, so existing and
iCloud-restored rows require no destructive migration or legacy-field cleanup.

## Authorization and tools

The Worker exposes Streamable HTTP JSON-RPC at:

```text
https://networth-plaid.bluelava.me/mcp
```

Claude.ai discovers an OAuth 2.1 authorization server, dynamically registers a
client, and uses PKCE. The iOS app mints a single-use six-character connect
code with a 10-minute lifetime. OAuth access tokens are stored only as hashes
and expire after 60 idle days.

The connector exposes five read-only tools:

1. `get_financial_summary`
2. `get_accounts`
3. `get_investments`
4. `search_transactions`
5. `get_net_worth_history`

No MCP tool mutates financial data. Turning the feature off deletes the
encrypted snapshot, unused connect codes, pending authorization codes, and all
access grants.

## Worker storage and deployment

The snapshot uses the existing private Workers KV namespace, encrypted with
AES-256-GCM and a dedicated `CLAUDE_SNAPSHOT_ENCRYPTION_KEY`. That key must be
different from `TOKEN_ENCRYPTION_KEY` and must be configured as a Worker secret
before deployment. Neither key enters the iOS app or git.

Before production use:

1. Set `CLAUDE_SNAPSHOT_ENCRYPTION_KEY` in Cloudflare.
2. Deploy `PlaidWorker`.
3. Enable Claude.ai Access in the app and verify the first snapshot succeeds.
4. Add the MCP URL in Claude.ai Settings → Connectors and authenticate with a
   freshly generated app code.
5. Call each read-only tool, then turn access off and verify the connector is
   denied.

Steps 1 and 2 were completed on 2026-07-30 with Worker version
`6279527f-90d2-48e1-ba63-fa31521fe06a`. Production smoke checks passed for
health, OAuth discovery, MCP initialization, the five-tool manifest, and the
unauthorized-call challenge. Steps 3–5 require the updated app on the user's
iPhone and Claude.ai account.
