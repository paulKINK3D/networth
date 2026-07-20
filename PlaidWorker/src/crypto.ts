import type { EncryptedValue } from "./types";

const additionalData = new TextEncoder().encode("networth-plaid-item-token-v1");

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function ownedBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

async function importEncryptionKey(encodedKey: string): Promise<CryptoKey> {
  const bytes = fromBase64(encodedKey);
  if (bytes.byteLength !== 32) {
    throw new Error("TOKEN_ENCRYPTION_KEY must decode to exactly 32 bytes");
  }
  return crypto.subtle.importKey("raw", ownedBuffer(bytes), "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

export async function encryptAccessToken(
  accessToken: string,
  encodedKey: string,
): Promise<EncryptedValue> {
  const key = await importEncryptionKey(encodedKey);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData },
    key,
    new TextEncoder().encode(accessToken),
  );
  return {
    version: 1,
    iv: toBase64(iv),
    ciphertext: toBase64(new Uint8Array(ciphertext)),
  };
}

export async function decryptAccessToken(
  encrypted: EncryptedValue,
  encodedKey: string,
): Promise<string> {
  if (encrypted.version !== 1) throw new Error("Unsupported token ciphertext");
  const key = await importEncryptionKey(encodedKey);
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: ownedBuffer(fromBase64(encrypted.iv)),
      additionalData,
    },
    key,
    ownedBuffer(fromBase64(encrypted.ciphertext)),
  );
  return new TextDecoder().decode(plaintext);
}
