import assert from "node:assert/strict";
import test from "node:test";
import { isAuthorized } from "../src/auth";

test("bearer authorization accepts only the provisioned token", async () => {
  const authorized = new Request("https://worker.example/v1/plaid/items", {
    headers: { Authorization: "Bearer expected-token" },
  });
  const rejected = new Request("https://worker.example/v1/plaid/items", {
    headers: { Authorization: "Bearer another-token" },
  });

  assert.equal(await isAuthorized(authorized, "expected-token"), true);
  assert.equal(await isAuthorized(rejected, "expected-token"), false);
});

test("bearer authorization rejects missing headers and empty configuration", async () => {
  const request = new Request("https://worker.example/v1/plaid/items");

  assert.equal(await isAuthorized(request, "expected-token"), false);
  assert.equal(await isAuthorized(request, ""), false);
});
