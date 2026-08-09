import assert from "node:assert/strict";
import test from "node:test";
import {
  InferenceRequestError,
  parseInferenceInput,
} from "../src/inference";

test("inference input accepts only privacy-bounded classification fields", () => {
  const result = parseInferenceInput({
    rawDescription: "SQ *JOES PIZZA 1842",
    merchantName: "Joe's Pizza",
    counterpartyName: null,
    counterpartyType: "merchant",
    paymentChannel: "in store",
    plaidCategoryPrimary: "FOOD_AND_DRINK",
    plaidCategoryDetailed: "FOOD_AND_DRINK_RESTAURANTS",
    plaidCategoryConfidence: "HIGH",
    direction: "outflow",
    exactAmount: 42.5,
    accountName: "Private Checking",
  });

  assert.equal(result.rawDescription, "SQ *JOES PIZZA 1842");
  assert.equal("allowedCategoryCodes" in result, false);
  assert.equal("exactAmount" in result, false);
  assert.equal("accountName" in result, false);
});

test("inference input rejects invalid directions", () => {
  assert.throws(
    () =>
      parseInferenceInput({
        rawDescription: "Example",
        direction: "unknown",
      }),
    InferenceRequestError,
  );
});
