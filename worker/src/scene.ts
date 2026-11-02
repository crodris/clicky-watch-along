/**
 * POST /scene
 *
 * A full scene is too slow to generate before Clicky can speak, so this route
 * takes two steps. Haiku only picks a template. The blue whale and the water
 * molecule are hand-tuned files. Every other subject is generated once by Sonnet
 * and checked against the scene schema. An invalid spec is retried once, then returned as 422.
 */

import { z } from "zod";
import { sceneSpecSchema } from "../../scene/src/spec";
import waterScene from "../../scene/fixtures/water.json";
import whaleScene from "../../scene/fixtures/whale.json";

const maximumBuildAttempts = 2;

const sceneRequestSchema = z.object({
  question: z.string(),
  screenshotBase64: z.string(),
  screenshotMediaType: z.enum(["image/jpeg", "image/png"]),
});

const pickSceneInputSchema = z.object({
  template: z.enum(["blue_whale", "water_molecule", "none"]),
});

const anthropicMessageSchema = z.object({
  content: z.array(
    z.object({
      type: z.string(),
      name: z.string().optional(),
      input: z.unknown().optional(),
    }),
  ),
});

type SceneRequest = z.infer<typeof sceneRequestSchema>;
type AnthropicMessage = z.infer<typeof anthropicMessageSchema>;

type JsonSchema = {
  type?: "object" | "string" | "number" | "integer" | "boolean" | "array";
  description?: string;
  enum?: string[];
  pattern?: string;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  items?: JsonSchema;
  prefixItems?: JsonSchema[];
  minItems?: number;
  maxItems?: number;
  minimum?: number;
  maximum?: number;
  exclusiveMinimum?: number;
  oneOf?: JsonSchema[];
};

type LearnerTurn = {
  role: "user";
  content: Array<
    | {
        type: "image";
        source: {
          type: "base64";
          media_type: "image/jpeg" | "image/png";
          data: string;
        };
      }
    | { type: "text"; text: string }
  >;
};

const hexColorSchema: JsonSchema = {
  type: "string",
  pattern: "^#[0-9a-fA-F]{6}$",
  description: "Color as #rrggbb.",
};

function vec3Schema(description: string): JsonSchema {
  return {
    type: "array",
    description,
    minItems: 3,
    maxItems: 3,
    items: { type: "number" },
  };
}

const vec2Schema: JsonSchema = {
  type: "array",
  description: "A pair of numbers.",
  minItems: 2,
  maxItems: 2,
  items: { type: "number" },
};

const skinSchema: JsonSchema = {
  type: "object",
  description: "Living outer surface: countershaded color, mottling, and throat pleats.",
  properties: {
    topColor: hexColorSchema,
    bellyColor: hexColorSchema,
    mottling: {
      type: "number",
      minimum: 0,
      maximum: 1,
      description: "How broken up the color is, from 0 to 1.",
    },
    grooves: {
      type: "boolean",
      description: "Throat pleats along the belly.",
    },
    interiorColor: {
      ...hexColorSchema,
      description: "What the inside of a translucent shell looks like once it has faded.",
    },
  },
  required: ["topColor", "bellyColor", "mottling", "grooves"],
};

const tissueSchema: JsonSchema = {
  type: "object",
  description: "Wet inner surface for organs and bones.",
  properties: {
    pattern: {
      type: "string",
      enum: ["muscle", "spongy", "folded", "bone", "wall", "smooth"],
    },
    veinColor: hexColorSchema,
  },
  required: ["pattern"],
};

const repeatSchema: JsonSchema = {
  type: "object",
  properties: {
    count: { type: "integer", minimum: 2, maximum: 24 },
    offset: vec3Schema("Distance added for each copy."),
    endScale: {
      type: "number",
      exclusiveMinimum: 0,
      description: "Scale of the last copy. Copies between step evenly from 1 to this value.",
    },
  },
  required: ["count", "offset"],
};

