import {
  authorizeClaudeMCPRequest,
  loadClaudeSnapshot,
  mcpUnauthorizedResponse,
  type ClaudeFinancialSnapshot,
} from "./claude";
import type { Env } from "./types";

const protocolVersion = "2025-06-18";

export const networthToolDefinitions = [
  {
    name: "get_financial_summary",
    description:
      "Return the latest synced Networth totals and record counts. Money values are USD dollars. Use this first for a concise overview.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "get_accounts",
    description:
      "Return synced account labels, types, institutions, balances, and available balances. Provider IDs and account numbers are never included.",
    inputSchema: {
      type: "object",
      properties: {
        type: {
          type: "string",
          description:
            "Optional case-insensitive account-type filter, such as checking, savings, creditCard, or investment.",
        },
        include_closed: {
          type: "boolean",
          description: "Include closed accounts. Defaults to false.",
        },
      },
    },
  },
  {
    name: "get_investments",
    description:
      "Return manual investment assets and synced Plaid holdings with security names, tickers, quantities, values, and cost basis. Money values are USD dollars.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "Optional case-insensitive filter across account, institution, security name, and ticker.",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 500,
          description: "Maximum holdings to return. Defaults to 100.",
        },
      },
    },
  },
  {
    name: "search_transactions",
    description:
      "Search confirmed transaction history. Unreviewed Plaid transactions, raw bank descriptions, memos, and provider IDs are never available. Money values are signed USD dollars: inflows positive, outflows negative.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "Optional case-insensitive filter across contact, category, treatment, and account.",
        },
        start_date: {
          type: "string",
          description: "Optional inclusive ISO-8601 date (YYYY-MM-DD).",
        },
        end_date: {
          type: "string",
          description: "Optional inclusive ISO-8601 date (YYYY-MM-DD).",
        },
        account: {
          type: "string",
          description: "Optional case-insensitive account-name filter.",
        },
        category: {
          type: "string",
          description: "Optional case-insensitive category filter.",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 500,
          description: "Maximum results. Defaults to 100.",
        },
      },
    },
  },
  {
    name: "get_net_worth_history",
    description:
      "Return daily asset, liability, and net-worth totals from Networth history. Money values are USD dollars.",
    inputSchema: {
      type: "object",
      properties: {
        start_date: {
          type: "string",
          description: "Optional inclusive ISO-8601 date (YYYY-MM-DD).",
        },
        end_date: {
          type: "string",
          description: "Optional inclusive ISO-8601 date (YYYY-MM-DD).",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 2_000,
          description: "Maximum points. Defaults to 400.",
        },
      },
    },
  },
] as const;

export async function handleMCPRequest(
  request: Request,
  env: Env,
): Promise<Response> {
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return rpcResponse(makeError(null, -32700, "Parse error"), 400);
  }
  const messages = Array.isArray(payload) ? payload : [payload];
  const needsAuthorization = messages.some(
    (value) => isObject(value) && value.method === "tools/call",
  );
  if (
    needsAuthorization &&
    !(await authorizeClaudeMCPRequest(request, env))
  ) {
    return mcpUnauthorizedResponse(request);
  }

  const responses: object[] = [];
  for (const value of messages) {
    const response = await routeMessage(value, env);
    if (response) responses.push(response);
  }
  if (responses.length === 0) return new Response(null, { status: 202 });
  return rpcResponse(Array.isArray(payload) ? responses : responses[0]);
}

