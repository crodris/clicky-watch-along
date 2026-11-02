import {
  AmbientLight,
  BufferGeometry,
  BoxGeometry,
  CapsuleGeometry,
  CylinderGeometry,
  DirectionalLight,
  DoubleSide,
  FrontSide,
  LinearSRGBColorSpace,
  Mesh,
  MeshLambertMaterial,
  NearestFilter,
  NoToneMapping,
  OrthographicCamera,
  PerspectiveCamera,
  PlaneGeometry,
  Scene,
  ShaderMaterial,
  SphereGeometry,
  TorusGeometry,
  Vector2,
  Vector3,
  WebGLRenderTarget,
  WebGLRenderer,
} from "three";
import { paletteSize, paletteVectors, virtualPixelCssSize } from "./palette";
import {
  sceneSpecSchema,
  type CameraStop,
  type Part,
  type SceneSpec,
} from "./spec";

const cameraStopHoldMilliseconds = 1000;
const cameraMoveDurationMilliseconds = 1800;
const cameraFieldOfViewDegrees = 40;
const cameraNearPlane = 0.08;
const cameraFarPlane = 200;

type PageElements = {
  canvas: HTMLCanvasElement;
  labelLayer: HTMLDivElement;
  leaderLayer: SVGSVGElement;
};

type ScenePart = {
  id: string;
  labelText: string;
  mesh: Mesh;
  geometry: BufferGeometry;
  material: MeshLambertMaterial;
  labelElement: HTMLDivElement;
  leaderLine: SVGLineElement;
};

type DitherPass = {
  target: WebGLRenderTarget;
  scene: Scene;
  camera: OrthographicCamera;
  lowResolutionSize: Vector2;
};

const scene = new Scene();
const camera = new PerspectiveCamera(
  cameraFieldOfViewDegrees,
  1,
  cameraNearPlane,
  cameraFarPlane,
);
const projectedAnchor = new Vector3();
const cameraSpaceAnchor = new Vector3();

let page: PageElements | null = null;
let renderer: WebGLRenderer | null = null;
let ditherPass: DitherPass | null = null;
let resizeObserver: ResizeObserver | null = null;
let lightsInstalled = false;
let sceneParts: ScenePart[] = [];
let quizPartId: string | null = null;
let quizLabelShowsQuestionMark = false;
let activeTourId = 0;
let cameraMoveFrameId: number | null = null;
const scheduledTimeoutIds: number[] = [];

const postVertexShader = `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}
`;

// Ordered dither copied from the birthday post pass. The alpha test is
// screen-door instead of a 0.4 cutoff, so a translucent shell stays visible
// as stippled coverage. Blending stores coverage-weighted rgb, so divide by
// alpha before quantizing or that shell becomes a dark smear.
const postFragmentShader = `
precision highp float;
varying vec2 vUv;
uniform sampler2D tScene;
uniform vec2 uLow;
uniform vec3 uPalette[${paletteSize}];
float bayer2(vec2 coordinate) {
  coordinate = floor(coordinate);
  return fract(coordinate.x / 2.0 + coordinate.y * coordinate.y * 0.75);
}
void main() {
  vec2 lowPixel = floor(vUv * uLow);
  vec4 sampleColor = texture2D(tScene, (lowPixel + 0.5) / uLow);
  float bayerThreshold = bayer2(lowPixel);
  if (sampleColor.a <= bayerThreshold) {
    gl_FragColor = vec4(0.0);
    return;
  }
  vec3 linearColor = sampleColor.rgb / sampleColor.a;
  vec3 gammaColor = pow(max(linearColor, 0.0), vec3(1.0 / 2.2));
  float dither = bayer2(0.5 * lowPixel) * 0.25 + bayer2(lowPixel);
  gammaColor += (dither - 0.5) * 0.12 * smoothstep(0.1, 0.3, dot(gammaColor, vec3(0.333)));
  vec3 nearest = uPalette[0];
  float nearestDistance = 1e9;
  for (int paletteIndex = 0; paletteIndex < ${paletteSize}; paletteIndex++) {
    vec3 paletteColor = uPalette[paletteIndex];
    float colorDistance = dot(gammaColor - paletteColor, gammaColor - paletteColor);
    if (colorDistance < nearestDistance) {
      nearestDistance = colorDistance;
      nearest = paletteColor;
    }
  }
  gl_FragColor = vec4(nearest, 1.0);
}
`;

