import type { StoredPlaidItem } from "./types";

const documentKey = "plaid:items:v1";

interface StoredDocument {
  schemaVersion: 1;
  items: StoredPlaidItem[];
}

export async function loadItems(storage: KVNamespace): Promise<StoredPlaidItem[]> {
  const document = await storage.get<StoredDocument>(documentKey, "json");
  if (document === null) return [];
  if (document.schemaVersion !== 1 || !Array.isArray(document.items)) {
    throw new Error("Unsupported Plaid Item storage document");
  }
  return document.items;
}

export async function saveItems(
  storage: KVNamespace,
  items: StoredPlaidItem[],
): Promise<void> {
  const document: StoredDocument = { schemaVersion: 1, items };
  await storage.put(documentKey, JSON.stringify(document));
}
