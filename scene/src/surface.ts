import { BackSide, Color, DoubleSide, FrontSide, MeshPhysicalMaterial, type Side } from "three";
import type { Skin, Tissue } from "./spec";

export type SurfaceFadeUniforms = {
  // 0 keeps a surface solid. 1 brings it fully down to fadedOpacity.
  shellFade: { value: number };
  fadedOpacity: { value: number };
  // 1 keeps a bright rim on the faded surface, so a shell keeps its silhouette.
  // 0 lets the surface vanish completely.
  fadedRim: { value: number };
};

const tissuePatternDefine = {
  muscle: "TISSUE_MUSCLE",
  spongy: "TISSUE_SPONGY",
  folded: "TISSUE_FOLDED",
  bone: "TISSUE_BONE",
  wall: "TISSUE_WALL",
  smooth: "TISSUE_SMOOTH",
  liquid: "TISSUE_LIQUID",
} as const;

const surfaceVertexDeclarations = /* glsl */ `
attribute vec4 surfaceCoordinate;
varying vec4 vSurfaceCoordinate;
varying vec3 vObjectPosition;
`;

const surfaceVertexAssignment = /* glsl */ `
vSurfaceCoordinate = surfaceCoordinate;
vObjectPosition = position;
`;

const noiseFunctions = /* glsl */ `
float hashPoint(vec3 point) {
  point = fract(point * 0.1031);
  point += dot(point, point.zyx + 31.32);
  return fract((point.x + point.y) * point.z);
}

float valueNoise(vec3 point) {
  vec3 cell = floor(point);
  vec3 blend = fract(point);
  blend = blend * blend * (3.0 - 2.0 * blend);
  return mix(
    mix(
      mix(hashPoint(cell), hashPoint(cell + vec3(1.0, 0.0, 0.0)), blend.x),
      mix(hashPoint(cell + vec3(0.0, 1.0, 0.0)), hashPoint(cell + vec3(1.0, 1.0, 0.0)), blend.x),
      blend.y
    ),
    mix(
      mix(hashPoint(cell + vec3(0.0, 0.0, 1.0)), hashPoint(cell + vec3(1.0, 0.0, 1.0)), blend.x),
      mix(hashPoint(cell + vec3(0.0, 1.0, 1.0)), hashPoint(cell + vec3(1.0, 1.0, 1.0)), blend.x),
      blend.y
    ),
    blend.z
  );
}

float fractalNoise(vec3 point, int octaveCount) {
  float total = 0.0;
  float amplitude = 0.5;
  float normalizer = 0.0;
  for (int octaveIndex = 0; octaveIndex < octaveCount; octaveIndex++) {
    total += amplitude * valueNoise(point);
    normalizer += amplitude;
    point = point * 2.03 + vec3(17.1, 9.2, 3.7);
    amplitude *= 0.5;
  }
  return total / normalizer;
}

// Distance from the nearest cell wall, zero on the wall itself.
float cellWallDistance(vec3 point) {
  vec3 cell = floor(point);
  float nearest = 8.0;
  float secondNearest = 8.0;
  for (int offsetZ = -1; offsetZ <= 1; offsetZ++) {
    for (int offsetY = -1; offsetY <= 1; offsetY++) {
      for (int offsetX = -1; offsetX <= 1; offsetX++) {
        vec3 neighbor = cell + vec3(float(offsetX), float(offsetY), float(offsetZ));
        vec3 seed = neighbor + vec3(
          hashPoint(neighbor),
          hashPoint(neighbor + 11.3),
          hashPoint(neighbor + 27.7)
        );
        float distanceToSeed = length(seed - point);
        if (distanceToSeed < nearest) {
          secondNearest = nearest;
          nearest = distanceToSeed;
        } else if (distanceToSeed < secondNearest) {
          secondNearest = distanceToSeed;
        }
      }
    }
  }
  return secondNearest - nearest;
}
`;

