import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  contextFromRequest,
  describeReply,
  judgePromptParts,
  overlayPage,
  parseJudgeVerdict,
  pointInChatReply,
  spotCheckPage,
  type JudgeContext,
} from "./judgeRender.ts";

const frameContext: JudgeContext = { kind: "frameParts", frameBase64: "RlJBTUU=", width: 1280, height: 720 };
const flowsContext: JudgeContext = { kind: "pictureFlows", frameBase64: "RlJBTUU=", width: 1280, height: 720, partLabels: ["Aorta", "Fan"] };
const chatContext: JudgeContext = { kind: "chat", frameBase64: "U0NSRUVO", width: 1280, height: 800, systemPrompt: "you are clicky", history: "", question: "how do i download this" };

describe("contextFromRequest", () => {
  it("reads the frame and its size for frame parts, and the part labels for picture flows", () => {
    const body = { frameBase64: "QUJD", frameWidth: 1280, frameHeight: 720, partLabels: ["Aorta"] };

    assert.deepEqual(contextFromRequest("/video-frame-parts", body), { kind: "frameParts", frameBase64: "QUJD", width: 1280, height: 720 });
    assert.deepEqual(contextFromRequest("/picture-flows", body), { kind: "pictureFlows", frameBase64: "QUJD", width: 1280, height: 720, partLabels: ["Aorta"] });
  });

  it("reads the title and the timestamped transcript for the quiz plan", () => {
    const context = contextFromRequest("/video-quiz-plan", { title: "Sharks", transcriptLines: [{ seconds: 0, text: "Hi." }, { seconds: 12.5, text: "Sharks float." }] });

    assert.deepEqual(context, { kind: "quizPlan", title: "Sharks", transcript: "[0] Hi.\n[12.5] Sharks float." });
  });

  it("reads a chat body's screenshot, size, system prompt, history, and the user's words", () => {
    const context = contextFromRequest("/chat", {
      system: [{ type: "text", text: "you are clicky", cache_control: { type: "ephemeral" } }],
      messages: [
        { role: "user", content: "how do i download this page as a pdf?" },
        { role: "assistant", content: "click the blue button." },
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "U0NSRUVO" } },
            { type: "text", text: "user's screen (cursor is here) (image dimensions: 1280x800 pixels)" },
            { type: "text", text: "what are the four chambers called?" },
          ],
        },
      ],
    });

    assert.deepEqual(context, {
      kind: "chat",
      frameBase64: "U0NSRUVO",
      width: 1280,
      height: 800,
      systemPrompt: "you are clicky",
      history: "User: how do i download this page as a pdf?\nClicky: click the blue button.",
      question: "what are the four chambers called?",
    });
  });

  it("gives nothing for a route it does not judge or a body without what it needs", () => {
    assert.equal(contextFromRequest("/landmark", { frameBase64: "QUJD" }), undefined);
    assert.equal(contextFromRequest("/video-frame-parts", {}), undefined);
    assert.equal(contextFromRequest("/chat", { messages: [{ role: "user", content: "hi" }] }), undefined);
    assert.equal(contextFromRequest("/chat", "text"), undefined);
  });
});

