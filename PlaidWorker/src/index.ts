import { isAuthorized } from "./auth";
import {
  authorizationServerMetadata,
  authorizeClaudeClient,
  ClaudeRequestError,
  completeClaudeAuthorization,
  exchangeClaudeAuthorizationCode,
  generateClaudeConnectCode,
  protectedResourceMetadata,
  registerClaudeClient,
  revokeClaudeAccess,
  storeClaudeSnapshot,
} from "./claude";
import { decryptAccessToken, encryptAccessToken } from "./crypto";
import {
  inferTransaction,
  InferenceRequestError,
  parseInferenceInput,
} from "./inference";
import {
  createLinkToken,
  exchangePublicToken,
  fetchAndNormalizeHoldings,
  fetchAndNormalizeTransactions,
  institutionMetadata,
  mergeProducts,
  PlaidRequestError,
  removePlaidItem,
} from "./plaid";
import { handleMCPRequest } from "./mcp";
import { loadItems, saveItems } from "./storage";
import type {
  Env,
  PlaidAccountResponse,
  PlaidHoldingResponse,
  PlaidProduct,
  PlaidSecurityResponse,
  PublicPlaidItem,
  StoredPlaidItem,
} from "./types";

class BadRequestError extends Error {}

const apiPrefix = "/v1/plaid";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return json({ status: "ok" });
      }
      if (
        request.method === "GET" &&
        url.pathname === "/.well-known/apple-app-site-association"
      ) {
        return appleAppSiteAssociation(env);
      }
      if (request.method === "GET" && url.pathname === "/plaid/oauth") {
        return oauthFallback();
      }
      if (
        request.method === "GET" &&
        url.pathname === "/.well-known/oauth-authorization-server"
      ) {
        return json(authorizationServerMetadata(request));
      }
      if (
        request.method === "GET" &&
        url.pathname === "/.well-known/oauth-protected-resource"
      ) {
        return json(protectedResourceMetadata(request));
      }
      if (request.method === "POST" && url.pathname === "/register") {
        return registerClaudeClient(request, env);
      }
      if (request.method === "GET" && url.pathname === "/authorize") {
        return authorizeClaudeClient(request, env);
      }
      if (
        request.method === "POST" &&
        url.pathname === "/authorize/complete"
      ) {
        return completeClaudeAuthorization(request, env);
      }
      if (request.method === "POST" && url.pathname === "/token") {
        return exchangeClaudeAuthorizationCode(request, env);
      }
      if (url.pathname === "/mcp") {
        if (request.method === "POST") {
          return handleMCPRequest(request, env);
        }
        return json({ error: "method_not_allowed" }, 405);
      }

      if (!(await isAuthorized(request, env.BACKEND_BEARER_TOKEN))) {
        return json(
          { error: "unauthorized" },
          401,
          { "WWW-Authenticate": "Bearer" },
        );
      }

      if (
        request.method === "PUT" &&
        url.pathname === "/v1/claude/snapshot"
      ) {
        return json(await storeClaudeSnapshot(request, env));
      }
      if (
        request.method === "POST" &&
        url.pathname === "/v1/claude/connect-code"
      ) {
        return json(await generateClaudeConnectCode(env));
      }
      if (
        request.method === "DELETE" &&
        url.pathname === "/v1/claude/access"
      ) {
        await revokeClaudeAccess(env);
        return json({ deleted: true });
      }

      if (
        request.method === "POST" &&
        url.pathname === `${apiPrefix}/link-token`
      ) {
        return linkToken(request, env);
      }

      if (
        request.method === "POST" &&
        url.pathname === `${apiPrefix}/exchange`
      ) {
        return exchange(request, env);
      }

      if (
        request.method === "GET" &&
        url.pathname === `${apiPrefix}/items`
      ) {
        const items = await loadItems(env.PLAID_STORAGE);
        return json({ items: items.map(publicItem) });
      }

      if (
        request.method === "GET" &&
        url.pathname === `${apiPrefix}/investments/holdings`
      ) {
        return holdings(env);
      }

      if (
        request.method === "POST" &&
        url.pathname === `${apiPrefix}/transactions/sync`
      ) {
        return transactionsSync(request, env);
      }

      if (
        request.method === "POST" &&
        url.pathname === `${apiPrefix}/inference/transaction`
      ) {
        const result = await inferTransaction(
          env,
          parseInferenceInput(await readJSON(request)),
        );
        return json(result);
      }

      const itemPrefix = `${apiPrefix}/items/`;
      if (
        request.method === "POST" &&
        url.pathname.startsWith(itemPrefix) &&
        url.pathname.endsWith("/enable-transactions")
      ) {
        const encodedID = url.pathname.slice(
          itemPrefix.length,
          -"/enable-transactions".length,
        );
        if (!encodedID || encodedID.includes("/")) {
          throw new BadRequestError("A single Item ID is required");
        }
        return enableTransactions(decodeURIComponent(encodedID), env);
      }
      if (request.method === "DELETE" && url.pathname.startsWith(itemPrefix)) {
        const encodedID = url.pathname.slice(itemPrefix.length);
        if (!encodedID || encodedID.includes("/")) {
          throw new BadRequestError("A single Item ID is required");
        }
        return removeItem(decodeURIComponent(encodedID), env);
      }

      return json({ error: "not_found" }, 404);
    } catch (error) {
      return errorResponse(error);
    }
  },
};

