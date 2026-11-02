import { z } from "zod";

const vec3Schema = z.tuple([z.number(), z.number(), z.number()]);

export const partShapeSchema = z.enum([
  "box",
  "sphere",
  "cylinder",
  "capsule",
  "torus",
]);

const hexColorSchema = z
  .string()
  .regex(/^#[0-9a-fA-F]{6}$/, "color must be #rrggbb");

export const partSchema = z.object({
  id: z.string(),
  label: z.string(),
  shape: partShapeSchema,
  position: vec3Schema,
  size: vec3Schema,
  rotation: vec3Schema.optional(),
  color: hexColorSchema,
  opacity: z.number().min(0).max(1).optional().default(1),
});

export const cameraStopSchema = z.object({
  position: vec3Schema,
  lookAt: vec3Schema,
});

export const sceneSpecSchema = z
  .object({
    title: z.string(),
    parts: z.array(partSchema).min(1).max(10),
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
export type CameraStop = z.infer<typeof cameraStopSchema>;
export type SceneSpec = z.infer<typeof sceneSpecSchema>;