const surfaceFragmentFunctions = /* glsl */ `
varying vec4 vSurfaceCoordinate;
varying vec3 vObjectPosition;
uniform float detailScale;
uniform float shellFade;
uniform float fadedOpacity;
uniform float fadedRim;
uniform vec3 topColor;
uniform vec3 bellyColor;
uniform vec3 veinColor;
uniform float mottling;
uniform float hasGrooves;

${noiseFunctions}

float grooveMask(float alongBody, float aroundBody, float pleatEnd) {
  return smoothstep(0.012, 0.05, alongBody)
    * (1.0 - smoothstep(pleatEnd - 0.05, pleatEnd + 0.03, alongBody))
    * smoothstep(1.78, 1.98, aroundBody);
}

// Ventral pleats run along the body. Using the angle around it makes them
// converge at the chin, the way they do on a rorqual.
float grooveHeight(float alongBody, float aroundBody, float pixelFootprint) {
  float wander = (fractalNoise(vec3(alongBody * 7.0, aroundBody * 3.0, 3.0), 2) - 0.5) * 0.11;
  float phase = (aroundBody + wander) * 62.0;
  float visibility = 1.0 - smoothstep(0.7, 1.9, pixelFootprint * 62.0);
  // Every pleat gets its own depth and end point, so they do not look machined.
  float pleatIndex = floor(phase / 3.14159 + 0.5);
  float pleatRandom = hashPoint(vec3(pleatIndex, 7.0, 3.0));
  float pleatEnd = 0.32 + pleatRandom * 0.15;
  float pleatDepth = 0.55 + hashPoint(vec3(pleatIndex, 2.0, 9.0)) * 0.45;
  float brokenLine = smoothstep(0.17, 0.3, valueNoise(vec3(alongBody * 15.0, pleatIndex * 1.7, 5.0)));
  float pleat = 1.0 - pow(abs(cos(phase)), 7.0);
  return (pleat - 1.0) * pleatDepth * brokenLine * visibility * grooveMask(alongBody, aroundBody, pleatEnd);
}

// Vessels branch, and cell walls branch. Iso-lines of plain noise close into
// rings, which read as a contour map instead of anatomy.
float vesselAmount(vec3 detailPosition) {
  vec3 warpedPosition = detailPosition + (fractalNoise(detailPosition * 1.7, 2) - 0.5) * 0.9;
  float wallDistance = cellWallDistance(warpedPosition * vec3(1.5, 3.4, 3.4));
  float presence = smoothstep(0.4, 0.6, fractalNoise(detailPosition * 1.2 + 31.0, 2));
  return smoothstep(0.05, 0.006, wallDistance) * presence;
}

float surfaceHeight(vec3 objectPosition, float alongBody, float aroundBody, float pixelFootprint) {
  vec3 detailPosition = objectPosition * detailScale;
  float height = 0.0;
  #if defined(SURFACE_SKIN)
    float wrinkleVisibility = 1.0 - smoothstep(0.006, 0.03, pixelFootprint);
    height += (fractalNoise(detailPosition * vec3(1.1, 3.4, 3.4), 3) - 0.5) * 0.016;
    height += (fractalNoise(detailPosition * vec3(8.0, 30.0, 30.0), 2) - 0.5) * 0.0032 * wrinkleVisibility;
    if (hasGrooves > 0.5) {
      height += grooveHeight(alongBody, aroundBody, pixelFootprint) * 0.0085;
    }
  #elif defined(TISSUE_MUSCLE)
    height += vesselAmount(detailPosition) * 0.006;
    height += (valueNoise(detailPosition * vec3(5.0, 30.0, 30.0)) - 0.5) * 0.0028;
    height += (fractalNoise(detailPosition * 1.3, 3) - 0.5) * 0.03;
  #elif defined(TISSUE_SPONGY)
    height += smoothstep(0.0, 0.2, cellWallDistance(detailPosition * 13.0)) * 0.0014;
    height += (fractalNoise(detailPosition * 1.4 + 3.0, 3) - 0.5) * 0.04;
    height += vesselAmount(detailPosition * 1.3) * 0.0024;
  #elif defined(TISSUE_FOLDED)
    float warp = fractalNoise(detailPosition * 1.6, 3) * 7.0;
    height += sin(detailPosition.y * 15.0 + detailPosition.x * 4.0 + warp) * 0.007;
    height += (fractalNoise(detailPosition * 1.3, 3) - 0.5) * 0.03;
  #elif defined(TISSUE_WALL)
    float bandWarp = fractalNoise(detailPosition * vec3(0.8, 1.6, 1.6), 2) * 2.4;
    height += sin(detailPosition.x * 5.0 + bandWarp) * 0.02;
    height += (fractalNoise(detailPosition * vec3(5.0, 14.0, 14.0), 2) - 0.5) * 0.008;
  #elif defined(TISSUE_SMOOTH)
    height += (fractalNoise(detailPosition * 1.2, 3) - 0.5) * 0.024;
  #elif defined(TISSUE_BONE)
    height += (valueNoise(detailPosition * 24.0) - 0.5) * 0.0015;
  #endif
  return height;
}

// Mikkelsen's unnormalized derivative bump, so height is in scene units and a
// groove keeps the same depth at every camera distance.
vec3 bumpedNormal(vec3 surfacePosition, vec3 surfaceNormal, float heightStepX, float heightStepY, float facing) {
  vec3 positionStepX = dFdx(surfacePosition);
  vec3 positionStepY = dFdy(surfacePosition);
  vec3 sideA = cross(positionStepY, surfaceNormal);
  vec3 sideB = cross(surfaceNormal, positionStepX);
  float determinant = dot(positionStepX, sideA) * facing;
  vec3 gradient = sign(determinant) * (heightStepX * sideA + heightStepY * sideB);
  return normalize(abs(determinant) * surfaceNormal - gradient);
}

#if defined(SURFACE_SKIN)
vec3 skinColor() {
  vec3 detailPosition = vObjectPosition * detailScale;
  float alongBody = vSurfaceCoordinate.x;
  float bellyAmount = vSurfaceCoordinate.y;
  float broadVariation = fractalNoise(detailPosition * vec3(0.5, 1.5, 1.5) + 4.0, 3);
  float countershadeLine = 0.62 + (broadVariation - 0.5) * 0.2;
  float bellyMix = smoothstep(countershadeLine - 0.06, countershadeLine + 0.08, bellyAmount);
  bellyMix *= mix(1.0, 0.42, smoothstep(0.26, 0.5, alongBody));
  vec3 color = mix(topColor, bellyColor, bellyMix);
  color *= 0.9 + broadVariation * 0.2;

  // Dappling: fine pale spots stretched along the body, denser in loose patches.
  vec3 warpedPosition = detailPosition + (fractalNoise(detailPosition * 3.1, 2) - 0.5) * 0.2;
  float patchDensity = smoothstep(0.34, 0.66, fractalNoise(detailPosition * vec3(0.5, 1.5, 1.5) + 9.0, 3));
  float spots = smoothstep(0.54, 0.76, fractalNoise(warpedPosition * vec3(7.0, 19.0, 19.0), 2));
  float fineSpots = smoothstep(0.56, 0.78, fractalNoise(warpedPosition * vec3(17.0, 40.0, 40.0) + 21.0, 2));
  float paleAmount = max(spots, fineSpots * 0.7) * (0.3 + 0.7 * patchDensity);
  float darkAmount = smoothstep(0.54, 0.74, fractalNoise(warpedPosition * vec3(4.4, 12.0, 12.0) + 40.0, 2));
  color *= 1.0 - darkAmount * mottling * 0.36;
  vec3 paleSkin = mix(color, vec3(0.42, 0.47, 0.52), 0.55);
  color = mix(color, paleSkin, paleAmount * mottling * (1.0 - bellyMix * 0.6));

  if (hasGrooves > 0.5) {
    float grooveShade = grooveHeight(alongBody, vSurfaceCoordinate.z, length(fwidth(vSurfaceCoordinate.xz)));
    color *= 1.0 + grooveShade * 0.62;
  }
  return color;
}
#endif

#if defined(TISSUE_LIQUID)
float softBand(float value, float bandStart, float bandEnd, float softness) {
  return smoothstep(bandStart - softness, bandStart + softness, value)
    * (1.0 - smoothstep(bandEnd - softness, bandEnd + softness, value));
}

// The overlay cannot refract the page behind it, so water is painted from the
// surface's angle to the camera, the way a matcap is. Alpha is per pixel, so the
// page shows through the middle of the drop and the rim stays dense.
vec4 liquidSurface(vec3 waterColor, vec3 viewNormal, float facing, float alongShell) {
  float edge = 1.0 - facing;
  vec3 deepColor = waterColor * vec3(0.3, 0.2, 0.46);
  vec3 midColor = mix(waterColor, vec3(0.08, 0.5, 0.95), 0.55);
  vec3 shallowColor = mix(waterColor, vec3(0.55, 0.92, 1.0), 0.8);

  // A drop is a lens, so it shows the sky upside down, bright at the bottom.
  float lensLight = smoothstep(0.55, -0.8, viewNormal.y);
  vec3 color = mix(midColor, shallowColor, lensLight);
  color = mix(color, deepColor, smoothstep(0.36, 0.84, edge));
  float alpha = mix(0.6, 0.98, smoothstep(0.05, 0.55, edge));

  vec2 surfaceDirection = normalize(viewNormal.xy + vec2(1e-5));
  float rimDistance = length(viewNormal.xy);

  // Light focuses into a bright crescent on the side of a drop away from the sun.
  float causticSweep = smoothstep(0.2, 0.95, dot(surfaceDirection, normalize(vec2(0.42, -0.9))));
  float caustic = softBand(rimDistance, 0.68, 0.84, 0.05) * causticSweep;
  color = mix(color, vec3(0.8, 0.97, 1.0), caustic * 0.9);
  alpha = max(alpha, caustic * 0.92);

  // The sky's reflection, an arc that follows the shoulder of the drop.
  float windowSweep = smoothstep(0.93, 0.99, dot(surfaceDirection, normalize(vec2(-0.9, 0.44))));
  float windowArc = softBand(rimDistance, 0.6, 0.74, 0.012) * windowSweep;
  float windowSpot = 1.0 - smoothstep(0.024, 0.036, distance(viewNormal.xy, vec2(-0.48, 0.3)));
  // The tapering tip repeats these normals, which would print a second highlight.
  float highlight = max(windowArc, windowSpot) * (1.0 - smoothstep(0.42, 0.5, alongShell));
  color = mix(color, vec3(1.0), highlight);
  alpha = max(alpha, highlight);

  return vec4(color, alpha);
}
#endif

#if defined(SURFACE_TISSUE)
vec3 tissueColor(vec3 baseColor) {
  vec3 detailPosition = vObjectPosition * detailScale;
  vec3 color = baseColor;
  #if defined(TISSUE_MUSCLE)
    float fatPatch = smoothstep(0.46, 0.78, fractalNoise(detailPosition * vec3(0.9, 1.4, 1.0) + 13.0, 3));
    float fibers = valueNoise(detailPosition * vec3(5.0, 30.0, 30.0));
    color *= 0.78 + fractalNoise(detailPosition * 1.6, 3) * 0.3 + fibers * 0.12;
    color = mix(color, vec3(0.74, 0.55, 0.32), fatPatch * 0.34);
    color = mix(color, veinColor, vesselAmount(detailPosition) * 0.72);
  #elif defined(TISSUE_SPONGY)
    float lobuleWall = smoothstep(0.07, 0.0, cellWallDistance(detailPosition * 13.0));
    float speckle = smoothstep(0.56, 0.8, valueNoise(detailPosition * 34.0));
    float blush = fractalNoise(detailPosition * 1.1 + 5.0, 4);
    color *= 0.56 + blush * 0.86;
    color = mix(color, veinColor, lobuleWall * 0.15);
    color = mix(color, veinColor * 0.7, speckle * 0.16);
    color = mix(color, veinColor, vesselAmount(detailPosition * 1.3) * 0.28);
  #elif defined(TISSUE_FOLDED)
    float warp = fractalNoise(detailPosition * 1.6, 3) * 7.0;
    float fold = sin(detailPosition.y * 15.0 + detailPosition.x * 4.0 + warp);
    color *= 0.74 + (fold * 0.5 + 0.5) * 0.38;
    color = mix(color, veinColor, smoothstep(0.1, 0.9, 0.5 - fold * 0.5) * 0.3);
  #elif defined(TISSUE_WALL)
    float bandWarp = fractalNoise(detailPosition * vec3(0.8, 1.6, 1.6), 2) * 2.4;
    float band = sin(detailPosition.x * 5.0 + bandWarp) * 0.5 + 0.5;
    color *= 0.46 + band * 0.42 + fractalNoise(detailPosition * vec3(5.0, 14.0, 14.0), 2) * 0.3;
  #elif defined(TISSUE_SMOOTH)
    color *= 0.74 + fractalNoise(detailPosition * 1.4, 4) * 0.5;
  #elif defined(TISSUE_BONE)
    color *= 0.82 + fractalNoise(detailPosition * vec3(3.0, 9.0, 9.0), 3) * 0.3;
  #endif
  return color;
}
#endif
`;

