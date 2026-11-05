import { describe, expect, it } from "vitest";
import { checkLiveSceneModelReply } from "./liveSceneReply";

const liveSceneQuiz = {
  question: "Here we are, inside the heart! What is this, and what does it do?",
  answerLabel: "Heart",
  functionWords: ["pump", "blood"],
  explanation: "That's the heart, and it pumps blood through the body.",
};

const liveScenePage = `<!DOCTYPE html>
<html>
<body>
<svg xmlns="http://www.w3.org/2000/svg"></svg>
<script type="importmap">
{ "imports": { "three": "clicky-asset://three/three.module.js" } }
</script>
<script type="module">
window.liveScene = {
  reveal() {},
  zoomBy(amount) {},
  focusPart(labelText) { return false; }
};
window.webkit?.messageHandlers?.liveSceneEvent?.postMessage("tourFinished");
</script>
</body>
</html>`;

function liveSceneModelReply(html: string): string {
  return "```html\n" + html + "\n```\n```json\n" + JSON.stringify(liveSceneQuiz) + "\n```";
}

describe("live scene reply", () => {
  it("accepts a page and a quiz", () => {
    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(liveScenePage));

    expect(checkedReply.accepted).toBe(true);
    if (checkedReply.accepted) {
      expect(checkedReply.quiz.answerLabel).toBe("Heart");
      expect(checkedReply.html).toContain("clicky-asset://three/three.module.js");
    }
  });

  it("rejects a page whose module script does not parse", () => {
    const pageWithATypo = liveScenePage.replace("zoomBy(amount) {},", "zoomBy(amount) { orbit(normal alFix) },");

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithATypo));

    expect(checkedReply).toMatchObject({ accepted: false, reason: expect.stringContaining("does not parse") });
  });

  it("rejects a page that reaches an external URL", () => {
    const pageWithAnExternalURL = liveScenePage.replace(
      "</body>",
      "<!-- https://cdn.example.com/three.module.js --></body>",
    );

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageWithAnExternalURL));

    expect(checkedReply.accepted).toBe(false);
  });

  it("rejects a page that uses WebRTC in any letter case", () => {
    const pageUsingWebRTC = liveScenePage.replace(
      "</body>",
      "<script>new RTCPeerConnection();</script></body>",
    );

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageUsingWebRTC));

    expect(checkedReply.accepted).toBe(false);
  });

  it("names every quiz problem on one line, so the Worker log keeps the whole reason", () => {
    const replyWithABrokenQuiz =
      "```html\n" + liveScenePage + "\n```\n```json\n" + JSON.stringify({ ...liveSceneQuiz, answerLabel: "", functionWords: "pump" }) + "\n```";
    const checkedReply = checkLiveSceneModelReply(replyWithABrokenQuiz);
    expect(checkedReply.accepted).toBe(false);
    if (checkedReply.accepted) return;
    expect(checkedReply.reason).not.toContain("\n");
    expect(checkedReply.reason).toContain("answerLabel");
    expect(checkedReply.reason).toContain("functionWords");
  });

  it("rejects a page missing focusPart", () => {
    const pageMissingFocusPart = liveScenePage.replace(
      "focusPart(labelText) { return false; }",
      "lookAtPart(labelText) { return false; }",
    );

    const checkedReply = checkLiveSceneModelReply(liveSceneModelReply(pageMissingFocusPart));

    expect(checkedReply.accepted).toBe(false);
  });
});
