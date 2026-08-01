import type { StoredPlaidItem } from "./types";

const documentKey = "plaid:items:v1";

interface LegacyStoredPlaidItem extends Omit<StoredPlaidItem, "products"> {
  products?: undefined;
}

interface StoredDocumentV1 {
  schemaVersion: 1;
  items: LegacyStoredPlaidItem[];
}

interface StoredDocumentV2 {
  schemaVersion: 2;
  items: StoredPlaidItem[];
}

export async function loadItems(storage: KVNamespace): Promise<StoredPlaidItem[]> {
  const document = await storage.get<StoredDocumentV1 | StoredDocumentV2>(
    documentKey,
    "json",
  );
  if (document === null) return [];
  if (!Array.isArray(document.items)) {
    throw new Error("Unsupported Plaid Item storage document");
  }
  if (document.schemaVersion === 2) return document.items;
  if (document.schemaVersion === 1) {
    return document.items.map((item) => ({
      ...item,
      products: ["investments"],
    }));
  }
  throw new Error("Unsupported Plaid Item storage document");
}

export async function saveItems(
  storage: KVNamespace,
  items: StoredPlaidItem[],
): Promise<void> {
  const document: StoredDocumentV2 = { schemaVersion: 2, items };
  await storage.put(documentKey, JSON.stringify(document));
}
