export interface Env {
  PLAID_STORAGE: KVNamespace;
  PLAID_CLIENT_ID: string;
  PLAID_SECRET: string;
  PLAID_REDIRECT_URI: string;
  BACKEND_BEARER_TOKEN: string;
  TOKEN_ENCRYPTION_KEY: string;
  PLAID_ENV: "sandbox" | "development" | "production";
  PLAID_CLIENT_NAME: string;
  PLAID_COUNTRY_CODES: string;
  APPLE_APP_ID: string;
}

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
  accessToken: EncryptedValue;
}

export interface PublicPlaidItem {
  id: string;
  institutionName: string;
  status: string;
  lastSyncedAt: string | null;
}

export interface PlaidAccountResponse {
  id: string;
  itemId: string;
  institutionName: string;
  name: string;
  officialName: string | null;
  mask: string | null;
  subtype: string | null;
  currentBalance: number | null;
  availableBalance: number | null;
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