async function linkToken(request: Request, env: Env): Promise<Response> {
  const body = await readOptionalJSON(request);
  const modeValue = body.mode ?? "investments";
  if (
    modeValue !== "investments" &&
    modeValue !== "transactions" &&
    modeValue !== "updateTransactions"
  ) {
    throw new BadRequestError("Unsupported Link mode");
  }
  let accessToken: string | undefined;
  if (modeValue === "updateTransactions") {
    const itemID = body.itemId;
    if (typeof itemID !== "string" || !itemID) {
      throw new BadRequestError("itemId is required for update mode");
    }
    const item = (await loadItems(env.PLAID_STORAGE)).find(
      (candidate) => candidate.id === itemID,
    );
    if (!item) throw new BadRequestError("Unknown Plaid Item");
    accessToken = await decryptAccessToken(
      item.accessToken,
      env.TOKEN_ENCRYPTION_KEY,
    );
  }
  const result = await createLinkToken(env, modeValue, accessToken);
  return json({
    linkToken: result.link_token,
    expiration: result.expiration ?? null,
  });
}

async function exchange(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  const publicToken = body.publicToken;
  if (typeof publicToken !== "string" || publicToken.length === 0) {
    throw new BadRequestError("publicToken is required");
  }
  const products = parseProducts(body.products, ["investments"]);

  const result = await exchangePublicToken(env, publicToken);
  let metadata = {
    institutionName: "Linked institution",
    status: "healthy",
  };
  try {
    metadata = await institutionMetadata(env, result.access_token);
  } catch (error) {
    if (error instanceof PlaidRequestError) logPlaidError(error);
  }

  try {
    const encryptedToken = await encryptAccessToken(
      result.access_token,
      env.TOKEN_ENCRYPTION_KEY,
    );
    const items = await loadItems(env.PLAID_STORAGE);
    const stored: StoredPlaidItem = {
      id: result.item_id,
      institutionName: metadata.institutionName,
      status: metadata.status,
      lastSyncedAt: null,
      products,
      accessToken: encryptedToken,
    };
    const nextItems = items.filter((item) => item.id !== stored.id);
    nextItems.push(stored);
    await saveItems(env.PLAID_STORAGE, nextItems);
    return json({ item: publicItem(stored) });
  } catch (error) {
    try {
      await removePlaidItem(env, result.access_token);
    } catch (cleanupError) {
      if (cleanupError instanceof PlaidRequestError) {
        logPlaidError(cleanupError);
      }
    }
    throw error;
  }
}