const applyFragmentNormal = /* glsl */ `
#include <normal_fragment_maps>
{
  vec3 positionStepX = dFdx(vObjectPosition);
  vec3 positionStepY = dFdy(vObjectPosition);
  vec2 coordinateStepX = dFdx(vSurfaceCoordinate.xz);
  vec2 coordinateStepY = dFdy(vSurfaceCoordinate.xz);
  float pixelFootprint = length(fwidth(vSurfaceCoordinate.xz));
  float centerHeight = surfaceHeight(vObjectPosition, vSurfaceCoordinate.x, vSurfaceCoordinate.z, pixelFootprint);
  float heightX = surfaceHeight(
    vObjectPosition + positionStepX,
    vSurfaceCoordinate.x + coordinateStepX.x,
    vSurfaceCoordinate.z + coordinateStepX.y,
    pixelFootprint
  );
  float heightY = surfaceHeight(
    vObjectPosition + positionStepY,
    vSurfaceCoordinate.x + coordinateStepY.x,
    vSurfaceCoordinate.z + coordinateStepY.y,
    pixelFootprint
  );
  normal = bumpedNormal(
    -vViewPosition,
    normal,
    (heightX - centerHeight) / detailScale,
    (heightY - centerHeight) / detailScale,
    faceDirection
  );
}
`;

