import { afterEach, describe, expect, it, vi } from "vitest";
import { checkLandmark, handleLandmark } from "./landmark";

const statue = { isFamousPlace: true, name: "Statue of Liberty", latitude: 40.68925, longitude: -74.0445, heightMeters: 93, radiusMeters: 20 };

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("checkLandmark", () => {
  it("keeps a real place", () => {
    expect(checkLandmark(statue)).toEqual(statue);
  });

  it("treats coordinates off the globe or at 0, 0 as no place", () => {
    expect(checkLandmark({ ...statue, latitude: 140 })).toEqual({ isFamousPlace: false });
    expect(checkLandmark({ ...statue, latitude: 0, longitude: 0 })).toEqual({ isFamousPlace: false });
  });
});

describe("handleLandmark", () => {
  it("sends the frame and the title to Sonnet and returns the checked place", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) =>
      new Response(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(statue) }] })),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleLandmark(
      new Request("https://worker.test/landmark", { method: "POST", body: JSON.stringify({ frameBase64: "AAAA", videoTitle: "Building an Icon", learnerRequest: "render this in 3D" }) }),
      "key",
    );

    expect(await response.json()).toEqual(statue);
    const sentBody: unknown = JSON.parse(String(fetchMock.mock.calls[0]?.[1].body));
    expect(sentBody).toMatchObject({
      model: "claude-sonnet-5-5",
      messages: [{ content: [{ type: "image" }, { type: "text" }, { type: "text", text: "<learner_request>render this in 3D</learner_request>" }] }],
    });
  });
});