function requiredCanvas(): HTMLCanvasElement {
  const element = document.getElementById("field-trip-canvas");
  if (!(element instanceof HTMLCanvasElement)) {
    throw new Error("Field trip page is missing #field-trip-canvas");
  }
  return element;
}

function requiredDiv(elementId: string): HTMLDivElement {
  const element = document.getElementById(elementId);
  if (!(element instanceof HTMLDivElement)) {
    throw new Error(`Field trip page is missing #${elementId}`);
  }
  return element;
}

function requiredSvg(elementId: string): SVGSVGElement {
  const element = document.getElementById(elementId);
  if (!(element instanceof SVGSVGElement)) {
    throw new Error(`Field trip page is missing #${elementId}`);
  }
  return element;
}

function pageElements(): PageElements {
  if (page !== null) {
    return page;
  }
  page = {
    canvas: requiredCanvas(),
    labelLayer: requiredDiv("field-trip-labels"),
    leaderLayer: requiredSvg("field-trip-leaders"),
  };
  return page;
}

function createPartGeometry(part: Part): BufferGeometry {
  const [width, height, depth] = part.size;
  switch (part.shape) {
    case "box":
      return new BoxGeometry(width, height, depth);
    case "sphere": {
      // Diameter-sized sphere, then scaled into an ellipsoid.
      const sphere = new SphereGeometry(0.5, 32, 24);
      sphere.scale(width, height, depth);
      return sphere;
    }
    case "cylinder": {
      // Unit cylinder points along Y. size.y is the length before rotation.
      const cylinder = new CylinderGeometry(0.5, 0.5, 1, 24);
      cylinder.scale(width, height, depth);
      return cylinder;
    }
    case "capsule": {
      // CapsuleGeometry(0.5, 1) is 2 units along Y. size.y is that length.
      const capsule = new CapsuleGeometry(0.5, 1, 8, 16);
      capsule.scale(width, height, depth);
      return capsule;
    }
    case "torus": {
      const torus = new TorusGeometry(0.32, 0.18, 16, 28);
      torus.scale(width, height, depth);
      return torus;
    }
    default: {
      const unexpectedShape: never = part.shape;
      throw new Error(`Unknown part shape: ${unexpectedShape}`);
    }
  }
}

function createDitherPass(): DitherPass {
  const lowResolutionSize = new Vector2(2, 2);
  const target = new WebGLRenderTarget(2, 2, {
    minFilter: NearestFilter,
    magFilter: NearestFilter,
    depthBuffer: true,
    generateMipmaps: false,
  });
  // The post pass reads linear samples and writes sRGB palette colors itself.
  target.texture.colorSpace = LinearSRGBColorSpace;
  const material = new ShaderMaterial({
    vertexShader: postVertexShader,
    fragmentShader: postFragmentShader,
    uniforms: {
      tScene: { value: target.texture },
      uLow: { value: lowResolutionSize },
      uPalette: { value: paletteVectors },
    },
    depthTest: false,
    depthWrite: false,
    transparent: true,
  });
  const postScene = new Scene();
  postScene.add(new Mesh(new PlaneGeometry(2, 2), material));
  const postCamera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
  return { target, scene: postScene, camera: postCamera, lowResolutionSize };
}

function ensureRenderer(): void {
  const elements = pageElements();
  if (renderer !== null) {
    return;
  }
  const glRenderer = new WebGLRenderer({
    canvas: elements.canvas,
    alpha: true,
    antialias: false,
    premultipliedAlpha: true,
  });
  // Virtual pixels are counted in CSS pixels, matching the dither pipeline's dpr 1.
  glRenderer.setPixelRatio(1);
  glRenderer.setClearColor(0x000000, 0);
  // The post shader already writes palette sRGB. A second encoding would crush it.
  glRenderer.outputColorSpace = LinearSRGBColorSpace;
  glRenderer.toneMapping = NoToneMapping;
  glRenderer.autoClear = true;
  renderer = glRenderer;
  ditherPass = createDitherPass();
  resizeObserver = new ResizeObserver(() => {
    // The camera move already renders every frame. A second render here would
    // only matter while the picture is sitting still.
    if (cameraMoveFrameId !== null) {
      return;
    }
    renderSceneOnce();
  });
  resizeObserver.observe(elements.canvas);
}