async function holdings(env: Env): Promise<Response> {
  const allItems = await loadItems(env.PLAID_STORAGE);
  const items = allItems.filter((item) => item.products.includes("investments"));
  const accounts: PlaidAccountResponse[] = [];
  const securitiesByID = new Map<string, PlaidSecurityResponse>();
  const holdingRows: PlaidHoldingResponse[] = [];
  const syncedAt = new Date().toISOString();
  const updatedItems: StoredPlaidItem[] = [];

  for (const item of items) {
    const accessToken = await decryptAccessToken(
      item.accessToken,
      env.TOKEN_ENCRYPTION_KEY,
    );
    const normalized = await fetchAndNormalizeHoldings(
      env,
      publicItem(item),
      accessToken,
    );
    accounts.push(...normalized.accounts);
    for (const security of normalized.securities) {
      securitiesByID.set(security.id, security);
    }
    holdingRows.push(...normalized.holdings);
    updatedItems.push({
      ...item,
      status: normalized.itemStatus,
      lastSyncedAt: syncedAt,
    });
  }

  const updatedByID = new Map(updatedItems.map((item) => [item.id, item]));
  await saveItems(
    env.PLAID_STORAGE,
    allItems.map((item) => updatedByID.get(item.id) ?? item),
  );
  return json({
    items: updatedItems.map(publicItem),
    accounts,
    securities: [...securitiesByID.values()],
    holdings: holdingRows,
  });
}

async function transactionsSync(
  request: Request,
  env: Env,
): Promise<Response> {
  const body = await readJSON(request);
  const itemID = body.itemId;
  if (typeof itemID !== "string" || !itemID) {
    throw new BadRequestError("itemId is required");
  }
  const cursor =
    body.cursor == null
      ? null
      : typeof body.cursor === "string"
        ? body.cursor
        : undefined;
  if (cursor === undefined) throw new BadRequestError("cursor must be a string");
  const count =
    body.count == null
      ? 500
      : typeof body.count === "number" && Number.isInteger(body.count)
        ? body.count
        : undefined;
  if (count === undefined || count < 1 || count > 500) {
    throw new BadRequestError("count must be between 1 and 500");
  }

  const items = await loadItems(env.PLAID_STORAGE);
  const item = items.find((candidate) => candidate.id === itemID);
  if (!item) return json({ error: "item_not_found" }, 404);
  if (!item.products.includes("transactions")) {
    return json({ error: "transactions_not_enabled" }, 409);
  }
  const accessToken = await decryptAccessToken(
    item.accessToken,
    env.TOKEN_ENCRYPTION_KEY,
  );
  const syncedAt = new Date().toISOString();
  const normalized = await fetchAndNormalizeTransactions(
    env,
    publicItem(item),
    accessToken,
    cursor,
    count,
  );
  const updatedItem: StoredPlaidItem = {
    ...item,
    status: normalized.itemStatus,
    lastSyncedAt: syncedAt,
  };
  await saveItems(
    env.PLAID_STORAGE,
    items.map((candidate) =>
      candidate.id === itemID ? updatedItem : candidate,
    ),
  );
  return json({
    item: publicItem(updatedItem),
    accounts: normalized.accounts,
    added: normalized.added,
    modified: normalized.modified,
    removed: normalized.removed,
    nextCursor: normalized.nextCursor,
    hasMore: normalized.hasMore,
    updateStatus: normalized.updateStatus,
  });
}

async function enableTransactions(id: string, env: Env): Promise<Response> {
  const items = await loadItems(env.PLAID_STORAGE);
  const item = items.find((candidate) => candidate.id === id);
  if (!item) return json({ error: "item_not_found" }, 404);
  const updated: StoredPlaidItem = {
    ...item,
    products: mergeProducts(item.products, ["transactions"]),
  };
  await saveItems(
    env.PLAID_STORAGE,
    items.map((candidate) => (candidate.id === id ? updated : candidate)),
  );
  return json({ item: publicItem(updated) });
}

async function removeItem(id: string, env: Env): Promise<Response> {
  const items = await loadItems(env.PLAID_STORAGE);
  const item = items.find((candidate) => candidate.id === id);
  // Idempotent so the app can retry local cleanup if it was interrupted after
  // Plaid and KV removal succeeded.
  if (!item) return new Response(null, { status: 204 });
  const accessToken = await decryptAccessToken(
    item.accessToken,
    env.TOKEN_ENCRYPTION_KEY,
  );
  await removePlaidItem(env, accessToken);
  await saveItems(
    env.PLAID_STORAGE,
    items.filter((candidate) => candidate.id !== id),
  );
  return new Response(null, { status: 204 });
}

