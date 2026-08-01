import assert from "node:assert/strict";
import test from "node:test";
import { normalizeHoldings } from "../src/plaid";

const item = {
  id: "item-1",
  institutionName: "First Brokerage",
  status: "healthy",
  lastSyncedAt: null,
  products: ["investments"] as const,
};

test("holdings normalization preserves account totals and holding detail", () => {
  const result = normalizeHoldings(item, {
    item: { error: null },
    accounts: [
      {
        account_id: "account-1",
        name: "Brokerage",
        official_name: "Taxable Brokerage",
        mask: "1234",
        subtype: "brokerage",
        balances: {
          current: 10_000.125,
          available: null,
          iso_currency_code: "USD",
          unofficial_currency_code: null,
        },
      },
    ],
    securities: [
      {
        security_id: "security-1",
        name: "Example Fund",
        ticker_symbol: "EXMPL",
        type: "etf",
        close_price: 475.25,
        close_price_as_of: "2026-07-18",
        iso_currency_code: "USD",
        unofficial_currency_code: null,
      },
    ],
    holdings: [
      {
        account_id: "account-1",
        security_id: "security-1",
        quantity: 20,
        institution_value: 9_505,
        cost_basis: 8_000,
        institution_price_as_of: "2026-07-18",
      },
    ],
  });

  assert.equal(result.accounts[0]?.currentBalance, 10_000.125);
  assert.equal(result.accounts[0]?.institutionName, "First Brokerage");
  assert.equal(result.securities[0]?.tickerSymbol, "EXMPL");
  assert.equal(result.securities[0]?.closePriceAsOf, "2026-07-18T00:00:00Z");
  assert.equal(result.holdings[0]?.institutionValue, 9_505);
  assert.equal(result.holdings[0]?.asOf, "2026-07-18T00:00:00Z");
  assert.equal(result.itemStatus, "healthy");
});

test("holdings normalization rejects missing financial identifiers", () => {
  assert.throws(
    () => normalizeHoldings(item, { accounts: [{}], securities: [], holdings: [] }),
    /account_id/,
  );
});

test("transaction sync normalization preserves enrichment and cursor state", async () => {
  const { normalizeTransactions } = await import("../src/plaid");
  const result = normalizeTransactions(
    { ...item, products: ["transactions"] },
    {
      item: { error: null },
      accounts: [
        {
          account_id: "checking-1",
          name: "Checking",
          official_name: "Everyday Checking",
          mask: "9876",
          type: "depository",
          subtype: "checking",
          balances: {
            current: 1200,
            available: 1100,
            limit: null,
            iso_currency_code: "USD",
            unofficial_currency_code: null,
          },
        },
      ],
      added: [
        {
          transaction_id: "transaction-1",
          account_id: "checking-1",
          date: "2026-07-24",
          authorized_date: "2026-07-23",
          amount: 42.5,
          pending: false,
          pending_transaction_id: "pending-1",
          name: "SQ *JOES PIZZA 1842",
          original_description: "SQ *JOES PIZZA 1842",
          merchant_name: "Joe's Pizza",
          merchant_entity_id: "merchant-1",
          payment_channel: "in store",
          personal_finance_category: {
            primary: "FOOD_AND_DRINK",
            detailed: "FOOD_AND_DRINK_RESTAURANTS",
            confidence_level: "VERY_HIGH",
          },
          counterparties: [
            {
              name: "Joe's Pizza",
              type: "merchant",
              entity_id: "merchant-1",
              confidence_level: "VERY_HIGH",
            },
          ],
          transaction_code: null,
          iso_currency_code: "USD",
          unofficial_currency_code: null,
        },
      ],
      modified: [],
      removed: [{ transaction_id: "removed-1" }],
      next_cursor: "cursor-2",
      has_more: true,
      transactions_update_status: "HISTORICAL_UPDATE_COMPLETE",
    },
  );

  assert.equal(result.accounts[0]?.type, "depository");
  assert.equal(result.added[0]?.merchantName, "Joe's Pizza");
  assert.equal(result.added[0]?.categoryDetailed, "FOOD_AND_DRINK_RESTAURANTS");
  assert.equal(result.removed[0], "removed-1");
  assert.equal(result.nextCursor, "cursor-2");
  assert.equal(result.hasMore, true);
  assert.equal(result.updateStatus, "HISTORICAL_UPDATE_COMPLETE");
});
