import { isAuthorized } from "./auth";
import { decryptAccessToken, encryptAccessToken } from "./crypto";
import {
  createLinkToken,
  exchangePublicToken,
  fetchAndNormalizeHoldings,
  institutionMetadata,
  PlaidRequestError,
  removePlaidItem,
} from "./plaid";
import { loadItems, saveItems } from "./storage";
import type {
  Env,
  PlaidAccountResponse,
  PlaidHoldingResponse,
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

      if (!(await isAuthorized(request, env.BACKEND_BEARER_TOKEN))) {
        return json(
          { error: "unauthorized" },
          401,
          { "WWW-Authenticate": "Bearer" },
        );
      }

      if (
        request.method === "POST" &&
        url.pathname === `${apiPrefix}/link-token`
      ) {
        const result = await createLinkToken(env);
        return json({
          linkToken: result.link_token,
          expiration: result.expiration ?? null,
        });
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

      const itemPrefix = `${apiPrefix}/items/`;
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

async function exchange(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  const publicToken = body.publicToken;
  if (typeof publicToken !== "string" || publicToken.length === 0) {
    throw new BadRequestError("publicToken is required");
  }

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
  const items = await loadItems(env.PLAID_STORAGE);
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

  await saveItems(env.PLAID_STORAGE, updatedItems);
  return json({
    items: updatedItems.map(publicItem),
    accounts,
    securities: [...securitiesByID.values()],
    holdings: holdingRows,
  });
}

async function removeItem(id: string, env: Env): Promise<Response> {
  const items = await loadItems(env.PLAID_STORAGE);
  const item = items.find((candidate) => candidate.id === id);
  if (!item) return json({ error: "item_not_found" }, 404);
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
  };
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