const sharedPartProperties: Record<string, JsonSchema> = {
  id: { type: "string", description: "Stable id. quiz.partId must match one part id." },
  label: {
    type: "string",
    description: "Words a 10-year-old can read. An empty label draws no pill or leader line.",
  },
  position: vec3Schema("Center of the part."),
  rotation: vec3Schema("Optional Euler rotation in radians."),
  labelAt: vec3Schema("Where the leader line points. Defaults to the middle of the part."),
  color: hexColorSchema,
  opacity: {
    type: "number",
    minimum: 0,
    maximum: 1,
    description:
      "Below 1 the part is a shell. It stays solid until the last camera move, then fades down to this opacity so inner parts show through it.",
  },
  skin: skinSchema,
  tissue: tissueSchema,
  mirror: {
    type: "boolean",
    description: "Adds a copy reflected across the z = 0 plane.",
  },
  repeat: repeatSchema,
  inner: {
    type: "boolean",
    description: "Inner parts stay hidden, with their labels, until the shell starts to fade.",
  },
};

const sharedPartRequired = ["id", "label", "position", "color", "shape"];

function partObjectSchema(
  description: string,
  shapeSchema: JsonSchema,
  extraProperties: Record<string, JsonSchema>,
  extraRequired: string[],
): JsonSchema {
  return {
    type: "object",
    description,
    properties: {
      ...sharedPartProperties,
      shape: shapeSchema,
      ...extraProperties,
    },
    required: [...sharedPartRequired, ...extraRequired],
  };
}

const loftStationSchema: JsonSchema = {
  type: "object",
  properties: {
    x: { type: "number", description: "Position along the body axis." },
    y: {
      type: "number",
      description: "Height of the axis at this station. Lets a body arch or droop.",
    },
    top: { type: "number", minimum: 0, description: "Distance above the axis." },
    bottom: { type: "number", minimum: 0, description: "Distance below the axis." },
    width: { type: "number", minimum: 0, description: "Half width." },
  },
  required: ["x", "top", "bottom", "width"],
};

const loftCreaseSchema: JsonSchema = {
  type: "object",
  description:
    "Angles around a loft run from 0 on the top line to 180 on the belly line, and apply to both sides of the body.",
  properties: {
    path: {
      type: "array",
      description: "Each point is [x, around degrees].",
      minItems: 2,
      maxItems: 24,
      items: vec2Schema,
    },
    width: { type: "number", exclusiveMinimum: 0 },
    depth: {
      type: "number",
      description: "Positive cuts a groove. Negative raises a ridge.",
    },
  },
  required: ["path", "width", "depth"],
};

const loftBumpSchema: JsonSchema = {
  type: "object",
  properties: {
    x: { type: "number" },
    around: { type: "number", minimum: 0, maximum: 180 },
    length: { type: "number", exclusiveMinimum: 0 },
    span: { type: "number", exclusiveMinimum: 0 },
    height: { type: "number" },
  },
  required: ["x", "around", "length", "span", "height"],
};

const primitivePartSchema = partObjectSchema(
  "A box, sphere, cylinder, capsule, or torus.",
  { type: "string", enum: ["box", "sphere", "cylinder", "capsule", "torus"] },
  { size: vec3Schema("Width, height, and depth.") },
  ["size"],
);

const loftPartSchema = partObjectSchema(
  "A body swept through cross-section stations.",
  { type: "string", enum: ["loft"] },
  {
    stations: {
      type: "array",
      minItems: 4,
      maxItems: 24,
      items: loftStationSchema,
    },
    creases: {
      type: "array",
      maxItems: 8,
      items: loftCreaseSchema,
    },
    bumps: {
      type: "array",
      maxItems: 12,
      items: loftBumpSchema,
    },
  },
  ["stations"],
);

const finPartSchema = partObjectSchema(
  "A flat fin or flipper.",
  { type: "string", enum: ["fin"] },
  {
    outline: {
      type: "array",
      minItems: 3,
      maxItems: 24,
      items: vec2Schema,
      description: "Outline in the fin's plane.",
    },
    thickness: { type: "number", exclusiveMinimum: 0 },
  },
  ["outline", "thickness"],
);

const tubePointSchema: JsonSchema = {
  type: "array",
  description: "Each point is [x, y, z, radius]. The radius is positive.",
  minItems: 4,
  maxItems: 4,
  prefixItems: [
    { type: "number" },
    { type: "number" },
    { type: "number" },
    { type: "number", exclusiveMinimum: 0, description: "Radius." },
  ],
};