describe("overlayPage", () => {
  const partsReply = JSON.stringify({
    subjectFound: true,
    subjectBox: { left: 100, top: 50, right: 600, bottom: 400 },
    isArtwork: false,
    wholePictureIsSubject: false,
    pictureShowsDepth: false,
    parts: [
      { label: "Aorta", x: 300, y: 120, isQuizAnswer: false },
      { label: "<b>Left ventricle</b>", x: 420, y: 300, isQuizAnswer: true },
    ],
  });

  it("draws the subject box and a numbered dot for each part at its pixel, over the frame at its size", () => {
    const page = overlayPage(frameContext, partsReply);

    assert.ok(page !== undefined);
    assert.deepEqual([page.width, page.height], [1280, 720]);
    assert.ok(page.html.includes('src="data:image/jpeg;base64,RlJBTUU="'));
    assert.ok(page.html.includes('<rect x="100" y="50" width="500" height="350"'));
    assert.ok(page.html.includes('<circle cx="300" cy="120"'));
    assert.ok(page.html.includes('<circle cx="420" cy="300"'));
    assert.ok(page.html.includes(">1 Aorta<"));
  });

  it("escapes a label, so a reply cannot add markup to the page", () => {
    const page = overlayPage(frameContext, partsReply);

    assert.ok(page !== undefined);
    assert.ok(!page.html.includes("<b>Left"));
    assert.ok(page.html.includes("&lt;b&gt;Left ventricle&lt;/b&gt;"));
  });

  it("draws nothing over the frame for no subject or a reply that is not JSON", () => {
    for (const replyText of [JSON.stringify({ subjectFound: false }), "not json", "[]"]) {
      const page = overlayPage(frameContext, replyText);

      assert.ok(page !== undefined);
      assert.ok(!page.html.includes("<circle") && !page.html.includes("<polyline"), replyText);
    }
  });

  it("draws each flow as a line through its points in its color, with an arrowhead and its number", () => {
    const page = overlayPage(flowsContext, JSON.stringify({ flows: [{ color: "red", style: "droplets", points: [[100, 100], [200, 150], [300, 150]] }] }));

    assert.ok(page !== undefined);
    assert.ok(page.html.includes('points="100,100 200,150 300,150"'));
    assert.ok(page.html.includes('stroke="#ef4444"'));
    assert.ok(page.html.includes("<polygon"));
    assert.ok(page.html.includes(">1<"));
  });

  it("draws no line for an empty flow list or a flow of one point", () => {
    assert.ok(!overlayPage(flowsContext, JSON.stringify({ flows: [] }))?.html.includes("<polyline"));
    assert.ok(!overlayPage(flowsContext, JSON.stringify({ flows: [{ color: "red", style: "air", points: [[1, 1]] }] }))?.html.includes("<polyline"));
  });

  it("circles the point a chat reply names, and draws nothing for none", () => {
    const pointed = overlayPage(chatContext, "see that button? [POINT:1200,60:download pdf]");
    const unpointed = overlayPage(chatContext, "the heart has four chambers. [POINT:none]");

    assert.ok(pointed?.html.includes('<circle cx="1200" cy="60" r="26"'));
    assert.ok(pointed?.html.includes("download pdf"));
    assert.ok(!unpointed?.html.includes("<circle"));
  });

  it("has no picture for a quiz plan", () => {
    assert.equal(overlayPage({ kind: "quizPlan", title: "t", transcript: "" }, "{}"), undefined);
  });
});

describe("pointInChatReply", () => {
  it("reads the coordinates and the label, and nothing from none", () => {
    assert.deepEqual(pointInChatReply("go here [POINT:12,34:the button:screen1]"), { x: 12, y: 34, label: "the button" });
    assert.deepEqual(pointInChatReply("go here [POINT:12,34]"), { x: 12, y: 34, label: "" });
    assert.equal(pointInChatReply("nothing [POINT:none]"), undefined);
  });
});

describe("describeReply", () => {
  it("lists the flags and the numbered parts of a frame parts reply, and says when there is no subject", () => {
    const text = describeReply(
      frameContext,
      JSON.stringify({ subjectFound: true, isArtwork: true, wholePictureIsSubject: false, pictureShowsDepth: false, parts: [{ label: "Ear", isQuizAnswer: true }] }),
    );

    assert.ok(text.includes("isArtwork: true") && text.includes("1. Ear (the quiz answer)"));
    assert.ok(describeReply(frameContext, JSON.stringify({ subjectFound: false })).includes("no single subject"));
  });

  it("summarizes flows, and says when nothing flows", () => {
    assert.ok(describeReply(flowsContext, JSON.stringify({ flows: [{ color: "blue", style: "air", points: [[1, 1], [2, 2]] }] })).includes("1. air in blue, 2 points"));
    assert.ok(describeReply(flowsContext, JSON.stringify({ flows: [] })).includes("No flows"));
  });

  it("lists each quiz moment with its question and answer", () => {
    const text = describeReply(
      { kind: "quizPlan", title: "t", transcript: "" },
      JSON.stringify({
        moments: [
          { pauseAtSeconds: 60, sourceLineSeconds: 50, question: "What floats?", answerLabel: "liver", explanation: "Oil." },
          { pauseAtSeconds: 200, sourceLineSeconds: 190, question: "What lifts?", answerLabel: "fins", explanation: "Lift." },
        ],
      }),
    );

    assert.ok(text.includes("Pause at 60s") && text.includes("Question: What floats?") && text.includes("Answer: liver"));
    assert.ok(text.includes("2. Pause at 200s") && text.includes("Answer: fins"));
  });

  it("gives a chat reply's spoken words without the tag, and where the cursor goes", () => {
    const text = describeReply(chatContext, "click that [POINT:10,20:button]");

    assert.ok(text.includes("Spoken: click that") && !text.includes("[POINT"));
    assert.ok(text.includes("(10, 20)"));
  });

  it("quotes a reply that is not the shape it should be, so the judge sees the failure", () => {
    assert.ok(describeReply(frameContext, "garbage").includes("garbage"));
  });
});