function ensureLights(): void {
  if (lightsInstalled) {
    return;
  }
  scene.add(new AmbientLight(0xffffff, 0.46));
  const keyLight = new DirectionalLight(0xffffff, 0.72);
  keyLight.position.set(6, 8, 10);
  scene.add(keyLight);
  const fillLight = new DirectionalLight(0xffffff, 0.22);
  fillLight.position.set(-8, -3, -6);
  scene.add(fillLight);
  lightsInstalled = true;
}

function syncViewSize(cssWidth: number, cssHeight: number): void {
  if (renderer === null || ditherPass === null) {
    return;
  }
  const lowWidth = Math.max(2, Math.floor(cssWidth / virtualPixelCssSize));
  const lowHeight = Math.max(2, Math.floor(cssHeight / virtualPixelCssSize));
  renderer.setSize(cssWidth, cssHeight, false);
  camera.aspect = cssWidth / cssHeight;
  camera.updateProjectionMatrix();
  if (
    ditherPass.target.width !== lowWidth ||
    ditherPass.target.height !== lowHeight
  ) {
    ditherPass.target.setSize(lowWidth, lowHeight);
    ditherPass.lowResolutionSize.set(lowWidth, lowHeight);
  }
}

function renderSceneOnce(): void {
  if (renderer === null || ditherPass === null) {
    return;
  }
  const elements = pageElements();
  const cssWidth = elements.canvas.clientWidth;
  const cssHeight = elements.canvas.clientHeight;
  if (cssWidth < 2 || cssHeight < 2) {
    return;
  }
  syncViewSize(cssWidth, cssHeight);
  renderer.setRenderTarget(ditherPass.target);
  renderer.render(scene, camera);
  renderer.setRenderTarget(null);
  renderer.render(ditherPass.scene, ditherPass.camera);
  updatePartLabelPositions();
}

function cancelCameraTour(): void {
  activeTourId += 1;
  if (cameraMoveFrameId !== null) {
    window.cancelAnimationFrame(cameraMoveFrameId);
    cameraMoveFrameId = null;
  }
  for (const timeoutId of scheduledTimeoutIds) {
    window.clearTimeout(timeoutId);
  }
  scheduledTimeoutIds.length = 0;
}

function disposeParts(): void {
  for (const scenePart of sceneParts) {
    scene.remove(scenePart.mesh);
    scenePart.geometry.dispose();
    scenePart.material.dispose();
    scenePart.labelElement.remove();
    scenePart.leaderLine.remove();
  }
  sceneParts = [];
}

function labelTextForPart(scenePart: ScenePart): string {
  if (quizLabelShowsQuestionMark && scenePart.id === quizPartId) {
    return "?";
  }
  return scenePart.labelText;
}

function setQuizLabelShowsQuestionMark(showsQuestionMark: boolean): void {
  quizLabelShowsQuestionMark = showsQuestionMark;
  updatePartLabelPositions();
}

