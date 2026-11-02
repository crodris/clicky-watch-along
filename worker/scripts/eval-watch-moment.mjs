// Sends six invented shark documentary transcripts to a running `wrangler dev`.
// Usage: node worker/scripts/eval-watch-moment.mjs [baseUrl]
// Default baseUrl is http://127.0.0.1:8790.

const baseUrl = process.argv[2] ?? "http://127.0.0.1:8790";

// A 16x16 solid blue JPEG. The route only needs a valid image to attach.
const screenshotBase64 =
  "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAEKADAAQAAAABAAAAEAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAEAAQAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A+N6KKK/ow/nc/9k=";

const liverFact =
  "Sharks have no swim bladder like other fish. Instead they have an enormous liver, and in a great white it can be a quarter of its body weight. The liver is packed with oil, and oil is lighter than water, so it helps the shark stay afloat without swimming hard.";

const teethFact =
  "A shark's teeth are not rooted in its jaw. They sit in rows, like a conveyor belt. When a front tooth breaks or falls out, the tooth behind it rotates forward to take its place, so a shark can go through thousands of teeth in a lifetime.";

const ampullaeFact =
  "Around its snout a shark has tiny jelly-filled pores called ampullae of Lorenzini. These pores sense the faint electric fields that every living animal gives off. That is how a shark finds a fish buried in the sand, even when it cannot see or smell it.";

const cases = [
  {
    name: "intro",
    expectPause: false,
    alreadyAskedQuestions: [],
    transcript:
      "Welcome back to Deep Blue Wonders. Today we are diving into the secret life of sharks. We will meet a few of the ocean's most misunderstood hunters, and I promise there are some surprises coming up. So grab a snack, get comfortable, and let's get into it.",
    newTranscript:
      "We will meet a few of the ocean's most misunderstood hunters, and I promise there are some surprises coming up. So grab a snack, get comfortable, and let's get into it.",
  },
  {
    name: "sponsor read",
    expectPause: false,
    alreadyAskedQuestions: [],
    transcript:
      "Before we go on, a quick word from today's sponsor, AquaPack. AquaPack makes the toughest waterproof backpacks I have ever used. I took mine on three boat trips this year and everything stayed bone dry. Use the code SHARKS at checkout for twenty percent off, and now back to the show.",
    newTranscript:
      "I took mine on three boat trips this year and everything stayed bone dry. Use the code SHARKS at checkout for twenty percent off, and now back to the show.",
  },
  {
    name: "cut mid-explanation",
    expectPause: false,
    alreadyAskedQuestions: [],
    transcript:
      "Around its snout a shark has tiny jelly-filled pores called ampullae of Lorenzini. These pores are a kind of sixth sense, and what they do is detect the faint",
    newTranscript:
      "These pores are a kind of sixth sense, and what they do is detect the faint",
  },
  {
    name: "liver finished",
    expectPause: true,
    alreadyAskedQuestions: [],
    transcript: `Now let's talk about what keeps a shark from sinking. ${liverFact}`,
    newTranscript: liverFact,
  },
  {
    name: "teeth finished, liver already asked",
    expectPause: true,
    alreadyAskedQuestions: [
      "Let's pause here! What does the big oily organ do for the shark?",
    ],
    transcript: `${liverFact} Now, the teeth. ${teethFact}`,
    newTranscript: `Now, the teeth. ${teethFact}`,
  },
  {
    name: "ampullae finished",
    expectPause: true,
    alreadyAskedQuestions: [],
    transcript: `A shark hunts with more than eyes and nose. ${ampullaeFact}`,
    newTranscript: ampullaeFact,
  },
];

const results = [];

for (const evalCase of cases) {
  const startedAt = performance.now();
  const response = await fetch(`${baseUrl}/watch-moment`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      transcript: evalCase.transcript,
      newTranscript: evalCase.newTranscript,
      alreadyAskedQuestions: evalCase.alreadyAskedQuestions,
      screenshotBase64,
      screenshotMediaType: "image/jpeg",
    }),
  });
  const elapsedMilliseconds = Math.round(performance.now() - startedAt);
  const body = await response.json();
  results.push({ evalCase, status: response.status, body, elapsedMilliseconds });
}

for (const { evalCase, status, body, elapsedMilliseconds } of results) {
  const paused = status === 200 && body.shouldPause === true;
  const verdict = status === 200 && paused === evalCase.expectPause ? "OK" : "MISMATCH";
  console.log(`[${verdict}] ${evalCase.name}: status ${status}, paused ${paused}, expected ${evalCase.expectPause}, ${elapsedMilliseconds} ms`);
  console.log(JSON.stringify(body, null, 2));
}

const slowest = results.reduce((slowestSoFar, result) =>
  result.elapsedMilliseconds > slowestSoFar.elapsedMilliseconds ? result : slowestSoFar,
);
console.log(`Slowest: ${slowest.evalCase.name} at ${slowest.elapsedMilliseconds} ms`);