const applyFragmentColor = /* glsl */ `
#include <color_fragment>
#if defined(SURFACE_SKIN)
  diffuseColor.rgb = skinColor();
#elif defined(SURFACE_TISSUE)
  diffuseColor.rgb = tissueColor(diffuseColor.rgb);
#endif
#if !defined(SURFACE_INTERIOR)
  diffuseColor.rgb *= 1.0 - vSurfaceCoordinate.w * 0.82;
#endif
`;

const applyFragmentRoughness = /* glsl */ `
#include <roughnessmap_fragment>
#if defined(SURFACE_SKIN)
  roughnessFactor = clamp(roughnessFactor + (fractalNoise(vObjectPosition * detailScale * vec3(1.2, 3.4, 3.4), 3) - 0.5) * 0.3, 0.2, 0.9);
  roughnessFactor = mix(roughnessFactor, 1.0, vSurfaceCoordinate.w);
#endif
`;

const applyFragmentOpacity = /* glsl */ `
#if defined(SURFACE_INTERIOR)
  // The wall turns solid before the skin thins, so the page never shows through the body.
  diffuseColor.a = smoothstep(0.0, 0.3, shellFade);
#elif defined(TISSUE_LIQUID) && defined(FLIP_SIDED)
  // The far wall of the drop is the water around the camera once it is inside.
  outgoingLight = diffuse * mix(vec3(0.3, 0.42, 0.6), vec3(0.6, 0.8, 0.95), smoothstep(0.4, -0.4, nonPerturbedNormal.y));
  diffuseColor.a = 0.94 * smoothstep(0.0, 0.5, shellFade);
#elif defined(TISSUE_LIQUID)
  vec4 liquidColor = liquidSurface(
    diffuse,
    nonPerturbedNormal,
    clamp(dot(normalize(vViewPosition), nonPerturbedNormal), 0.0, 1.0),
    vSurfaceCoordinate.x
  );
  outgoingLight = liquidColor.rgb;
  diffuseColor.a = liquidColor.a;
#elif defined(SURFACE_TISSUE)
  // A wet organ glows at its rim, because light scatters through the edge of soft tissue.
  float rimAmount = pow(1.0 - abs(dot(normalize(vViewPosition), nonPerturbedNormal)), 3.0);
  outgoingLight += diffuseColor.rgb * rimAmount * 0.32;
#endif
#if !defined(SURFACE_INTERIOR) && !(defined(TISSUE_LIQUID) && defined(FLIP_SIDED))
  float edgeAmount = pow(1.0 - abs(dot(normalize(vViewPosition), nonPerturbedNormal)), 3.0);
  diffuseColor.a *= mix(1.0, mix(fadedOpacity, 1.0, edgeAmount * fadedRim), shellFade);
#endif
#include <opaque_fragment>
`;

