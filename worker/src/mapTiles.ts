/**
 * GET /v1/3dtiles/... forwards Google Photorealistic 3D Tiles requests and adds
 * the key, so the key stays in the Worker and the app's overlay never sees it.
 * Tile responses list their children as paths under /v1/3dtiles/, so every
 * request of a render comes back through this route.
 */

const googleTilesOrigin = "https://tile.googleapis.com";

export function isMapTilesRequest(url: URL): boolean {
  return url.pathname.startsWith("/v1/3dtiles/");
}

/** Only pages served from this machine may read tiles in a browser, which is how the tile page is tested. */
function localOriginAllowedToRead(request: Request): string | undefined {
  const origin = request.headers.get("origin");
  return origin !== null && /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin) ? origin : undefined;
}

export async function handleMapTiles(request: Request, googleMapsAPIKey: string | undefined): Promise<Response> {
  if (googleMapsAPIKey === undefined || googleMapsAPIKey === "") {
    return new Response("GOOGLE_MAPS_API_KEY is not set in worker/.dev.vars", { status: 500 });
  }
  const requestURL = new URL(request.url);
  const upstreamURL = new URL(requestURL.pathname + requestURL.search, googleTilesOrigin);
  upstreamURL.searchParams.set("key", googleMapsAPIKey);

  const upstreamResponse = await fetch(upstreamURL.toString());
  if (!upstreamResponse.ok) {
    console.error(`[/v1/3dtiles] Google returned ${upstreamResponse.status} for ${requestURL.pathname}`);
  }
  const headers = new Headers({
    "content-type": upstreamResponse.headers.get("content-type") ?? "application/octet-stream",
  });
  const allowedOrigin = localOriginAllowedToRead(request);
  if (allowedOrigin !== undefined) {
    headers.set("access-control-allow-origin", allowedOrigin);
  }
  return new Response(upstreamResponse.body, { status: upstreamResponse.status, headers });
}
