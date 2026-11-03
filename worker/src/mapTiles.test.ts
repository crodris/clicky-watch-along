import { afterEach, describe, expect, it, vi } from "vitest";
import { handleMapTiles, isMapTilesRequest } from "./mapTiles";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("handleMapTiles", () => {
  it("forwards the tile path to Google with the Worker's key in place of any key the page sent", async () => {
    const fetchMock = vi.fn(async (_url: string) => new Response("{}", { headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleMapTiles(
      new Request("http://127.0.0.1:8787/v1/3dtiles/datasets/abc/files/x.glb?session=s1&key=page-key"),
      "worker-key",
    );

    expect(response.status).toBe(200);
    const forwardedURL = new URL(String(fetchMock.mock.calls[0]?.[0]));
    expect(forwardedURL.origin + forwardedURL.pathname).toBe("https://tile.googleapis.com/v1/3dtiles/datasets/abc/files/x.glb");
    expect(forwardedURL.searchParams.get("session")).toBe("s1");
    expect(forwardedURL.searchParams.getAll("key")).toEqual(["worker-key"]);
  });

  it("refuses to call Google without a key", async () => {
    const fetchMock = vi.fn(async () => new Response("{}"));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleMapTiles(new Request("http://127.0.0.1:8787/v1/3dtiles/root.json"), undefined);

    expect(response.status).toBe(500);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("lets only pages on this machine read tiles from a browser", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}")));

    const fromLocalPage = await handleMapTiles(
      new Request("http://127.0.0.1:8787/v1/3dtiles/root.json", { headers: { origin: "http://127.0.0.1:8795" } }),
      "worker-key",
    );
    const fromWebsite = await handleMapTiles(
      new Request("http://127.0.0.1:8787/v1/3dtiles/root.json", { headers: { origin: "https://example.com" } }),
      "worker-key",
    );

    expect(fromLocalPage.headers.get("access-control-allow-origin")).toBe("http://127.0.0.1:8795");
    expect(fromWebsite.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("matches only 3D tiles paths", () => {
    expect(isMapTilesRequest(new URL("http://127.0.0.1:8787/v1/3dtiles/root.json"))).toBe(true);
    expect(isMapTilesRequest(new URL("http://127.0.0.1:8787/chat"))).toBe(false);
  });
});
