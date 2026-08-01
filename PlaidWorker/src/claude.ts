import {
  decryptClaudeSnapshot,
  encryptClaudeSnapshot,
} from "./crypto";
import type { EncryptedValue, Env } from "./types";

const snapshotKey = "claude:snapshot:v1";
const clientPrefix = "claude:oauth:client:";
const connectCodePrefix = "claude:oauth:connect:";
const authorizationCodePrefix = "claude:oauth:authorization:";
const accessTokenPrefix = "claude:oauth:access:";
const connectCodeTTLSeconds = 10 * 60;
const authorizationCodeTTLSeconds = 10 * 60;
const accessTokenTTLSeconds = 60 * 24 * 60 * 60;
const clientTTLSeconds = 365 * 24 * 60 * 60;
const maximumSnapshotBytes = 10 * 1024 * 1024;

export interface ClaudeFinancialSnapshot {
  schemaVersion: number;
  generatedAt: string;
  primarySource: string;
  accounts: unknown[];
  manualAssets: unknown[];
  holdings: unknown[];
  transactions: unknown[];
  netWorthHistory: unknown[];
}

interface StoredSnapshot {
  schemaVersion: 1;
  encrypted: EncryptedValue;
}

interface OAuthClient {
  clientId: string;
  clientName: string | null;
  redirectUris: string[];
}

interface ConnectCode {
  expiresAt: string;
}

interface AuthorizationCode {
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  scope: string;
  expiresAt: string;
}

interface AccessGrant {
  clientId: string;
  scope: string;
  expiresAt: string;
}

export class ClaudeRequestError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function storeClaudeSnapshot(
  request: Request,
  env: Env,
): Promise<{ generatedAt: string }> {
  if (!env.CLAUDE_SNAPSHOT_ENCRYPTION_KEY?.trim()) {
    throw new ClaudeRequestError(
      503,
      "Claude snapshot encryption is not configured",
    );
  }
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > maximumSnapshotBytes) {
    throw new ClaudeRequestError(413, "Snapshot is too large");
  }
  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > maximumSnapshotBytes) {
    throw new ClaudeRequestError(413, "Snapshot is too large");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new ClaudeRequestError(400, "Snapshot must be valid JSON");
  }
  const snapshot = validateSnapshot(parsed);
  const encrypted = await encryptClaudeSnapshot(
    JSON.stringify(snapshot),
    env.CLAUDE_SNAPSHOT_ENCRYPTION_KEY,
  );
  const stored: StoredSnapshot = {
    schemaVersion: 1,
    encrypted,
  };
  await env.PLAID_STORAGE.put(snapshotKey, JSON.stringify(stored));
  return { generatedAt: snapshot.generatedAt };
}

export async function loadClaudeSnapshot(
  env: Env,
): Promise<ClaudeFinancialSnapshot | null> {
  if (!env.CLAUDE_SNAPSHOT_ENCRYPTION_KEY?.trim()) {
    throw new ClaudeRequestError(
      503,
      "Claude snapshot encryption is not configured",
    );
  }
  const stored = await env.PLAID_STORAGE.get<StoredSnapshot>(
    snapshotKey,
    "json",
  );
  if (stored === null) return null;
  if (stored.schemaVersion !== 1 || stored.encrypted?.version !== 1) {
    throw new ClaudeRequestError(500, "Stored Claude snapshot is unsupported");
  }
  const plaintext = await decryptClaudeSnapshot(
    stored.encrypted,
    env.CLAUDE_SNAPSHOT_ENCRYPTION_KEY,
  );
  return validateSnapshot(JSON.parse(plaintext) as unknown);
}

export async function generateClaudeConnectCode(
  env: Env,
): Promise<{ code: string; expires_at: string }> {
  const code = randomConnectCode();
  const expiresAt = new Date(
    Date.now() + connectCodeTTLSeconds * 1_000,
  ).toISOString();
  const value: ConnectCode = { expiresAt };
  await env.PLAID_STORAGE.put(
    `${connectCodePrefix}${code}`,
    JSON.stringify(value),
    { expirationTtl: connectCodeTTLSeconds },
  );
  return { code, expires_at: expiresAt };
}

export async function revokeClaudeAccess(env: Env): Promise<void> {
  await env.PLAID_STORAGE.delete(snapshotKey);
  for (const prefix of [
    connectCodePrefix,
    authorizationCodePrefix,
    accessTokenPrefix,
  ]) {
    await deletePrefix(env.PLAID_STORAGE, prefix);
  }
}