describe("judgePromptParts", () => {
  const textOf = (parts: ReturnType<typeof judgePromptParts>) => parts.flatMap((part) => (part.kind === "text" ? [part.text] : []));

  it("shows the frame once, then reply A with its drawing, then reply B with its drawing", () => {
    const parts = judgePromptParts(frameContext, { description: "first reply", overlayPNGBase64: "QQ==" }, { description: "second reply", overlayPNGBase64: "Qg==" });

    assert.deepEqual(
      parts.map((part) => (part.kind === "text" ? part.text.slice(0, 7) : `image ${part.mediaType} ${part.base64}`)),
      ["Purpose", "The fra", "image image/jpeg RlJBTUU=", "Reply A", "image image/png QQ==", "Reply B", "image image/png Qg=="],
    );
    assert.ok(textOf(parts)[2].includes("first reply") && textOf(parts)[3].includes("second reply"));
  });

  it("holds the transcript and no image for a quiz plan", () => {
    const parts = judgePromptParts({ kind: "quizPlan", title: "Sharks", transcript: "[0] Hi." }, { description: "plan one", overlayPNGBase64: undefined }, { description: "plan two", overlayPNGBase64: undefined });

    assert.ok(parts.every((part) => part.kind === "text"));
    assert.ok(textOf(parts).some((text) => text.includes("Sharks") && text.includes("[0] Hi.")));
  });

  it("holds the system prompt and the user's words for chat", () => {
    const parts = judgePromptParts(chatContext, { description: "a", overlayPNGBase64: "QQ==" }, { description: "b", overlayPNGBase64: "Qg==" });

    assert.ok(textOf(parts).some((text) => text.includes("you are clicky") && text.includes("how do i download this")));
  });
});

describe("parseJudgeVerdict", () => {
  it("reads a winner and a reason, and refuses any other winner", () => {
    assert.deepEqual(parseJudgeVerdict('{"reason":"A is closer","winner":"A"}'), { winner: "A", reason: "A is closer" });
    assert.deepEqual(parseJudgeVerdict('{"winner":"tie"}'), { winner: "tie", reason: "" });
    assert.equal(parseJudgeVerdict('{"winner":"C","reason":""}'), undefined);
    assert.equal(parseJudgeVerdict("not json"), undefined);
  });
});

describe("spotCheckPage", () => {
  it("shows both replies, hides the reveal in a details block, and escapes text from a reply", () => {
    const page = spotCheckPage([
      {
        title: "/chat, case chat-first",
        request: "The user said: <script>",
        replies: [{ description: "reply <one>", imageFileName: "abc.png" }, { description: "reply two", imageFileName: undefined }],
        reveal: "A is parts-sol",
      },
    ]);

    assert.ok(page.includes('<img src="images/abc.png"'));
    assert.ok(page.includes("reply &lt;one&gt;") && page.includes("&lt;script&gt;") && !page.includes("<script>"));
    assert.ok(/<details><summary>[^<]*<\/summary><pre>A is parts-sol<\/pre><\/details>/.test(page));
    assert.ok(page.indexOf("<details>") > page.indexOf("reply two"));
  });
});
