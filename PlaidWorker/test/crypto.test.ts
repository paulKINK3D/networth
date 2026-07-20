import assert from "node:assert/strict";
import test from "node:test";
import { decryptAccessToken, encryptAccessToken } from "../src/crypto";

const key = Buffer.alloc(32, 7).toString("base64");

test("access-token encryption round trips without plaintext storage", async () => {
  const encrypted = await encryptAccessToken("access-sandbox-secret", key);

  assert.equal(encrypted.version, 1);
  assert.notEqual(encrypted.ciphertext, "access-sandbox-secret");
  assert.equal(
    await decryptAccessToken(encrypted, key),
    "access-sandbox-secret",
  );
});

test("access-token encryption rejects invalid key sizes", async () => {
  await assert.rejects(
    encryptAccessToken("token", Buffer.alloc(16).toString("base64")),
    /exactly 32 bytes/,
  );
});