export function authorizationServerMetadata(request: Request): object {
  const origin = new URL(request.url).origin;
  return {
    issuer: origin,
    authorization_endpoint: `${origin}/authorize`,
    token_endpoint: `${origin}/token`,
    registration_endpoint: `${origin}/register`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    scopes_supported: ["mcp"],
  };
}

export function protectedResourceMetadata(request: Request): object {
  const origin = new URL(request.url).origin;
  return {
    resource: origin,
    authorization_servers: [origin],
    scopes_supported: ["mcp"],
  };
}

export async function registerClaudeClient(
  request: Request,
  env: Env,
): Promise<Response> {
  const body = await readJSONObject(request);
  const redirectUris = Array.isArray(body.redirect_uris)
    ? body.redirect_uris
    : [];
  if (
    redirectUris.length === 0 ||
    redirectUris.length > 10 ||
    redirectUris.some(
      (value) =>
        typeof value !== "string" ||
        value.length === 0 ||
        value.length > 2_048 ||
        !isAllowedRedirectURI(value),
    )
  ) {
    return oauthJSON(
      {
        error: "invalid_redirect_uri",
        error_description: "A valid HTTPS or loopback redirect URI is required",
      },
      400,
    );
  }
  const clientId = `mcp-${randomBase64URLToken(16)}`;
  const client: OAuthClient = {
    clientId,
    clientName:
      typeof body.client_name === "string"
        ? body.client_name.slice(0, 200)
        : null,
    redirectUris: redirectUris as string[],
  };
  await env.PLAID_STORAGE.put(
    `${clientPrefix}${clientId}`,
    JSON.stringify(client),
    { expirationTtl: clientTTLSeconds },
  );
  return oauthJSON(
    {
      client_id: client.clientId,
      client_name: client.clientName,
      redirect_uris: client.redirectUris,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code"],
      response_types: ["code"],
      application_type: "native",
    },
    201,
  );
}

