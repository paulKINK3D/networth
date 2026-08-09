import type { Env } from "./types";

type JsonObject = Record<string, unknown>;

export interface TransactionInferenceInput {
  rawDescription: string;
  merchantName: string | null;
  counterpartyName: string | null;
  counterpartyType: string | null;
  paymentChannel: string | null;
  plaidCategoryPrimary: string | null;
  plaidCategoryDetailed: string | null;
  plaidCategoryConfidence: string | null;
  direction: "inflow" | "outflow";
}

export interface TransactionInferenceResult {
  displayName: string;
  confidence: "high" | "medium" | "low";
}

export class InferenceRequestError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function inferTransaction(
  env: Env,
  input: TransactionInferenceInput,
): Promise<TransactionInferenceResult> {
  const apiKey = env.ANTHROPIC_API_KEY?.trim();
  if (!apiKey) throw new InferenceRequestError(503, "Claude fallback is not configured");

  const schema = {
    type: "object",
    properties: {
      displayName: {
        type: "string",
        description: "Short human-readable merchant or counterparty name.",
      },
      confidence: {
        type: "string",
        enum: ["high", "medium", "low"],
      },
    },
    required: ["displayName", "confidence"],
    additionalProperties: false,
  };
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: env.ANTHROPIC_MODEL?.trim() || "claude-haiku-4-5-20251001",
      max_tokens: 160,
      system:
        "Normalize one personal-finance transaction. Use only the supplied evidence. Do not infer identity, account ownership, location, category, or other facts. Return the cleanest defensible display name.",
      messages: [
        {
          role: "user",
          content: JSON.stringify(input),
        },
      ],
      output_config: {
        format: {
          type: "json_schema",
          schema,
        },
      },
    }),
    signal: AbortSignal.timeout(15_000),
  });

  let payload: JsonObject;
  try {
    payload = (await response.json()) as JsonObject;
  } catch {
    throw new InferenceRequestError(502, "Claude returned an unreadable response");
  }
  if (!response.ok) {
    throw new InferenceRequestError(
      response.status === 429 ? 429 : 502,
      "Claude inference failed",
    );
  }
  const content = Array.isArray(payload.content) ? payload.content : [];
  const textBlock = content.find((value) => {
    const block = objectValue(value);
    return block.type === "text" && typeof block.text === "string";
  });
  const text = objectValue(textBlock).text;
  if (typeof text !== "string") {
    throw new InferenceRequestError(502, "Claude returned no classification");
  }

  let result: JsonObject;
  try {
    result = JSON.parse(text) as JsonObject;
  } catch {
    throw new InferenceRequestError(502, "Claude returned invalid classification JSON");
  }
  const displayName = trimmedString(result.displayName, 120);
  const confidence = trimmedString(result.confidence, 16);
  if (
    !displayName ||
    !["high", "medium", "low"].includes(confidence)
  ) {
    throw new InferenceRequestError(502, "Claude returned an invalid classification");
  }
  return {
    displayName,
    confidence: confidence as TransactionInferenceResult["confidence"],
  };
}

export function parseInferenceInput(
  body: Record<string, unknown>,
): TransactionInferenceInput {
  const rawDescription = requiredTrimmedString(body.rawDescription, 500);
  const direction = requiredTrimmedString(body.direction, 16);
  if (direction !== "inflow" && direction !== "outflow") {
    throw new InferenceRequestError(400, "direction must be inflow or outflow");
  }
  return {
    rawDescription,
    merchantName: optionalTrimmedString(body.merchantName, 200),
    counterpartyName: optionalTrimmedString(body.counterpartyName, 200),
    counterpartyType: optionalTrimmedString(body.counterpartyType, 64),
    paymentChannel: optionalTrimmedString(body.paymentChannel, 64),
    plaidCategoryPrimary: optionalTrimmedString(
      body.plaidCategoryPrimary,
      100,
    ),
    plaidCategoryDetailed: optionalTrimmedString(
      body.plaidCategoryDetailed,
      160,
    ),
    plaidCategoryConfidence: optionalTrimmedString(
      body.plaidCategoryConfidence,
      32,
    ),
    direction,
  };
}

function requiredTrimmedString(value: unknown, maximum: number): string {
  const parsed = trimmedString(value, maximum);
  if (!parsed) throw new InferenceRequestError(400, "A required field is invalid");
  return parsed;
}

function optionalTrimmedString(value: unknown, maximum: number): string | null {
  if (value == null) return null;
  return trimmedString(value, maximum) || null;
}

function trimmedString(value: unknown, maximum: number): string {
  if (typeof value !== "string") return "";
  return value.trim().slice(0, maximum);
}

function objectValue(value: unknown): JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonObject)
    : {};
}