async function routeMessage(
  message: unknown,
  env: Env,
): Promise<object | undefined> {
  if (!isObject(message) || message.jsonrpc !== "2.0") {
    return makeError(
      isObject(message) ? message.id ?? null : null,
      -32600,
      "Invalid Request",
    );
  }
  const id = message.id;
  const isNotification = id === undefined;
  try {
    switch (message.method) {
      case "initialize":
        return makeResult(id, {
          protocolVersion,
          serverInfo: { name: "networth-mcp", version: "1.0.0" },
          capabilities: { tools: { listChanged: false } },
        });
      case "notifications/initialized":
      case "notifications/cancelled":
      case "ping":
        return isNotification ? undefined : makeResult(id, {});
      case "tools/list":
        return makeResult(id, { tools: networthToolDefinitions });
      case "tools/call": {
        const params = isObject(message.params) ? message.params : {};
        const name = typeof params.name === "string" ? params.name : "";
        const args = isObject(params.arguments) ? params.arguments : {};
        const snapshot = await loadClaudeSnapshot(env);
        if (!snapshot) {
          return makeResult(id, {
            content: [
              {
                type: "text",
                text: "Networth has not uploaded a financial snapshot yet.",
              },
            ],
            isError: true,
          });
        }
        const result = dispatchTool(name, args, snapshot);
        return makeResult(id, {
          content: [
            { type: "text", text: JSON.stringify(result, null, 2) },
          ],
          isError: false,
        });
      }
      default:
        return makeError(id ?? null, -32601, "Method not found");
    }
  } catch (error) {
    return makeError(
      id ?? null,
      -32000,
      error instanceof Error ? error.message : "Internal error",
    );
  }
}

