export interface Env {
  PLAID_STORAGE: KVNamespace;
  PLAID_CLIENT_ID: string;
  PLAID_SECRET: string;
  PLAID_REDIRECT_URI: string;
  BACKEND_BEARER_TOKEN: string;
  TOKEN_ENCRYPTION_KEY: string;
  CLAUDE_SNAPSHOT_ENCRYPTION_KEY: string;
  PLAID_ENV: "sandbox" | "development" | "production";
  PLAID_CLIENT_NAME: string;
  PLAID_COUNTRY_CODES: string;
  APPLE_APP_ID: string;
  ANTHROPIC_API_KEY?: string;
  ANTHROPIC_MODEL?: string;
}

export type PlaidProduct = "investments" | "transactions";

export interface EncryptedValue {
  version: 1;
  iv: string;
  ciphertext: string;
}

export interface StoredPlaidItem {
  id: string;
  institutionName: string;
  status: string;
  lastSyncedAt: string | null;
  products: PlaidProduct[];
  accessToken: EncryptedValue;
}

export interface PublicPlaidItem {
  id: string;
  institutionName: string;
  status: string;
  lastSyncedAt: string | null;
  products: PlaidProduct[];
}

export interface PlaidAccountResponse {
  id: string;
  itemId: string;
  institutionName: string;
  name: string;
  officialName: string | null;
  mask: string | null;
  type: string | null;
  subtype: string | null;
  currentBalance: number | null;
  availableBalance: number | null;
  limit: number | null;
  isoCurrencyCode: string | null;
  unofficialCurrencyCode: string | null;
}

export interface PlaidSecurityResponse {
  id: string;
  name: string | null;
  tickerSymbol: string | null;
  type: string | null;
  closePrice: number | null;
  closePriceAsOf: string | null;
  isoCurrencyCode: string | null;
  unofficialCurrencyCode: string | null;
}

export interface PlaidHoldingResponse {
  accountId: string;
  securityId: string;
  quantity: number;
  institutionValue: number;
  costBasis: number | null;
  asOf: string | null;
}

export interface NormalizedHoldings {
  accounts: PlaidAccountResponse[];
  securities: PlaidSecurityResponse[];
  holdings: PlaidHoldingResponse[];
  itemStatus: string;
}

export interface PlaidTransactionResponse {
  id: string;
  accountId: string;
  date: string;
  authorizedDate: string | null;
  amount: number;
  pending: boolean;
  pendingTransactionId: string | null;
  name: string;
  originalDescription: string | null;
  merchantName: string | null;
  merchantEntityId: string | null;
  counterpartyName: string | null;
  counterpartyType: string | null;
  counterpartyEntityId: string | null;
  counterpartyConfidence: string | null;
  paymentChannel: string | null;
  categoryPrimary: string | null;
  categoryDetailed: string | null;
  categoryConfidence: string | null;
  transactionCode: string | null;
  isoCurrencyCode: string | null;
  unofficialCurrencyCode: string | null;
}

export interface NormalizedTransactions {
  accounts: PlaidAccountResponse[];
  added: PlaidTransactionResponse[];
  modified: PlaidTransactionResponse[];
  removed: string[];
  nextCursor: string;
  hasMore: boolean;
  updateStatus: string | null;
  itemStatus: string;
}
