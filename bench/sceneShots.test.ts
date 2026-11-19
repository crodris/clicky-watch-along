import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { pageWithLocalThree } from "./sceneShots.ts";

describe("pageWithLocalThree", () => {
  it("points the import map's three.js at the local server, and leaves every other URL alone", () => {
    const page = '<script type="importmap">{ "imports": { "three": "clicky-asset://three/three.module.js" } }</script><img src="https://example.com/a.png">';

    assert.equal(
      pageWithLocalThree(page),
      '<script type="importmap">{ "imports": { "three": "/three/three.module.js" } }</script><img src="https://example.com/a.png">',
    );
  });
});
