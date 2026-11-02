import { z } from "zod";

const vec3Schema = z.tuple([z.number(), z.number(), z.number()]);
const vec2Schema = z.tuple([z.number(), z.number()]);

const hexColorSchema = z
  .string()
  .regex(/^#[0-9a-fA-F]{6}$/, "color must be #rrggbb");

// Living outer surface: countershaded color, mottling, and throat pleats.
const skinSchema = z.object({
  topColor: hexColorSchema,
  bellyColor: hexColorSchema,
  mottling: z.number().min(0).max(1),
  grooves: z.boolean(),
  // What the inside of a translucent shell looks like once it has faded.
  interiorColor: hexColorSchema.optional(),
});

// Wet inner surface for organs and bones. "liquid" is the exception: it is for
// a shell of clear water, seen from outside and then from within.
const tissueSchema = z.object({
  pattern: z.enum(["muscle", "spongy", "folded", "bone", "wall", "smooth", "liquid"]),
  veinColor: hexColorSchema.optional(),
});

const repeatSchema = z.object({
  count: z.number().int().min(2).max(24),
  offset: vec3Schema,
  // Scale of the last copy. Copies between step evenly from 1 to this value.
  endScale: z.number().positive().optional().default(1),
});

const sharedPartFields = {
  id: z.string(),
  // An empty label draws no pill or leader line.
  label: z.string(),
  position: vec3Schema,
  rotation: vec3Schema.optional(),
  // Where the leader line points. Defaults to the middle of the part.
  labelAt: vec3Schema.optional(),
  color: hexColorSchema,
  // Below 1 the part is a shell. It stays solid until the last camera move,
  // then fades down to this opacity so inner parts show through it.
  opacity: z.number().min(0).max(1).optional().default(1),
  skin: skinSchema.optional(),
  tissue: tissueSchema.optional(),
  // Adds a copy reflected across the z = 0 plane.
  mirror: z.boolean().optional().default(false),
  repeat: repeatSchema.optional(),
  // Inner parts stay hidden, with their labels, until the shell starts to fade.
  inner: z.boolean().optional().default(false),
};

const primitivePartSchema = z.object({
  ...sharedPartFields,
  shape: z.enum(["box", "sphere", "cylinder", "capsule", "torus"]),
  size: vec3Schema,
});

const loftStationSchema = z.object({
  // Position along the body axis.
  x: z.number(),
  // Height of the axis at this station. Lets a body arch or droop.
  y: z.number().optional().default(0),
  // Distances above and below the axis, and the half width.
  top: z.number().min(0),
  bottom: z.number().min(0),
  width: z.number().min(0),
});

// Angles around a loft run from 0 on the top line to 180 on the belly line,
// and apply to both sides of the body.
const loftCreaseSchema = z.object({
  // Each point is [x, around degrees].
  path: z.array(vec2Schema).min(2).max(24),
  width: z.number().positive(),
  // Positive cuts a groove. Negative raises a ridge.
  depth: z.number(),
});

const loftBumpSchema = z.object({
  x: z.number(),
  around: z.number().min(0).max(180),
  length: z.number().positive(),
  span: z.number().positive(),
  height: z.number(),
});

const loftPartSchema = z.object({
  ...sharedPartFields,
  shape: z.literal("loft"),
  stations: z.array(loftStationSchema).min(4).max(24),
  creases: z.array(loftCreaseSchema).max(8).optional().default([]),
  bumps: z.array(loftBumpSchema).max(12).optional().default([]),
});

const finPartSchema = z.object({
  ...sharedPartFields,
  shape: z.literal("fin"),
  outline: z.array(vec2Schema).min(3).max(24),
  thickness: z.number().positive(),
});

const tubePartSchema = z.object({
  ...sharedPartFields,
  shape: z.literal("tube"),
  // Each point is [x, y, z, radius].
  points: z
    .array(z.tuple([z.number(), z.number(), z.number(), z.number().positive()]))
    .min(2)
    .max(32),
  // Rounded segments along the length, such as vertebrae.
  beads: z.number().int().min(0).max(80).optional().default(0),
});

export const partSchema = z.discriminatedUnion("shape", [
  primitivePartSchema,
  loftPartSchema,
  finPartSchema,
  tubePartSchema,
]);

export const cameraStopSchema = z.object({
  position: vec3Schema,
  lookAt: vec3Schema,
});

export const sceneSpecSchema = z
  .object({
    title: z.string(),
    parts: z.array(partSchema).min(1).max(16),
    cameraStops: z.tuple([
      cameraStopSchema,
      cameraStopSchema,
      cameraStopSchema,
    ]),
    quiz: z.object({
      partId: z.string(),
      question: z.string(),
    }),
  })
  .refine(
    (sceneSpec) =>
      sceneSpec.parts.some((part) => part.id === sceneSpec.quiz.partId),
    {
      message: "quiz partId must match a part id",
      path: ["quiz", "partId"],
    },
  );

export type Part = z.infer<typeof partSchema>;
export type LoftPart = z.infer<typeof loftPartSchema>;
export type FinPart = z.infer<typeof finPartSchema>;
export type TubePart = z.infer<typeof tubePartSchema>;
export type Skin = z.infer<typeof skinSchema>;
export type Tissue = z.infer<typeof tissueSchema>;
export type CameraStop = z.infer<typeof cameraStopSchema>;
export type SceneSpec = z.infer<typeof sceneSpecSchema>;