const tubePartSchema = partObjectSchema(
  "A path with a radius at each point, such as a vessel or a spine.",
  { type: "string", enum: ["tube"] },
  {
    points: {
      type: "array",
      minItems: 2,
      maxItems: 32,
      items: tubePointSchema,
    },
    beads: {
      type: "integer",
      minimum: 0,
      maximum: 80,
      description: "Rounded segments along the length, such as vertebrae.",
    },
  },
  ["points"],
);

const cameraStopSchema: JsonSchema = {
  type: "object",
  properties: {
    position: vec3Schema("Where the camera stands."),
    lookAt: vec3Schema("Where the camera looks."),
  },
  required: ["position", "lookAt"],
};

// Written by hand to match scene/src/spec.ts, including every shape and surface.
const buildSceneInputSchema: JsonSchema = {
  type: "object",
  properties: {
    title: { type: "string" },
    parts: {
      type: "array",
      minItems: 1,
      maxItems: 16,
      items: {
        oneOf: [primitivePartSchema, loftPartSchema, finPartSchema, tubePartSchema],
      },
    },
    cameraStops: {
      type: "array",
      description: "Exactly three stops. The last one ends beside the quiz part.",
      minItems: 3,
      maxItems: 3,
      items: cameraStopSchema,
    },
    quiz: {
      type: "object",
      properties: {
        partId: {
          type: "string",
          description: "Id of the part the quiz hides. Must match a part id.",
        },
        question: {
          type: "string",
          description: "Asks the learner to name the hidden part. Does not contain the answer.",
        },
      },
      required: ["partId", "question"],
    },
  },
  required: ["title", "parts", "cameraStops", "quiz"],
};

const pickSceneSystemPrompt = [
  "You choose a field-trip template. The subject is what the learner names. When they name nothing, it is the subject in the screenshot.",
  "Call pick_scene.",
  'Return template "blue_whale" when the subject is a blue whale, or a whale with no species named.',
  'Return template "water_molecule" when the subject is water, a water molecule, or H2O.',
  'Return template "none" for every other subject.',
].join("\n");

const buildSceneSystemPrompt = [
  "You build a labeled 3D field-trip scene. The subject is what the learner names. When they name nothing, it is the subject in their screenshot.",
  "Call build_scene with the scene spec.",
  "",
  "Requirements:",
  "- Labels are words a 10-year-old can read.",
  "- Use 16 parts at most.",
  "- Every part's shape is box, sphere, cylinder, capsule, torus, loft, fin, or tube. There is no cone shape, so use a cylinder for a cone. A loft needs at least 4 sections.",
  "- When the subject has an inside, the outer part is a translucent shell.",
  "- Center the subject at the origin, inside a box 6 units on each side.",
  "- Use three camera stops. The last stop ends beside the most interesting part, with neighboring parts still in view.",
  "- The quiz hides that part. quiz.partId is that part. quiz.question opens with one cheerful sentence saying you have arrived inside the subject, points at the spot marked with a question mark, then asks the learner to name it. It does not contain the answer. That part's label is one word the learner would say out loud, such as Oxygen, not Oxygen atom.",
  "",
  "Worked example of this schema. The blue whale below is a hand-tuned template, so its coordinates extend past the 6 unit box. A new subject still has to fit inside that box.",
  JSON.stringify(whaleScene),
].join("\n");

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function learnerTurn(sceneRequest: SceneRequest): LearnerTurn {
  return {
    role: "user",
    content: [
      {
        type: "image",
        source: {
          type: "base64",
          media_type: sceneRequest.screenshotMediaType,
          data: sceneRequest.screenshotBase64,
        },
      },
      { type: "text", text: sceneRequest.question },
    ],
  };
}

function toolInputNamed(message: AnthropicMessage, toolName: string): unknown {
  const toolUseBlock = message.content.find((contentBlock) => {
    return contentBlock.type === "tool_use" && contentBlock.name === toolName;
  });
  return toolUseBlock?.input;
}