function clampNumber(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

function labelOffsetPixels(
  partIndex: number,
  partCount: number,
): { x: number; y: number } {
  const spread = partCount <= 1 ? 0 : (partIndex / (partCount - 1)) * 2 - 1;
  return {
    x: spread * 96,
    y: -58 - Math.abs(spread) * 28,
  };
}

function leaderEndAtLabelEdge(
  anchorX: number,
  anchorY: number,
  labelCenterX: number,
  labelCenterY: number,
  labelWidth: number,
  labelHeight: number,
): { x: number; y: number } {
  const deltaX = labelCenterX - anchorX;
  const deltaY = labelCenterY - anchorY;
  const halfWidth = labelWidth / 2;
  const halfHeight = labelHeight / 2;
  if (deltaX === 0 && deltaY === 0) {
    return { x: labelCenterX, y: labelCenterY };
  }
  const scaleToVerticalEdge =
    deltaX === 0 ? Number.POSITIVE_INFINITY : halfWidth / Math.abs(deltaX);
  const scaleToHorizontalEdge =
    deltaY === 0 ? Number.POSITIVE_INFINITY : halfHeight / Math.abs(deltaY);
  const scale = Math.min(scaleToVerticalEdge, scaleToHorizontalEdge);
  return {
    x: labelCenterX - deltaX * scale,
    y: labelCenterY - deltaY * scale,
  };
}

function updatePartLabelPositions(): void {
  const elements = pageElements();
  const cssWidth = elements.canvas.clientWidth;
  const cssHeight = elements.canvas.clientHeight;
  if (cssWidth < 2 || cssHeight < 2) {
    return;
  }
  camera.updateMatrixWorld(true);
  sceneParts.forEach((scenePart, partIndex) => {
    scenePart.labelElement.textContent = labelTextForPart(scenePart);
    cameraSpaceAnchor.copy(scenePart.mesh.position);
    cameraSpaceAnchor.applyMatrix4(camera.matrixWorldInverse);
    // Three.js cameras look down negative Z. A positive Z is behind the lens.
    const anchorIsInFrontOfCamera = cameraSpaceAnchor.z < 0;
    scenePart.labelElement.style.display = anchorIsInFrontOfCamera ? "block" : "none";
    scenePart.leaderLine.style.display = anchorIsInFrontOfCamera ? "block" : "none";
    if (!anchorIsInFrontOfCamera) {
      return;
    }

    projectedAnchor.copy(scenePart.mesh.position).project(camera);
    const anchorX = (projectedAnchor.x * 0.5 + 0.5) * cssWidth;
    const anchorY = (-projectedAnchor.y * 0.5 + 0.5) * cssHeight;
    const offset = labelOffsetPixels(partIndex, sceneParts.length);
    const labelCenterX = clampNumber(anchorX + offset.x, 16, cssWidth - 16);
    const labelCenterY = clampNumber(anchorY + offset.y, 16, cssHeight - 16);
    scenePart.labelElement.style.left = `${labelCenterX}px`;
    scenePart.labelElement.style.top = `${labelCenterY}px`;

    const leaderEnd = leaderEndAtLabelEdge(
      anchorX,
      anchorY,
      labelCenterX,
      labelCenterY,
      scenePart.labelElement.offsetWidth,
      scenePart.labelElement.offsetHeight,
    );
    scenePart.leaderLine.setAttribute("x1", anchorX.toFixed(2));
    scenePart.leaderLine.setAttribute("y1", anchorY.toFixed(2));
    scenePart.leaderLine.setAttribute("x2", leaderEnd.x.toFixed(2));
    scenePart.leaderLine.setAttribute("y2", leaderEnd.y.toFixed(2));
  });
}

function buildParts(parts: Part[]): void {
  const elements = pageElements();
  for (const part of parts) {
    const geometry = createPartGeometry(part);
    const material = new MeshLambertMaterial({
      color: part.color,
      transparent: part.opacity < 1,
      opacity: part.opacity,
      depthWrite: part.opacity >= 1,
      side: part.opacity < 1 ? DoubleSide : FrontSide,
      premultipliedAlpha: false,
    });
    const mesh = new Mesh(geometry, material);
    mesh.position.set(part.position[0], part.position[1], part.position[2]);
    const rotation = part.rotation ?? [0, 0, 0];
    mesh.rotation.set(rotation[0], rotation[1], rotation[2]);
    // Draw the shell after the solid organs so the glass blends over them.
    if (part.opacity < 1) {
      mesh.renderOrder = 2;
    }
    scene.add(mesh);

    const labelElement = document.createElement("div");
    labelElement.className = "field-trip-label";
    labelElement.dataset.partId = part.id;
    labelElement.textContent = part.label;
    elements.labelLayer.appendChild(labelElement);

    const leaderLine = document.createElementNS("http://www.w3.org/2000/svg", "line");
    leaderLine.setAttribute("class", "field-trip-leader");
    elements.leaderLayer.appendChild(leaderLine);

    sceneParts.push({
      id: part.id,
      labelText: part.label,
      mesh,
      geometry,
      material,
      labelElement,
      leaderLine,
    });
  }
}

function placeCameraAtStop(stop: CameraStop): void {
  camera.position.set(stop.position[0], stop.position[1], stop.position[2]);
  camera.lookAt(stop.lookAt[0], stop.lookAt[1], stop.lookAt[2]);
}

function placeCameraBetweenStops(
  fromStop: CameraStop,
  toStop: CameraStop,
  progress: number,
): void {
  camera.position.set(
    fromStop.position[0] + (toStop.position[0] - fromStop.position[0]) * progress,
    fromStop.position[1] + (toStop.position[1] - fromStop.position[1]) * progress,
    fromStop.position[2] + (toStop.position[2] - fromStop.position[2]) * progress,
  );
  camera.lookAt(
    fromStop.lookAt[0] + (toStop.lookAt[0] - fromStop.lookAt[0]) * progress,
    fromStop.lookAt[1] + (toStop.lookAt[1] - fromStop.lookAt[1]) * progress,
    fromStop.lookAt[2] + (toStop.lookAt[2] - fromStop.lookAt[2]) * progress,
  );
}

function easeInOutCubic(progress: number): number {
  if (progress < 0.5) {
    return 4 * progress * progress * progress;
  }
  return 1 - (-2 * progress + 2) ** 3 / 2;
}

function scheduleAfterHold(tourId: number, continueTour: () => void): void {
  const timeoutId = window.setTimeout(() => {
    if (tourId !== activeTourId) {
      return;
    }
    continueTour();
  }, cameraStopHoldMilliseconds);
  scheduledTimeoutIds.push(timeoutId);
}

function moveCamera(
  tourId: number,
  fromStop: CameraStop,
  toStop: CameraStop,
  onArrived: () => void,
): void {
  const moveStartedAtMilliseconds = performance.now();
  const step = (nowMilliseconds: number) => {
    if (tourId !== activeTourId) {
      return;
    }
    const progress = Math.min(
      1,
      (nowMilliseconds - moveStartedAtMilliseconds) / cameraMoveDurationMilliseconds,
    );
    placeCameraBetweenStops(fromStop, toStop, easeInOutCubic(progress));
    renderSceneOnce();
    if (progress < 1) {
      cameraMoveFrameId = window.requestAnimationFrame(step);
      return;
    }
    cameraMoveFrameId = null;
    onArrived();
  };
  cameraMoveFrameId = window.requestAnimationFrame(step);
}

// Stop 1 holds for a second. The pause on stop 2 uses that same hold, then
// each move eases for 1.8s. requestAnimationFrame runs only during a move.
function startCameraTour(sceneSpec: SceneSpec): void {
  const tourId = activeTourId;
  const [firstStop, secondStop, thirdStop] = sceneSpec.cameraStops;
  placeCameraAtStop(firstStop);
  renderSceneOnce();
  scheduleAfterHold(tourId, () => {
    moveCamera(tourId, firstStop, secondStop, () => {
      scheduleAfterHold(tourId, () => {
        moveCamera(tourId, secondStop, thirdStop, () => {
          if (tourId !== activeTourId) {
            return;
          }
          setQuizLabelShowsQuestionMark(true);
        });
      });
    });
  });
}

function playScene(spec: unknown): void {
  const sceneSpec = sceneSpecSchema.parse(spec);
  cancelCameraTour();
  disposeParts();
  quizPartId = sceneSpec.quiz.partId;
  quizLabelShowsQuestionMark = false;
  document.title = sceneSpec.title;
  ensureRenderer();
  ensureLights();
  buildParts(sceneSpec.parts);
  startCameraTour(sceneSpec);
}

function revealQuizLabel(): void {
  setQuizLabelShowsQuestionMark(false);
}

function clearScene(): void {
  cancelCameraTour();
  disposeParts();
  quizPartId = null;
  quizLabelShowsQuestionMark = false;
  document.title = "Field trip";
  renderSceneOnce();
}

declare global {
  interface Window {
    fieldTrip: {
      play(spec: unknown): void;
      reveal(): void;
      clear(): void;
    };
  }
}

window.fieldTrip = {
  play(spec: unknown) {
    playScene(spec);
  },
  reveal() {
    revealQuizLabel();
  },
  clear() {
    clearScene();
  },
};