// The same physical material as everywhere else, with three.js's lighting left
// in charge. Only its color, roughness, normal, and opacity inputs are replaced.
// Liquid is the exception: it paints its final color and ignores the lights.
function installSurfaceShader(
  material: MeshPhysicalMaterial,
  uniforms: Record<string, { value: unknown }>,
  defineNames: string[],
): void {
  const defineLines = defineNames.map((defineName) => `#define ${defineName}`).join("\n");
  // Each surface kind compiles differently, so each needs its own cached program.
  material.customProgramCacheKey = () => defineLines;
  material.onBeforeCompile = (shader) => {
    Object.assign(shader.uniforms, uniforms);
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", `#include <common>\n${surfaceVertexDeclarations}`)
      .replace("#include <begin_vertex>", `#include <begin_vertex>\n${surfaceVertexAssignment}`);
    shader.fragmentShader = `${defineLines}\n${shader.fragmentShader}`
      .replace("#include <common>", `#include <common>\n${surfaceFragmentFunctions}`)
      .replace("#include <color_fragment>", applyFragmentColor)
      .replace("#include <roughnessmap_fragment>", applyFragmentRoughness)
      .replace("#include <normal_fragment_maps>", applyFragmentNormal)
      .replace("#include <opaque_fragment>", applyFragmentOpacity);
  };
}

