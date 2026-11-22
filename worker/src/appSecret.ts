/**
 * The shared secret between the Clicky app and this Worker. The Worker answers any caller that can reach it, so the
 * routes that spend the Notion token, or the agent harness's Anthropic calls, check that the request carries the app's secret
 * before they do anything else.
 */

export const appSecretHeaderName = "x-clicky-app-secret";

/**
 * Every route that uses the Notion token, the Messages passthrough, which spends the owner's Anthropic key for the agent
 * harness, and the room art routes, which spend it on a page read and keep the local depth service's GPU busy for about 14 s.
 */
export const routesThatNeedTheAppSecret = new Set([
  "/notion-page",
  "/study-guide",
  "/study-guide-status",
  "/v1/messages",
  "/room-art",
  "/room-wall",
]);

async function sha256Digest(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/**
 * Compares SHA-256 digests byte by byte without stopping early, so the time taken never reveals how much of a guess
 * matched, and hashing first makes both sides the same length. A Worker with no secret set refuses every caller.
 */
export async function requestCarriesTheAppSecret(request: Request, expectedSecret: string | undefined): Promise<boolean> {
  if (expectedSecret === undefined || expectedSecret.length === 0) {
    console.error("CLICKY_APP_SECRET is not set, so the gated routes refuse every request");
    return false;
  }
  const [sentDigest, expectedDigest] = await Promise.all([
    sha256Digest(request.headers.get(appSecretHeaderName) ?? ""),
    sha256Digest(expectedSecret),
  ]);
  let differingBits = 0;
  for (let byteIndex = 0; byteIndex < expectedDigest.length; byteIndex += 1) {
    differingBits |= (sentDigest[byteIndex] ?? 0) ^ (expectedDigest[byteIndex] ?? 0);
  }
  return differingBits === 0;
}
