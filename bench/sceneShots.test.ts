import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { pageWithLocalThree, scenePageContentSecurityPolicy } from "./sceneShots.ts";

describe("pageWithLocalThree", () => {
  it("points the import map's three.js at the local server, and leaves every other URL alone", () => {
    const page = '<script type="importmap">{ "imports": { "three": "clicky-asset://three/three.module.js" } }</script><img src="https://example.com/a.png">';

    assert.equal(
      pageWithLocalThree(page),
      '<script type="importmap">{ "imports": { "three": "/three/three.module.js" } }</script><img src="https://example.com/a.png">',
    );
  });
});

describe("scenePageContentSecurityPolicy", () => {
  it("lets a page load only from this server, so it cannot call a local Worker that holds API keys", () => {
    const directives = new Map(
      scenePageContentSecurityPolicy.split(";").map((directive) => {
        const [name = "", ...sources] = directive.trim().split(/\s+/);
        return [name, sources] as const;
      }),
    );

    assert.deepEqual(directives.get("default-src"), ["'none'"]);
    assert.deepEqual(directives.get("connect-src"), ["'self'"]);
    assert.ok(!scenePageContentSecurityPolicy.includes("http"), "names no other host");
  });
});
