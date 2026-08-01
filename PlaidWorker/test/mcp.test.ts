import assert from "node:assert/strict";
import test from "node:test";
import { dispatchTool } from "../src/mcp";
import type { ClaudeFinancialSnapshot } from "../src/claude";

const snapshot: ClaudeFinancialSnapshot = {
  schemaVersion: 1,
  generatedAt: "2026-07-30T12:00:00.000Z",
  primarySource: "plaid",
  accounts: [
    {
      name: "Checking",
      institutionName: "Example Bank",
      type: "checking",
      balanceMilliunits: 1_250_000,
      availableBalanceMilliunits: 1_200_000,
      closed: false,
    },
  ],
  manualAssets: [
    {
      name: "Private investment",
      groupName: null,
      type: "investment",
      currentValueMilliunits: 5_000_000,
      lastUpdatedAt: "2026-07-29T12:00:00.000Z",
    },
  ],
  holdings: [
    {
      accountName: "Brokerage",
      institutionName: "Example Brokerage",
      securityName: "Index Fund",
      tickerSymbol: "IDX",
      securityType: "etf",
      quantity: "10",
      valueMilliunits: 5_000_000,
      costBasisMilliunits: 4_000_000,
      asOf: "2026-07-30T00:00:00.000Z",
    },
  ],
  transactions: [
    {
      date: "2026-07-29T00:00:00.000Z",
      accountName: "Checking",
      contactName: "Grocery Store",
      categoryName: "Groceries",
      treatment: "ordinarySpending",
      amountMilliunits: -125_500,
      splits: [],
    },
  ],
  netWorthHistory: [
    {
      date: "2026-07-30T00:00:00.000Z",
      assetsMilliunits: 10_000_000,
      liabilitiesMilliunits: 2_000_000,
    },
  ],
};

test("financial summary converts exact milliunits to dollars", () => {
  const result = dispatchTool(
    "get_financial_summary",
    {},
    snapshot,
  ) as {
    latest_totals: {
      assets: number;
      liabilities: number;
      net_worth: number;
    };
  };

  assert.deepEqual(result.latest_totals, {
    date: "2026-07-30T00:00:00.000Z",
    assets: 10_000,
    liabilities: 2_000,
    net_worth: 8_000,
  });
});

test("transaction search filters confirmed snapshot rows", () => {
  const result = dispatchTool(
    "search_transactions",
    { category: "grocer", limit: 10 },
    snapshot,
  ) as { transactions: Array<{ contact: string; amount: number }> };

  assert.deepEqual(result.transactions, [
    { date: "2026-07-29T00:00:00.000Z", account: "Checking",
      contact: "Grocery Store", category: "Groceries",
      treatment: "ordinarySpending", amount: -125.5, splits: [] },
  ]);
});
