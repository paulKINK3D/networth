import assert from "node:assert/strict";
import test from "node:test";
import { normalizeHoldings } from "../src/plaid";

const item = {
  id: "item-1",
  institutionName: "First Brokerage",
  status: "healthy",
  lastSyncedAt: null,
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