async function callAnthropic(
  anthropicAPIKey: string,
  body: unknown,
): Promise<{ ok: true; message: AnthropicMessage } | { ok: false; response: Response }> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": anthropicAPIKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`[/scene] Anthropic API error ${response.status}: ${errorText}`);
    return {
      ok: false,
      response: jsonResponse(
        { error: errorText.length > 0 ? errorText : "Anthropic request failed" },
        response.status,
      ),
    };
  }

  let responseJSON: unknown;
  try {
    responseJSON = await response.json();
  } catch {
    return {
      ok: false,
      response: jsonResponse({ error: "Anthropic returned a body that was not JSON" }, 502),
    };
  }

  const parsedMessage = anthropicMessageSchema.safeParse(responseJSON);
  if (!parsedMessage.success) {
    return {
      ok: false,
      response: jsonResponse({ error: "Anthropic response was missing tool content" }, 502),
    };
  }

  return { ok: true, message: parsedMessage.data };
}

export async function handleScene(request: Request, anthropicAPIKey: string): Promise<Response> {
  let requestJSON: unknown;
  try {
    requestJSON = await request.json();
  } catch {
    return jsonResponse({ error: "Request body must be JSON" }, 400);
  }

  const parsedRequest = sceneRequestSchema.safeParse(requestJSON);
  if (!parsedRequest.success) {
    return jsonResponse({ error: parsedRequest.error.message }, 400);
  }
  const sceneRequest = parsedRequest.data;

  const pickResult = await callAnthropic(anthropicAPIKey, {
    model: "claude-haiku-5-5",
    max_tokens: 1024,
    system: pickSceneSystemPrompt,
    tools: [
      {
        name: "pick_scene",
        description: "Choose the field-trip template for this subject.",
        input_schema: {
          type: "object",
          properties: {
            template: {
              type: "string",
              enum: ["blue_whale", "water_molecule", "none"],
              description: "blue_whale when the subject is a blue whale, or a whale with no species named. water_molecule when the subject is water, a water molecule, or H2O. none for every other subject.",
            },
          },
          required: ["template"],
        },
      },
    ],
    tool_choice: { type: "tool", name: "pick_scene", disable_parallel_tool_use: true },
    messages: [learnerTurn(sceneRequest)],
  });
  if (!pickResult.ok) {
    return pickResult.response;
  }

  const parsedPick = pickSceneInputSchema.safeParse(toolInputNamed(pickResult.message, "pick_scene"));
  if (!parsedPick.success) {
    return jsonResponse({ error: parsedPick.error.message }, 502);
  }
  if (parsedPick.data.template === "blue_whale") {
    return jsonResponse(whaleScene, 200);
  }
  if (parsedPick.data.template === "water_molecule") {
    return jsonResponse(waterScene, 200);
  }

  // One retry, because low effort sometimes breaks the schema in a new way and a
  // failed scene leaves the learner with a voice and nothing on screen.
  let lastValidationError = "";
  for (let attempt = 1; attempt <= maximumBuildAttempts; attempt += 1) {
    const buildResult = await callAnthropic(anthropicAPIKey, {
      model: "claude-sonnet-5-5",
      max_tokens: 6000,
      system: `${buildSceneSystemPrompt}\n\nCall build_scene exactly once. Do not write any other text.`,
      // Low effort because the learner is waiting on this scene.
      output_config: { effort: "low" },
      tools: [
        {
          name: "build_scene",
          description: "Build the labeled 3D field-trip scene for this subject.",
          input_schema: buildSceneInputSchema,
        },
      ],
      // Sonnet 5.5 rejects forced tool use, so the prompt asks for the call and
      // sceneSpecSchema still rejects a reply that skips it.
      tool_choice: { type: "auto", disable_parallel_tool_use: true },
      messages: [learnerTurn(sceneRequest)],
    });
    if (!buildResult.ok) {
      return buildResult.response;
    }

    const parsedScene = sceneSpecSchema.safeParse(toolInputNamed(buildResult.message, "build_scene"));
    if (parsedScene.success) {
      return jsonResponse(parsedScene.data, 200);
    }
    lastValidationError = parsedScene.error.message;
  }
  return jsonResponse({ error: lastValidationError }, 422);
}