export async function authorizeClaudeClient(
  request: Request,
  env: Env,
): Promise<Response> {
  const url = new URL(request.url);
  const clientId = url.searchParams.get("client_id") ?? "";
  const redirectUri = url.searchParams.get("redirect_uri") ?? "";
  const responseType = url.searchParams.get("response_type") ?? "";
  const codeChallenge = url.searchParams.get("code_challenge") ?? "";
  const codeChallengeMethod =
    url.searchParams.get("code_challenge_method") ?? "";
  const state = url.searchParams.get("state") ?? "";
  const scope = url.searchParams.get("scope") ?? "mcp";
  const client = await loadClient(env, clientId);
  if (
    responseType !== "code" ||
    scope !== "mcp" ||
    !client ||
    !client.redirectUris.includes(redirectUri) ||
    !codeChallenge ||
    codeChallengeMethod !== "S256"
  ) {
    return authorizationError("The authorization request is invalid.");
  }
  return new Response(
    renderAuthorizationPage({
      clientId,
      redirectUri,
      codeChallenge,
      state,
      scope,
      message: "",
    }),
    { headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

export async function completeClaudeAuthorization(
  request: Request,
  env: Env,
): Promise<Response> {
  const form = await request.formData();
  const clientId = stringValue(form.get("client_id"));
  const redirectUri = stringValue(form.get("redirect_uri"));
  const codeChallenge = stringValue(form.get("code_challenge"));
  const state = stringValue(form.get("state"));
  const scope = stringValue(form.get("scope")) || "mcp";
  const connectCode = stringValue(form.get("connect_code"))
    .trim()
    .toUpperCase();
  const client = await loadClient(env, clientId);
  const connect = await env.PLAID_STORAGE.get<ConnectCode>(
    `${connectCodePrefix}${connectCode}`,
    "json",
  );
  if (
    !client ||
    !client.redirectUris.includes(redirectUri) ||
    !codeChallenge ||
    scope !== "mcp" ||
    !connect ||
    new Date(connect.expiresAt) <= new Date()
  ) {
    return new Response(
      renderAuthorizationPage({
        clientId,
        redirectUri,
        codeChallenge,
        state,
        scope,
        message: "The connect code is invalid or expired.",
      }),
      {
        status: 400,
        headers: { "content-type": "text/html; charset=utf-8" },
      },
    );
  }
  await env.PLAID_STORAGE.delete(`${connectCodePrefix}${connectCode}`);
  const code = randomBase64URLToken(32);
  const expiresAt = new Date(
    Date.now() + authorizationCodeTTLSeconds * 1_000,
  ).toISOString();
  const authorization: AuthorizationCode = {
    clientId,
    redirectUri,
    codeChallenge,
    scope,
    expiresAt,
  };
  await env.PLAID_STORAGE.put(
    `${authorizationCodePrefix}${code}`,
    JSON.stringify(authorization),
    { expirationTtl: authorizationCodeTTLSeconds },
  );
  const redirect = new URL(redirectUri);
  redirect.searchParams.set("code", code);
  if (state) redirect.searchParams.set("state", state);
  return Response.redirect(redirect.toString(), 302);
}

export async function exchangeClaudeAuthorizationCode(
  request: Request,
  env: Env,
): Promise<Response> {
  const form = await request.formData();
  if (stringValue(form.get("grant_type")) !== "authorization_code") {
    return oauthJSON({ error: "unsupported_grant_type" }, 400);
  }
  const code = stringValue(form.get("code"));
  const clientId = stringValue(form.get("client_id"));
  const redirectUri = stringValue(form.get("redirect_uri"));
  const codeVerifier = stringValue(form.get("code_verifier"));
  const key = `${authorizationCodePrefix}${code}`;
  const authorization = await env.PLAID_STORAGE.get<AuthorizationCode>(
    key,
    "json",
  );
  if (
    !authorization ||
    new Date(authorization.expiresAt) <= new Date() ||
    authorization.clientId !== clientId ||
    authorization.redirectUri !== redirectUri ||
    !codeVerifier
  ) {
    return oauthJSON({ error: "invalid_grant" }, 400);
  }
  const computedChallenge = await sha256Base64URL(codeVerifier);
  if (computedChallenge !== authorization.codeChallenge) {
    return oauthJSON(
      {
        error: "invalid_grant",
        error_description: "PKCE verification failed",
      },
      400,
    );
  }
  await env.PLAID_STORAGE.delete(key);
  const accessToken = randomBase64URLToken(32);
  const tokenHash = await sha256Base64URL(accessToken);
  const expiresAt = new Date(
    Date.now() + accessTokenTTLSeconds * 1_000,
  ).toISOString();
  const grant: AccessGrant = {
    clientId,
    scope: authorization.scope,
    expiresAt,
  };
  await env.PLAID_STORAGE.put(
    `${accessTokenPrefix}${tokenHash}`,
    JSON.stringify(grant),
    { expirationTtl: accessTokenTTLSeconds },
  );
  return oauthJSON({
    access_token: accessToken,
    token_type: "Bearer",
    scope: authorization.scope,
  });
}

export async function authorizeClaudeMCPRequest(
  request: Request,
  env: Env,
): Promise<boolean> {
  const match = request.headers
    .get("authorization")
    ?.match(/^Bearer\s+(.+)$/i);
  if (!match?.[1]) return false;
  const tokenHash = await sha256Base64URL(match[1].trim());
  const key = `${accessTokenPrefix}${tokenHash}`;
  const grant = await env.PLAID_STORAGE.get<AccessGrant>(key, "json");
  if (
    !grant ||
    grant.scope !== "mcp" ||
    new Date(grant.expiresAt) <= new Date()
  ) {
    return false;
  }
  const expiresAt = new Date(
    Date.now() + accessTokenTTLSeconds * 1_000,
  ).toISOString();
  await env.PLAID_STORAGE.put(
    key,
    JSON.stringify({ ...grant, expiresAt }),
    { expirationTtl: accessTokenTTLSeconds },
  );
  return true;
}

export function mcpUnauthorizedResponse(request: Request): Response {
  const origin = new URL(request.url).origin;
  return new Response(
    JSON.stringify({
      error: "unauthorized",
      error_description: "Connect Networth to Claude.ai first",
    }),
    {
      status: 401,
      headers: {
        "content-type": "application/json",
        "www-authenticate":
          `Bearer realm="networth-mcp", ` +
          `resource_metadata="${origin}/.well-known/oauth-protected-resource"`,
      },
    },
  );
}

function validateSnapshot(value: unknown): ClaudeFinancialSnapshot {
  if (!isObject(value)) {
    throw new ClaudeRequestError(400, "Snapshot must be an object");
  }
  const generatedAt = value.generatedAt;
  if (
    value.schemaVersion !== 1 ||
    typeof generatedAt !== "string" ||
    !Number.isFinite(Date.parse(generatedAt)) ||
    typeof value.primarySource !== "string"
  ) {
    throw new ClaudeRequestError(400, "Snapshot metadata is invalid");
  }
  for (const key of [
    "accounts",
    "manualAssets",
    "holdings",
    "transactions",
    "netWorthHistory",
  ]) {
    if (!Array.isArray(value[key])) {
      throw new ClaudeRequestError(400, `Snapshot ${key} is invalid`);
    }
  }
  return value as unknown as ClaudeFinancialSnapshot;
}

async function loadClient(
  env: Env,
  clientId: string,
): Promise<OAuthClient | null> {
  if (!clientId) return null;
  return env.PLAID_STORAGE.get<OAuthClient>(
    `${clientPrefix}${clientId}`,
    "json",
  );
}

async function deletePrefix(
  storage: KVNamespace,
  prefix: string,
): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await storage.list({ prefix, cursor });
    await Promise.all(page.keys.map((key) => storage.delete(key.name)));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
}

function randomConnectCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return Array.from(bytes)
    .map((byte) => alphabet[byte % alphabet.length])
    .join("");
}

function randomBase64URLToken(byteLength: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function sha256Base64URL(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  const bytes = new Uint8Array(digest);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function readJSONObject(
  request: Request,
): Promise<Record<string, unknown>> {
  try {
    const value = (await request.json()) as unknown;
    if (isObject(value)) return value;
  } catch {
    // Fall through to a consistent OAuth error.
  }
  throw new ClaudeRequestError(400, "A JSON object is required");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAllowedRedirectURI(value: string): boolean {
  try {
    const url = new URL(value);
    if (url.protocol === "https:") return true;
    return (
      url.protocol === "http:" &&
      (url.hostname === "127.0.0.1" ||
        url.hostname === "localhost" ||
        url.hostname === "::1")
    );
  } catch {
    return false;
  }
}

function stringValue(value: FormDataEntryValue | null): string {
  return typeof value === "string" ? value : "";
}

function oauthJSON(body: object, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function authorizationError(message: string): Response {
  return new Response(
    `<!doctype html><html><body><h1>Authorization Error</h1><p>${escapeHTML(
      message,
    )}</p></body></html>`,
    {
      status: 400,
      headers: { "content-type": "text/html; charset=utf-8" },
    },
  );
}

function renderAuthorizationPage(input: {
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  state: string;
  scope: string;
  message: string;
}): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Authorize Networth</title>
<style>
body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 28rem; margin: 4rem auto; padding: 0 1rem; color: #0f172a; }
h1 { font-size: 1.5rem; margin-bottom: 0.5rem; }
label { display: block; font-weight: 600; margin: 1.5rem 0 0.5rem; }
input { width: 100%; padding: 0.75rem; font: inherit; font-size: 1.25rem; text-transform: uppercase; letter-spacing: 0.1em; box-sizing: border-box; }
button { margin-top: 1.5rem; padding: 0.75rem 1.5rem; font: inherit; font-weight: 600; background: #1e3a8a; color: white; border: 0; border-radius: 8px; }
.error { color: #b91c1c; }
.muted { color: #64748b; font-size: 0.9rem; }
</style>
</head>
<body>
<h1>Connect Networth</h1>
<p>Generate a connect code in Networth under Settings → Claude.ai Access.</p>
${input.message ? `<p class="error">${escapeHTML(input.message)}</p>` : ""}
<form method="POST" action="/authorize/complete">
<input type="hidden" name="client_id" value="${escapeHTML(input.clientId)}">
<input type="hidden" name="redirect_uri" value="${escapeHTML(input.redirectUri)}">
<input type="hidden" name="code_challenge" value="${escapeHTML(input.codeChallenge)}">
<input type="hidden" name="state" value="${escapeHTML(input.state)}">
<input type="hidden" name="scope" value="${escapeHTML(input.scope)}">
<label for="connect_code">Connect code</label>
<input id="connect_code" name="connect_code" maxlength="6" required autofocus>
<button type="submit">Connect Claude</button>
</form>
<p class="muted">The code expires after 10 minutes. Claude receives read-only access to the financial copy you enabled in Networth.</p>
</body>
</html>`;
}

function escapeHTML(value: string): string {
  return value.replace(
    /[<>&"']/g,
    (character) =>
      ({
        "<": "&lt;",
        ">": "&gt;",
        "&": "&amp;",
        '"': "&quot;",
        "'": "&#39;",
      })[character] ?? character,
  );
}