function sharedUniforms(
  detailScale: number,
  fade: SurfaceFadeUniforms,
  skin: Skin | undefined,
  veinColor: string | undefined,
): Record<string, { value: unknown }> {
  return {
    detailScale: { value: detailScale },
    shellFade: fade.shellFade,
    fadedOpacity: fade.fadedOpacity,
    fadedRim: fade.fadedRim,
    topColor: { value: new Color(skin?.topColor ?? "#000000") },
    bellyColor: { value: new Color(skin?.bellyColor ?? "#000000") },
    veinColor: { value: new Color(veinColor ?? "#000000") },
    mottling: { value: skin?.mottling ?? 0 },
    hasGrooves: { value: skin?.grooves === true ? 1 : 0 },
  };
}

type SurfaceMaterialInput = {
  color: string;
  skin: Skin | undefined;
  tissue: Tissue | undefined;
  detailScale: number;
  // True for every part that fades with a shell. Inner parts stay opaque.
  fadesWithShell: boolean;
  side?: Side;
  fade: SurfaceFadeUniforms;
};

export function createSurfaceMaterial(input: SurfaceMaterialInput): MeshPhysicalMaterial {
  const { color, skin, tissue, detailScale, fadesWithShell, side, fade } = input;
  const isLiquid = tissue?.pattern === "liquid";
  const material = new MeshPhysicalMaterial({
    color,
    transparent: fadesWithShell,
    // three.js draws a transparent double-sided surface back faces first, so the
    // far wall of a drop can stay in view once the camera is inside it.
    side: side ?? (isLiquid ? DoubleSide : FrontSide),
    // Tone mapping would turn painted white highlights grey.
    toneMapped: !isLiquid,
    roughness: skin !== undefined ? 0.5 : tissue?.pattern === "bone" ? 0.62 : 0.4,
    metalness: 0,
    clearcoat: skin !== undefined ? 0.8 : tissue?.pattern === "bone" ? 0.05 : 0.7,
    clearcoatRoughness: skin !== undefined ? 0.3 : 0.3,
    ior: 1.38,
  });
  const defineNames: string[] = [];
  if (skin !== undefined) {
    defineNames.push("SURFACE_SKIN");
  } else if (tissue !== undefined) {
    defineNames.push("SURFACE_TISSUE", tissuePatternDefine[tissue.pattern]);
  }
  installSurfaceShader(
    material,
    sharedUniforms(detailScale, fade, skin, tissue?.veinColor),
    defineNames,
  );
  return material;
}

// The flesh wall seen through a faded shell. It uses the shell's own geometry
// with back faces, so it only exists where the body does and the canvas stays
// transparent everywhere else.
export function createInteriorMaterial(
  interiorColor: string,
  detailScale: number,
  fade: SurfaceFadeUniforms,
): MeshPhysicalMaterial {
  const material = new MeshPhysicalMaterial({
    color: interiorColor,
    transparent: true,
    depthWrite: false,
    side: BackSide,
    roughness: 0.66,
    clearcoat: 0.12,
    clearcoatRoughness: 0.5,
  });
  installSurfaceShader(material, sharedUniforms(detailScale, fade, undefined, undefined), [
    "SURFACE_TISSUE",
    "SURFACE_INTERIOR",
    tissuePatternDefine.wall,
  ]);
  return material;
}