function publicItem(item: StoredPlaidItem): PublicPlaidItem {
  return {
    id: item.id,
    institutionName: item.institutionName,
    status: item.status,
    lastSyncedAt: item.lastSyncedAt,
    products: item.products,
  };
}

async function readOptionalJSON(
  request: Request,
): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (!text.trim()) return {};
  if (new TextEncoder().encode(text).byteLength > 16_384) {
    throw new BadRequestError("Request is too large");
  }
  try {
    const value: unknown = JSON.parse(text);
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new BadRequestError("A JSON object is required");
    }
    return value as Record<string, unknown>;
  } catch (error) {
    if (error instanceof BadRequestError) throw error;
    throw new BadRequestError("Valid JSON is required");
  }
}

async function readJSON(request: Request): Promise<Record<string, unknown>> {
  const contentLength = Number(request.headers.get("Content-Length") ?? "0");
  if (contentLength > 16_384) throw new BadRequestError("Request is too large");
  try {
    const text = await request.text();
    if (new TextEncoder().encode(text).byteLength > 16_384) {
      throw new BadRequestError("Request is too large");
    }
    const value: unknown = JSON.parse(text);
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new BadRequestError("A JSON object is required");
    }
    return value as Record<string, unknown>;
  } catch (error) {
    if (error instanceof BadRequestError) throw error;
    throw new BadRequestError("Valid JSON is required");
  }
}

function parseProducts(
  value: unknown,
  fallback: PlaidProduct[],
): PlaidProduct[] {
  if (value == null) return fallback;
  if (!Array.isArray(value) || value.length === 0) {
    throw new BadRequestError("products must be a non-empty array");
  }
  const products: PlaidProduct[] = [];
  for (const product of value) {
    if (product !== "investments" && product !== "transactions") {
      throw new BadRequestError("Unsupported Plaid product");
    }
    if (!products.includes(product)) products.push(product);
  }
  return products;
}

function appleAppSiteAssociation(env: Env): Response {
  return json({
    applinks: {
      details: [
        {
          appIDs: [env.APPLE_APP_ID],
          components: [
            {
              "/": "/plaid/*",
              comment: "Plaid OAuth return path",
            },
          ],
        },
      ],
    },
  });
}

function oauthFallback(): Response {
  return new Response(
    "<!doctype html><title>BlueLava Networth</title><p>Return to BlueLava Networth to continue.</p>",
    {
      status: 200,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
      },
    },
  );
}

function json(
  value: unknown,
  status = 200,
  additionalHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...additionalHeaders,
    },
  });
}

function errorResponse(error: unknown): Response {
  if (error instanceof BadRequestError) {
    return json({ error: "bad_request", message: error.message }, 400);
  }
  if (error instanceof InferenceRequestError) {
    return json(
      {
        error:
          error.status === 400
            ? "bad_request"
            : error.status === 429
              ? "inference_rate_limited"
              : "inference_unavailable",
      },
      error.status,
    );
  }
  if (error instanceof ClaudeRequestError) {
    return json(
      {
        error:
          error.status === 400
            ? "bad_request"
            : error.status === 413
              ? "snapshot_too_large"
              : "claude_connector_unavailable",
      },
      error.status,
    );
  }
  if (error instanceof PlaidRequestError) {
    logPlaidError(error);
    const status = error.status === 429 ? 429 : 502;
    return json(
      {
        error: "plaid_request_failed",
        code: error.errorCode,
        requestId: error.requestId,
      },
      status,
    );
  }
  console.error("Plaid Worker request failed", {
    name: error instanceof Error ? error.name : "UnknownError",
  });
  return json({ error: "internal_error" }, 500);
}

function logPlaidError(error: PlaidRequestError): void {
  console.error("Plaid API request failed", {
    status: error.status,
    code: error.errorCode,
    requestId: error.requestId,
  });
}
