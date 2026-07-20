import type {
  Env,
  NormalizedHoldings,
  PublicPlaidItem,
} from "./types";

type JsonObject = Record<string, unknown>;

export class PlaidRequestError extends Error {
  constructor(
    public readonly status: number,
    public readonly errorCode: string,
    public readonly requestId: string | null,
  ) {
    super(`Plaid request failed: ${errorCode}`);
  }
}

function plaidBaseURL(environment: Env["PLAID_ENV"]): string {
  return `https://${environment}.plaid.com`;
}

function countryCodes(env: Env): string[] {
  return env.PLAID_COUNTRY_CODES.split(",")
    .map((value) => value.trim().toUpperCase())
    .filter(Boolean);
}

export async function plaidPost<T>(
  env: Env,
  path: string,
  body: JsonObject,
): Promise<T> {
  const response = await fetch(`${plaidBaseURL(env.PLAID_ENV)}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_id: env.PLAID_CLIENT_ID,
      secret: env.PLAID_SECRET,
      ...body,
    }),
    signal: AbortSignal.timeout(30_000),
  });
  const payload = (await response.json()) as JsonObject;
  if (!response.ok) {
    throw new PlaidRequestError(
      response.status,
      stringValue(payload.error_code) ?? "PLAID_ERROR",
      stringValue(payload.request_id),
    );
  }
  return payload as T;
}

export interface LinkTokenResult {
  link_token: string;
  expiration?: string;
}

export async function createLinkToken(env: Env): Promise<LinkTokenResult> {
  return plaidPost<LinkTokenResult>(env, "/link/token/create", {
    user: { client_user_id: "networth-personal-user" },
    client_name: env.PLAID_CLIENT_NAME,
    products: ["investments"],
    country_codes: countryCodes(env),
    language: "en",
    redirect_uri: env.PLAID_REDIRECT_URI,
  });
}

export interface ExchangeResult {
  access_token: string;
  item_id: string;
}

export async function exchangePublicToken(
  env: Env,
  publicToken: string,
): Promise<ExchangeResult> {
  return plaidPost<ExchangeResult>(env, "/item/public_token/exchange", {
    public_token: publicToken,
  });
}

interface ItemGetResult {
  item?: {
    institution_id?: string | null;
    error?: unknown;
  };
}

interface InstitutionGetResult {
  institution?: { name?: string | null };
}

export async function institutionMetadata(
  env: Env,
  accessToken: string,
): Promise<{ institutionName: string; status: string }> {
  const item = await plaidPost<ItemGetResult>(env, "/item/get", {
    access_token: accessToken,
  });
  const institutionId = item.item?.institution_id;
  let institutionName = "Linked institution";
  if (institutionId) {
    const institution = await plaidPost<InstitutionGetResult>(
      env,
      "/institutions/get_by_id",
      {
        institution_id: institutionId,
        country_codes: countryCodes(env),
      },
    );
    institutionName = institution.institution?.name ?? institutionName;
  }
  return {
    institutionName,
    status: item.item?.error == null ? "healthy" : "needsAttention",
  };
}

export async function removePlaidItem(
  env: Env,
  accessToken: string,
): Promise<void> {
  await plaidPost<JsonObject>(env, "/item/remove", {
    access_token: accessToken,
  });
}

export async function fetchAndNormalizeHoldings(
  env: Env,
  item: PublicPlaidItem,
  accessToken: string,
): Promise<NormalizedHoldings> {
  const payload = await plaidPost<JsonObject>(
    env,
    "/investments/holdings/get",
    { access_token: accessToken },
  );
  return normalizeHoldings(item, payload);
}

export function normalizeHoldings(
  item: PublicPlaidItem,
  payload: JsonObject,
): NormalizedHoldings {
  const accounts = arrayValue(payload.accounts).map((raw) => {
    const account = objectValue(raw);
    const balances = objectValue(account.balances);
    return {
      id: requiredString(account.account_id, "account_id"),
      itemId: item.id,
      institutionName: item.institutionName,
      name: requiredString(account.name, "account name"),
      officialName: stringValue(account.official_name),
      mask: stringValue(account.mask),
      subtype: stringValue(account.subtype),
      currentBalance: numberValue(balances.current),
      availableBalance: numberValue(balances.available),
      isoCurrencyCode: stringValue(balances.iso_currency_code),
      unofficialCurrencyCode: stringValue(
        balances.unofficial_currency_code,
      ),
    };
  });

  const securities = arrayValue(payload.securities).map((raw) => {
    const security = objectValue(raw);
    return {
      id: requiredString(security.security_id, "security_id"),
      name: stringValue(security.name),
      tickerSymbol: stringValue(security.ticker_symbol),
      type: stringValue(security.type),
      closePrice: numberValue(security.close_price),
      closePriceAsOf: isoDateValue(security.close_price_as_of),
      isoCurrencyCode: stringValue(security.iso_currency_code),
      unofficialCurrencyCode: stringValue(
        security.unofficial_currency_code,
      ),
    };
  });

  const holdings = arrayValue(payload.holdings).map((raw) => {
    const holding = objectValue(raw);
    return {
      accountId: requiredString(holding.account_id, "holding account_id"),
      securityId: requiredString(
        holding.security_id,
        "holding security_id",
      ),
      quantity: requiredNumber(holding.quantity, "holding quantity"),
      institutionValue: requiredNumber(
        holding.institution_value,
        "holding institution_value",
      ),
      costBasis: numberValue(holding.cost_basis),
      asOf: isoDateValue(holding.institution_price_as_of),
    };
  });

  const responseItem = objectValue(payload.item);
  return {
    accounts,
    securities,
    holdings,
    itemStatus: responseItem.error == null ? "healthy" : "needsAttention",
  };
}

function objectValue(value: unknown): JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonObject)
    : {};
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function isoDateValue(value: unknown): string | null {
  const parsed = stringValue(value);
  if (parsed === null) return null;
  return /^\d{4}-\d{2}-\d{2}$/.test(parsed)
    ? `${parsed}T00:00:00Z`
    : parsed;
}

function requiredString(value: unknown, field: string): string {
  const parsed = stringValue(value);
  if (parsed === null) throw new Error(`Missing ${field}`);
  return parsed;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function requiredNumber(value: unknown, field: string): number {
  const parsed = numberValue(value);
  if (parsed === null) throw new Error(`Missing ${field}`);
  return parsed;
}
