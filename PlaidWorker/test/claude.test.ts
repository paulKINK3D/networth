import assert from "node:assert/strict";
import test from "node:test";
import {
  authorizeClaudeClient,
  authorizeClaudeMCPRequest,
  completeClaudeAuthorization,
  exchangeClaudeAuthorizationCode,
  generateClaudeConnectCode,
  loadClaudeSnapshot,
  registerClaudeClient,
  revokeClaudeAccess,
  storeClaudeSnapshot,
} from "../src/claude";
import type { Env } from "../src/types";

class MemoryKV {
  values = new Map<string, string>();

  async put(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }

  async get<T>(
    key: string,
    type?: "json",
  ): Promise<T | string | null> {
    const value = this.values.get(key);
    if (value === undefined) return null;
    return type === "json" ? JSON.parse(value) as T : value;
  }

  async delete(key: string): Promise<void> {
    this.values.delete(key);
  }

  async list(options: { prefix?: string }): Promise<{
    keys: Array<{ name: string }>;
    list_complete: true;
    cacheStatus: null;
  }> {
    const prefix = options.prefix ?? "";
    return {
      keys: [...this.values.keys()]
        .filter((key) => key.startsWith(prefix))
        .map((name) => ({ name })),
      list_complete: true,
      cacheStatus: null,
    };
  }
}

function environment(storage: MemoryKV): Env {
  return {
    PLAID_STORAGE: storage as unknown as KVNamespace,
    CLAUDE_SNAPSHOT_ENCRYPTION_KEY:
      Buffer.alloc(32, 9).toString("base64"),
  } as Env;
}

test("financial snapshots are validated, encrypted, and recoverable", async () => {
  const storage = new MemoryKV();
  const env = environment(storage);
  const snapshot = {
    schemaVersion: 1,
    generatedAt: "2026-07-30T12:00:00.000Z",
    primarySource: "plaid",
    accounts: [{ name: "Sensitive Checking" }],
    manualAssets: [],
    holdings: [],
    transactions: [],
    netWorthHistory: [],
  };

  await storeClaudeSnapshot(
    new Request("https://worker.example/v1/claude/snapshot", {
      method: "PUT",
      body: JSON.stringify(snapshot),
    }),
    env,
  );

  const stored = storage.values.get("claude:snapshot:v1") ?? "";
  assert.equal(stored.includes("Sensitive Checking"), false);
  assert.deepEqual(await loadClaudeSnapshot(env), snapshot);
});

test("connect codes are short, readable, and expire in ten minutes", async () => {
  const storage = new MemoryKV();
  const result = await generateClaudeConnectCode(environment(storage));

  assert.match(result.code, /^[A-HJ-NP-Z2-9]{6}$/);
  const lifetime =
    new Date(result.expires_at).getTime() - Date.now();
  assert.ok(lifetime > 9 * 60 * 1_000);
  assert.ok(lifetime <= 10 * 60 * 1_000);
});

test("OAuth PKCE links one connect code and revocation invalidates access", async () => {
  const storage = new MemoryKV();
  const env = environment(storage);
  const redirectURI = "https://claude.example/callback";
  const registration = await registerClaudeClient(
    new Request("https://worker.example/register", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        client_name: "Claude",
        redirect_uris: [redirectURI],
      }),
    }),
    env,
  );
  const client = await registration.json() as { client_id: string };
  const verifier = "pkce-verifier-with-enough-entropy-123456789";
  const challenge = await sha256Base64URL(verifier);
  const authorizeURL = new URL("https://worker.example/authorize");
  authorizeURL.search = new URLSearchParams({
    client_id: client.client_id,
    redirect_uri: redirectURI,
    response_type: "code",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state: "state-value",
    scope: "mcp",
  }).toString();
  const invalidScopeURL = new URL(authorizeURL);
  invalidScopeURL.searchParams.set("scope", "write");
  assert.equal(
    (await authorizeClaudeClient(
      new Request(invalidScopeURL),
      env,
    )).status,
    400,
  );
  assert.equal(
    (await authorizeClaudeClient(
      new Request(authorizeURL),
      env,
    )).status,
    200,
  );

  const connect = await generateClaudeConnectCode(env);
  const completed = await completeClaudeAuthorization(
    formRequest("https://worker.example/authorize/complete", {
      client_id: client.client_id,
      redirect_uri: redirectURI,
      code_challenge: challenge,
      state: "state-value",
      scope: "mcp",
      connect_code: connect.code,
    }),
    env,
  );
  assert.equal(completed.status, 302);
  const redirected = new URL(completed.headers.get("location") ?? "");
  const authorizationCode = redirected.searchParams.get("code") ?? "";
  assert.equal(redirected.searchParams.get("state"), "state-value");

  const tokenResponse = await exchangeClaudeAuthorizationCode(
    formRequest("https://worker.example/token", {
      grant_type: "authorization_code",
      code: authorizationCode,
      client_id: client.client_id,
      redirect_uri: redirectURI,
      code_verifier: verifier,
    }),
    env,
  );
  const token = await tokenResponse.json() as {
    access_token: string;
  };
  const authorizedRequest = new Request(
    "https://worker.example/mcp",
    {
      headers: {
        authorization: `Bearer ${token.access_token}`,
      },
    },
  );
  assert.equal(
    await authorizeClaudeMCPRequest(authorizedRequest, env),
    true,
  );

  await revokeClaudeAccess(env);

  assert.equal(
    await authorizeClaudeMCPRequest(authorizedRequest, env),
    false,
  );
});

function formRequest(
  url: string,
  fields: Record<string, string>,
): Request {
  return new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(fields),
  });
}

async function sha256Base64URL(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Buffer.from(digest).toString("base64url");
}