export function dispatchTool(
  name: string,
  args: Record<string, unknown>,
  snapshot: ClaudeFinancialSnapshot,
): object {
  switch (name) {
    case "get_financial_summary":
      return financialSummary(snapshot);
    case "get_accounts":
      return accountsResult(args, snapshot);
    case "get_investments":
      return investmentsResult(args, snapshot);
    case "search_transactions":
      return transactionsResult(args, snapshot);
    case "get_net_worth_history":
      return netWorthResult(args, snapshot);
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

function financialSummary(snapshot: ClaudeFinancialSnapshot): object {
  const history = objectArray(snapshot.netWorthHistory).sort(
    (left, right) =>
      stringValue(left.date).localeCompare(stringValue(right.date)),
  );
  const latest = history.at(-1);
  const assets = moneyValue(latest?.assetsMilliunits);
  const liabilities = moneyValue(latest?.liabilitiesMilliunits);
  return {
    generated_at: snapshot.generatedAt,
    primary_source: snapshot.primarySource,
    latest_totals: latest
      ? {
          date: latest.date,
          assets,
          liabilities,
          net_worth: assets - liabilities,
        }
      : null,
    counts: {
      accounts: snapshot.accounts.length,
      manual_assets: snapshot.manualAssets.length,
      holdings: snapshot.holdings.length,
      confirmed_transactions: snapshot.transactions.length,
      net_worth_points: snapshot.netWorthHistory.length,
    },
  };
}

function accountsResult(
  args: Record<string, unknown>,
  snapshot: ClaudeFinancialSnapshot,
): object {
  const type = lowerString(args.type);
  const includeClosed = args.include_closed === true;
  const accounts = objectArray(snapshot.accounts)
    .filter((account) => includeClosed || account.closed !== true)
    .filter(
      (account) =>
        !type || lowerString(account.type).includes(type),
    )
    .map((account) => ({
      name: account.name,
      institution: account.institutionName ?? null,
      type: account.type,
      balance: moneyValue(account.balanceMilliunits),
      available_balance:
        account.availableBalanceMilliunits === null ||
        account.availableBalanceMilliunits === undefined
          ? null
          : moneyValue(account.availableBalanceMilliunits),
      closed: account.closed === true,
    }));
  return { generated_at: snapshot.generatedAt, accounts };
}

function investmentsResult(
  args: Record<string, unknown>,
  snapshot: ClaudeFinancialSnapshot,
): object {
  const query = lowerString(args.query);
  const limit = clampInteger(args.limit, 1, 500, 100);
  const holdings = objectArray(snapshot.holdings)
    .filter((holding) => {
      if (!query) return true;
      return [
        holding.accountName,
        holding.institutionName,
        holding.securityName,
        holding.tickerSymbol,
      ].some((value) => lowerString(value).includes(query));
    })
    .slice(0, limit)
    .map((holding) => ({
      account: holding.accountName,
      institution: holding.institutionName ?? null,
      security: holding.securityName,
      ticker: holding.tickerSymbol ?? null,
      security_type: holding.securityType ?? null,
      quantity: holding.quantity,
      value: moneyValue(holding.valueMilliunits),
      cost_basis:
        holding.costBasisMilliunits === null ||
        holding.costBasisMilliunits === undefined
          ? null
          : moneyValue(holding.costBasisMilliunits),
      as_of: holding.asOf ?? null,
    }));
  const manualAssets = objectArray(snapshot.manualAssets)
    .filter((asset) =>
      ["brokerage", "retirement", "crypto"].includes(
        lowerString(asset.type),
      ),
    )
    .map((asset) => ({
      name: asset.name,
      group: asset.groupName ?? null,
      type: asset.type,
      current_value: moneyValue(asset.currentValueMilliunits),
      last_updated_at: asset.lastUpdatedAt,
    }));
  return {
    generated_at: snapshot.generatedAt,
    manual_investment_assets: manualAssets,
    holdings,
    returned_holdings: holdings.length,
  };
}

function transactionsResult(
  args: Record<string, unknown>,
  snapshot: ClaudeFinancialSnapshot,
): object {
  const query = lowerString(args.query);
  const accountFilter = lowerString(args.account);
  const categoryFilter = lowerString(args.category);
  const start = dateBoundary(args.start_date, false);
  const end = dateBoundary(args.end_date, true);
  const limit = clampInteger(args.limit, 1, 500, 100);
  const transactions = objectArray(snapshot.transactions)
    .filter((transaction) => {
      const date = Date.parse(stringValue(transaction.date));
      if (start !== null && date < start) return false;
      if (end !== null && date > end) return false;
      if (
        accountFilter &&
        !lowerString(transaction.accountName).includes(accountFilter)
      ) {
        return false;
      }
      if (
        categoryFilter &&
        !lowerString(transaction.categoryName).includes(categoryFilter)
      ) {
        return false;
      }
      if (!query) return true;
      return [
        transaction.contactName,
        transaction.categoryName,
        transaction.treatment,
        transaction.accountName,
      ].some((value) => lowerString(value).includes(query));
    })
    .sort(
      (left, right) =>
        stringValue(right.date).localeCompare(stringValue(left.date)),
    )
    .slice(0, limit)
    .map((transaction) => ({
      date: transaction.date,
      account: transaction.accountName,
      contact: transaction.contactName,
      category: transaction.categoryName ?? null,
      treatment: transaction.treatment,
      amount: moneyValue(transaction.amountMilliunits),
      splits: objectArray(transaction.splits).map((split) => ({
        category: split.categoryName ?? null,
        treatment: split.treatment ?? null,
        amount: moneyValue(split.amountMilliunits),
      })),
    }));
  return {
    generated_at: snapshot.generatedAt,
    transactions,
    returned: transactions.length,
  };
}

function netWorthResult(
  args: Record<string, unknown>,
  snapshot: ClaudeFinancialSnapshot,
): object {
  const start = dateBoundary(args.start_date, false);
  const end = dateBoundary(args.end_date, true);
  const limit = clampInteger(args.limit, 1, 2_000, 400);
  const points = objectArray(snapshot.netWorthHistory)
    .filter((point) => {
      const date = Date.parse(stringValue(point.date));
      return (
        (start === null || date >= start) &&
        (end === null || date <= end)
      );
    })
    .sort(
      (left, right) =>
        stringValue(left.date).localeCompare(stringValue(right.date)),
    )
    .slice(-limit)
    .map((point) => {
      const assets = moneyValue(point.assetsMilliunits);
      const liabilities = moneyValue(point.liabilitiesMilliunits);
      return {
        date: point.date,
        assets,
        liabilities,
        net_worth: assets - liabilities,
      };
    });
  return { generated_at: snapshot.generatedAt, points };
}

function objectArray(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.filter(isObject) : [];
}

function moneyValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value)
    ? value / 1_000
    : 0;
}

function clampInteger(
  value: unknown,
  minimum: number,
  maximum: number,
  fallback: number,
): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.floor(value)));
}

function dateBoundary(value: unknown, endOfDay: boolean): number | null {
  if (typeof value !== "string" || !value.trim()) return null;
  const suffix = endOfDay ? "T23:59:59.999Z" : "T00:00:00.000Z";
  const parsed = Date.parse(
    /^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}${suffix}` : value,
  );
  if (!Number.isFinite(parsed)) throw new Error("A date filter is invalid");
  return parsed;
}

function lowerString(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function makeResult(id: unknown, result: object): object {
  return { jsonrpc: "2.0", id: id ?? null, result };
}

function makeError(id: unknown, code: number, message: string): object {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message } };
}

function rpcResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
