const encoder = new TextEncoder();

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
}

export async function isAuthorized(
  request: Request,
  expectedToken: string,
): Promise<boolean> {
  if (!expectedToken) return false;
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return false;
  const suppliedToken = header.slice("Bearer ".length);
  const [supplied, expected] = await Promise.all([
    digest(suppliedToken),
    digest(expectedToken),
  ]);
  let difference = 0;
  for (let index = 0; index < expected.length; index += 1) {
    difference |= supplied[index]! ^ expected[index]!;
  }
  return difference === 0;
}
