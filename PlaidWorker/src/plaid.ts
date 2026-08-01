import type {
  Env,
  NormalizedHoldings,
  NormalizedTransactions,
  PlaidAccountResponse,
  PlaidProduct,
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

export type LinkMode = "investments" | "transactions" | "updateTransactions";

export async function createLinkToken(
  env: Env,
  mode: LinkMode,
  accessToken?: string,
): Promise<LinkTokenResult> {
  const common: JsonObject = {
    user: { client_user_id: "networth-personal-user" },
    client_name: env.PLAID_CLIENT_NAME,
    country_codes: countryCodes(env),
    language: "en",
    redirect_uri: env.PLAID_REDIRECT_URI,
  };
  if (mode === "investments") {
    return plaidPost<LinkTokenResult>(env, "/link/token/create", {
      ...common,
      products: ["investments"],
    });
  }
  if (mode === "transactions") {
    return plaidPost<LinkTokenResult>(env, "/link/token/create", {
      ...common,
      products: ["transactions"],
      transactions: { days_requested: 730 },
    });
  }
  if (!accessToken) throw new Error("Update mode requires an access token");
  return plaidPost<LinkTokenResult>(env, "/link/token/create", {
    ...common,
    access_token: accessToken,
    additional_consented_products: ["transactions"],
    update: { account_selection_enabled: true },
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
  const accounts = arrayValue(payload.accounts).map((raw) =>
    normalizeAccount(item, raw),
  );

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

export async function fetchAndNormalizeTransactions(
  env: Env,
  item: PublicPlaidItem,
  accessToken: string,
  cursor: string | null,
  count = 500,
): Promise<NormalizedTransactions> {
  const payload = await plaidPost<JsonObject>(env, "/transactions/sync", {
    access_token: accessToken,
    cursor: cursor ?? undefined,
    count: Math.max(1, Math.min(500, count)),
    options: {
      include_original_description: true,
      personal_finance_category_version: "v2",
      ...(cursor === null ? { days_requested: 730 } : {}),
    },
  });
  const accountsPayload = await plaidPost<JsonObject>(env, "/accounts/get", {
    access_token: accessToken,
  });
  const normalized = normalizeTransactions(item, payload);
  normalized.accounts = arrayValue(accountsPayload.accounts).map((raw) =>
    normalizeAccount(item, raw),
  );
  return normalized;
}

export function normalizeTransactions(
  item: PublicPlaidItem,
  payload: JsonObject,
): NormalizedTransactions {
  const responseItem = objectValue(payload.item);
  return {
    accounts: arrayValue(payload.accounts).map((raw) =>
      normalizeAccount(item, raw),
    ),
    added: arrayValue(payload.added).map(normalizeTransaction),
    modified: arrayValue(payload.modified).map(normalizeTransaction),
    removed: arrayValue(payload.removed).map((raw) =>
      requiredString(objectValue(raw).transaction_id, "removed transaction_id"),
    ),
    nextCursor: requiredString(payload.next_cursor, "next_cursor"),
    hasMore: booleanValue(payload.has_more) ?? false,
    updateStatus: stringValue(payload.transactions_update_status),
    itemStatus: responseItem.error == null ? "healthy" : "needsAttention",
  };
}

function normalizeAccount(
  item: PublicPlaidItem,
  raw: unknown,
): PlaidAccountResponse {
  const account = objectValue(raw);
  const balances = objectValue(account.balances);
  return {
    id: requiredString(account.account_id, "account_id"),
    itemId: item.id,
    institutionName: item.institutionName,
    name: requiredString(account.name, "account name"),
    officialName: stringValue(account.official_name),
    mask: stringValue(account.mask),
    type: stringValue(account.type),
    subtype: stringValue(account.subtype),
    currentBalance: numberValue(balances.current),
    availableBalance: numberValue(balances.available),
    limit: numberValue(balances.limit),
    isoCurrencyCode: stringValue(balances.iso_currency_code),
    unofficialCurrencyCode: stringValue(balances.unofficial_currency_code),
  };
}

function normalizeTransaction(raw: unknown) {
  const transaction = objectValue(raw);
  const category = objectValue(transaction.personal_finance_category);
  const counterparties = arrayValue(transaction.counterparties);
  const firstCounterparty = objectValue(counterparties[0]);
  return {
    id: requiredString(transaction.transaction_id, "transaction_id"),
    accountId: requiredString(transaction.account_id, "transaction account_id"),
    date: requiredString(transaction.date, "transaction date"),
    authorizedDate: stringValue(transaction.authorized_date),
    amount: requiredNumber(transaction.amount, "transaction amount"),
    pending: booleanValue(transaction.pending) ?? false,
    pendingTransactionId: stringValue(transaction.pending_transaction_id),
    name: requiredString(transaction.name, "transaction name"),
    originalDescription: stringValue(transaction.original_description),
    merchantName: stringValue(transaction.merchant_name),
    merchantEntityId: stringValue(transaction.merchant_entity_id),
    counterpartyName: stringValue(firstCounterparty.name),
    counterpartyType: stringValue(firstCounterparty.type),
    counterpartyEntityId: stringValue(firstCounterparty.entity_id),
    counterpartyConfidence: stringValue(firstCounterparty.confidence_level),
    paymentChannel: stringValue(transaction.payment_channel),
    categoryPrimary: stringValue(category.primary),
    categoryDetailed: stringValue(category.detailed),
    categoryConfidence: stringValue(category.confidence_level),
    transactionCode: stringValue(transaction.transaction_code),
    isoCurrencyCode: stringValue(transaction.iso_currency_code),
    unofficialCurrencyCode: stringValue(transaction.unofficial_currency_code),
  };
}

export function mergeProducts(
  existing: PlaidProduct[],
  additions: PlaidProduct[],
): PlaidProduct[] {
  return [...new Set([...existing, ...additions])];
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

function booleanValue(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
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
