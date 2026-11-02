import {
  ACESFilmicToneMapping,
  BackSide,
  Box3,
  BoxGeometry,
  BufferGeometry,
  CapsuleGeometry,
  CylinderGeometry,
  DirectionalLight,
  Euler,
  Group,
  HemisphereLight,
  Mesh,
  MeshPhysicalMaterial,
  PCFSoftShadowMap,
  PerspectiveCamera,
  PMREMGenerator,
  Scene,
  SphereGeometry,
  TorusGeometry,
  Vector3,
  WebGLRenderer,
} from "three";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import {
  applyWorldSpaceBellyAmount,
  createFinGeometry,
  createLoftGeometry,
  createTubeGeometry,
} from "./geometry";
import {
  sceneSpecSchema,
  type CameraStop,
  type Part,
  type SceneSpec,
} from "./spec";
import {
  createInteriorMaterial,
  createSurfaceMaterial,
  type SurfaceFadeUniforms,
} from "./surface";

const cameraStopHoldMilliseconds = 1000;
const cameraMoveDurationMilliseconds = 1800;
const cameraFieldOfViewDegrees = 34;
const cameraNearPlane = 0.08;
const cameraFarPlane = 200;
const maximumPixelRatio = 2;
const shadowMapSize = 4096;
// The skin holds until the camera is well into the last move, so the viewer
// sees the whale before they see through it.
const shellFadeStartProgress = 0.3;
const shellFadeEndProgress = 0.92;
const interiorWallResolution = 0.4;
const labelSwapFade = 0.6;
const labelDistancePixels = 74;
const labelLiftPixels = 18;
const labelGapPixels = 6;
const labelEdgeMarginPixels = 12;

type PageElements = {
  canvas: HTMLCanvasElement;
  labelLayer: HTMLDivElement;
  leaderLayer: SVGSVGElement;
};

type PartLabel = {
  element: HTMLDivElement;
  leaderLine: SVGLineElement;
  anchor: Vector3;
};

type PartSurface = {
  geometry: BufferGeometry;
  material: MeshPhysicalMaterial;
};

type ScenePart = {
  id: string;
  labelText: string;
  isInner: boolean;
  root: Group;
  surfaces: PartSurface[];
  label: PartLabel | null;
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
const keyLight = new DirectionalLight(0xfff4e6, 2.3);
const shellFadeUniform = { value: 0 };
const fadedOpacityUniform = { value: 1 };
const shellSurfaceUniforms: SurfaceFadeUniforms = {
  shellFade: shellFadeUniform,
  fadedOpacity: fadedOpacityUniform,
  fadedRim: { value: 1 },
};
// Fins and other outer parts leave the picture entirely, because a ghost of a
// flipper across the organs reads as a rendering fault.
const vanishingSurfaceUniforms: SurfaceFadeUniforms = {
  shellFade: shellFadeUniform,
  fadedOpacity: { value: 0 },
  fadedRim: { value: 0 },
};
const solidSurfaceUniforms: SurfaceFadeUniforms = {
  shellFade: { value: 0 },
  fadedOpacity: { value: 1 },
  fadedRim: { value: 0 },
};

let page: PageElements | null = null;
let renderer: WebGLRenderer | null = null;
let resizeObserver: ResizeObserver | null = null;
let lightsInstalled = false;
let sceneParts: ScenePart[] = [];
let quizPartId: string | null = null;
let quizLabelShowsQuestionMark = false;
let activeTourId = 0;
let cameraMoveFrameId: number | null = null;
const scheduledTimeoutIds: number[] = [];

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
  switch (part.shape) {
    case "box": {
      const [width, height, depth] = part.size;
      return new BoxGeometry(width, height, depth);
    }
    case "sphere": {
      // Diameter-sized sphere, then scaled into an ellipsoid.
      const [width, height, depth] = part.size;
      const sphere = new SphereGeometry(0.5, 48, 32);
      sphere.scale(width, height, depth);
      return sphere;
    }
    case "cylinder": {
      // Unit cylinder points along Y. size.y is the length before rotation.
      const [width, height, depth] = part.size;
      const cylinder = new CylinderGeometry(0.5, 0.5, 1, 32);
      cylinder.scale(width, height, depth);
      return cylinder;
    }
    case "capsule": {
      // CapsuleGeometry(0.5, 1) is 2 units along Y. size.y is that length.
      const [width, height, depth] = part.size;
      const capsule = new CapsuleGeometry(0.5, 1, 12, 24);
      capsule.scale(width, height, depth);
      return capsule;
    }
    case "torus": {
      const [width, height, depth] = part.size;
      const torus = new TorusGeometry(0.32, 0.18, 24, 48);
      torus.scale(width, height, depth);
      return torus;
    }
    case "loft":
      return createLoftGeometry(part);
    case "fin":
      return createFinGeometry(part);
    case "tube":
      return createTubeGeometry(part);
    default: {
      const unexpectedPart: never = part;
      throw new Error(`Unknown part: ${JSON.stringify(unexpectedPart)}`);
    }
  }
}

// Procedural detail is sized to the part, so skin on a small animal is not as
// coarse as skin on a whale. The median side ignores how long a body is.
function detailScaleForGeometry(geometry: BufferGeometry): number {
  geometry.computeBoundingBox();
  const bounds = geometry.boundingBox;
  if (bounds === null) {
    return 1;
  }
  const size = bounds.getSize(new Vector3());
  const sortedSides = [size.x, size.y, size.z].sort((left, right) => left - right);
  return 2 / Math.max(sortedSides[1], 0.01);
}

function ensureRenderer(): void {
  const elements = pageElements();
  if (renderer !== null) {
    return;
  }
  const glRenderer = new WebGLRenderer({
    canvas: elements.canvas,
    alpha: true,
    antialias: true,
    premultipliedAlpha: true,
  });
  glRenderer.setPixelRatio(Math.min(window.devicePixelRatio, maximumPixelRatio));
  glRenderer.setClearColor(0x000000, 0);
  glRenderer.toneMapping = ACESFilmicToneMapping;
  glRenderer.toneMappingExposure = 0.8;
  glRenderer.shadowMap.enabled = true;
  glRenderer.shadowMap.type = PCFSoftShadowMap;
  // The scene never moves, only the camera, so one shadow pass per play is enough.
  glRenderer.shadowMap.autoUpdate = false;
  renderer = glRenderer;

  const environmentGenerator = new PMREMGenerator(glRenderer);
  scene.environment = environmentGenerator.fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environmentIntensity = 0.42;
  environmentGenerator.dispose();

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
  // Open-water light: bright from above, cool and dim from below.
  scene.add(new HemisphereLight(0xdcebff, 0x1d3147, 0.72));
  keyLight.castShadow = true;
  keyLight.shadow.mapSize.set(shadowMapSize, shadowMapSize);
  keyLight.shadow.bias = -0.0004;
  keyLight.shadow.normalBias = 0.012;
  keyLight.shadow.radius = 6;
  scene.add(keyLight);
  scene.add(keyLight.target);
  const fillLight = new DirectionalLight(0xbcd6f2, 0.42);
  fillLight.position.set(-8, -2, 9);
  scene.add(fillLight);
  lightsInstalled = true;
}

function fitKeyLightToScene(): void {
  const sceneBounds = new Box3();
  for (const scenePart of sceneParts) {
    sceneBounds.expandByObject(scenePart.root);
  }
  const sceneCenter = sceneBounds.getCenter(new Vector3());
  const sceneRadius = sceneBounds.getSize(new Vector3()).length() / 2;
  keyLight.target.position.copy(sceneCenter);
  keyLight.position.copy(sceneCenter).add(
    new Vector3(-0.22, 0.92, 0.3).multiplyScalar(sceneRadius * 2),
  );
  const shadowCamera = keyLight.shadow.camera;
  shadowCamera.left = -sceneRadius;
  shadowCamera.right = sceneRadius;
  shadowCamera.top = sceneRadius;
  shadowCamera.bottom = -sceneRadius;
  shadowCamera.near = 0.1;
  shadowCamera.far = sceneRadius * 4;
  shadowCamera.updateProjectionMatrix();
  if (renderer !== null) {
    renderer.shadowMap.needsUpdate = true;
  }
}

function setShellFade(shellFade: number): void {
  shellFadeUniform.value = shellFade;
  const isFading = shellFade > 0;
  for (const scenePart of sceneParts) {
    if (scenePart.isInner) {
      scenePart.root.visible = isFading;
      continue;
    }
    for (const surface of scenePart.surfaces) {
      // A solid shell must write depth so nothing behind it shows. A fading one
      // must not, or it would hide the far wall drawn after it.
      surface.material.depthWrite = !isFading;
    }
  }
}

function renderSceneOnce(): void {
  if (renderer === null) {
    return;
  }
  const elements = pageElements();
  const cssWidth = elements.canvas.clientWidth;
  const cssHeight = elements.canvas.clientHeight;
  if (cssWidth < 2 || cssHeight < 2) {
    return;
  }
  renderer.setSize(cssWidth, cssHeight, false);
  camera.aspect = cssWidth / cssHeight;
  camera.updateProjectionMatrix();
  renderer.render(scene, camera);
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
    scene.remove(scenePart.root);
    for (const surface of scenePart.surfaces) {
      surface.geometry.dispose();
      surface.material.dispose();
    }
    scenePart.label?.element.remove();
    scenePart.label?.leaderLine.remove();
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

type PlacedLabel = {
  scenePart: ScenePart;
  label: PartLabel;
  anchorX: number;
  anchorY: number;
  labelX: number;
  labelY: number;
  width: number;
  height: number;
};

function labelsOverlap(first: PlacedLabel, second: PlacedLabel): boolean {
  return (
    Math.abs(first.labelX - second.labelX) < (first.width + second.width) / 2 + labelGapPixels &&
    Math.abs(first.labelY - second.labelY) < (first.height + second.height) / 2 + labelGapPixels
  );
}

// Labels sit outside the crowd of anchors: each one is pushed away from their
// shared center, then labels that still touch are stepped apart vertically.
function placeLabels(
  visibleLabels: PlacedLabel[],
  cssWidth: number,
  cssHeight: number,
): void {
  const centerX =
    visibleLabels.reduce((total, placed) => total + placed.anchorX, 0) / visibleLabels.length;
  const centerY =
    visibleLabels.reduce((total, placed) => total + placed.anchorY, 0) / visibleLabels.length;
  for (const placed of visibleLabels) {
    const awayX = placed.anchorX - centerX;
    const awayY = placed.anchorY - centerY;
    const awayLength = Math.max(1, Math.hypot(awayX, awayY));
    placed.labelX = placed.anchorX + (awayX / awayLength) * labelDistancePixels;
    placed.labelY =
      placed.anchorY + (awayY / awayLength) * labelDistancePixels - labelLiftPixels;
  }
  const ordered = [...visibleLabels].sort((first, second) => first.labelY - second.labelY);
  for (let pass = 0; pass < 8; pass += 1) {
    for (let firstIndex = 0; firstIndex < ordered.length; firstIndex += 1) {
      for (let secondIndex = firstIndex + 1; secondIndex < ordered.length; secondIndex += 1) {
        const upper = ordered[firstIndex];
        const lower = ordered[secondIndex];
        if (labelsOverlap(upper, lower)) {
          lower.labelY = upper.labelY + (upper.height + lower.height) / 2 + labelGapPixels + 1;
        }
      }
    }
  }
  for (const placed of visibleLabels) {
    const edgeX = placed.width / 2 + labelEdgeMarginPixels;
    const edgeY = placed.height / 2 + labelEdgeMarginPixels;
    placed.labelX = clampNumber(placed.labelX, edgeX, cssWidth - edgeX);
    placed.labelY = clampNumber(placed.labelY, edgeY, cssHeight - edgeY);
  }
}

function updatePartLabelPositions(): void {
  const elements = pageElements();
  const cssWidth = elements.canvas.clientWidth;
  const cssHeight = elements.canvas.clientHeight;
  if (cssWidth < 2 || cssHeight < 2) {
    return;
  }
  camera.updateMatrixWorld(true);
  const shellHasFaded = shellFadeUniform.value >= labelSwapFade;
  const visibleLabels: PlacedLabel[] = [];
  for (const scenePart of sceneParts) {
    const label = scenePart.label;
    if (label === null) {
      continue;
    }
    label.element.textContent = labelTextForPart(scenePart);
    cameraSpaceAnchor.copy(label.anchor).applyMatrix4(camera.matrixWorldInverse);
    projectedAnchor.copy(label.anchor).project(camera);
    // Three.js cameras look down negative Z. A positive Z is behind the lens.
    const anchorIsOnScreen =
      cameraSpaceAnchor.z < 0 &&
      Math.abs(projectedAnchor.x) < 0.98 &&
      Math.abs(projectedAnchor.y) < 0.98;
    const belongsToThisStage = scenePart.isInner === shellHasFaded;
    const isVisible = anchorIsOnScreen && belongsToThisStage;
    label.element.classList.toggle("is-hidden", !isVisible);
    label.leaderLine.classList.toggle("is-hidden", !isVisible);
    if (isVisible) {
      visibleLabels.push({
        scenePart,
        label,
        anchorX: (projectedAnchor.x * 0.5 + 0.5) * cssWidth,
        anchorY: (-projectedAnchor.y * 0.5 + 0.5) * cssHeight,
        labelX: 0,
        labelY: 0,
        width: label.element.offsetWidth,
        height: label.element.offsetHeight,
      });
    }
  }
  if (visibleLabels.length === 0) {
    return;
  }
  placeLabels(visibleLabels, cssWidth, cssHeight);
  for (const placed of visibleLabels) {
    placed.label.element.style.left = `${placed.labelX}px`;
    placed.label.element.style.top = `${placed.labelY}px`;
    const leaderEnd = leaderEndAtLabelEdge(
      placed.anchorX,
      placed.anchorY,
      placed.labelX,
      placed.labelY,
      placed.width,
      placed.height,
    );
    placed.label.leaderLine.setAttribute("x1", placed.anchorX.toFixed(2));
    placed.label.leaderLine.setAttribute("y1", placed.anchorY.toFixed(2));
    placed.label.leaderLine.setAttribute("x2", leaderEnd.x.toFixed(2));
    placed.label.leaderLine.setAttribute("y2", leaderEnd.y.toFixed(2));
  }
}

function createPartMeshes(part: Part, surfaces: PartSurface[]): Group {
  const root = new Group();
  const copyCount = part.repeat?.count ?? 1;
  const copyOffset = part.repeat?.offset ?? [0, 0, 0];
  const endScale = part.repeat?.endScale ?? 1;
  const rotation = part.rotation ?? [0, 0, 0];
  const placeCopies = (parent: Group) => {
    for (let copyIndex = 0; copyIndex < copyCount; copyIndex += 1) {
      const copyScale =
        copyCount === 1 ? 1 : 1 + ((endScale - 1) * copyIndex) / (copyCount - 1);
      for (const { geometry, material } of surfaces) {
        const mesh = new Mesh(geometry, material);
        mesh.position.set(
          part.position[0] + copyOffset[0] * copyIndex,
          part.position[1] + copyOffset[1] * copyIndex,
          part.position[2] + copyOffset[2] * copyIndex,
        );
        mesh.rotation.set(rotation[0], rotation[1], rotation[2]);
        mesh.scale.setScalar(copyScale);
        const isInteriorWall = material.side === BackSide;
        // Inner parts sit under a shell that would otherwise leave them black.
        mesh.castShadow = !part.inner && !isInteriorWall;
        mesh.receiveShadow = !part.inner && !isInteriorWall;
        // Solid organs draw first, then the far wall, then fins, then the near skin.
        mesh.renderOrder = isInteriorWall ? 1 : part.opacity < 1 ? 3 : part.inner ? 0 : 2;
        parent.add(mesh);
      }
    }
  };
  placeCopies(root);
  if (part.mirror) {
    const reflectedCopies = new Group();
    // A negative scale reflects across z = 0. three.js flips the winding for it.
    reflectedCopies.scale.z = -1;
    placeCopies(reflectedCopies);
    root.add(reflectedCopies);
  }
  return root;
}

function createPartLabel(part: Part, root: Group, elements: PageElements): PartLabel | null {
  if (part.label === "") {
    return null;
  }
  const element = document.createElement("div");
  element.className = "field-trip-label is-hidden";
  element.dataset.partId = part.id;
  element.textContent = part.label;
  elements.labelLayer.appendChild(element);

  const leaderLine = document.createElementNS("http://www.w3.org/2000/svg", "line");
  leaderLine.setAttribute("class", "field-trip-leader is-hidden");
  elements.leaderLayer.appendChild(leaderLine);

  const firstCopy = root.children[0];
  const anchor =
    part.labelAt !== undefined
      ? new Vector3(part.labelAt[0], part.labelAt[1], part.labelAt[2])
      : new Box3().setFromObject(firstCopy ?? root).getCenter(new Vector3());
  return { element, leaderLine, anchor };
}

// The mouth and eye are skin features. Left on the far wall they would show up
// as marks on the inside of the body, so a lofted wall is built without them.
function createInteriorWallGeometry(part: Part, skinGeometry: BufferGeometry): BufferGeometry {
  if (part.shape !== "loft") {
    return skinGeometry.clone();
  }
  return createLoftGeometry({ ...part, creases: [], bumps: [] }, interiorWallResolution);
}

function surfaceFadeForPart(part: Part): SurfaceFadeUniforms {
  if (part.inner) {
    return solidSurfaceUniforms;
  }
  return part.opacity < 1 ? shellSurfaceUniforms : vanishingSurfaceUniforms;
}

function buildParts(parts: Part[]): void {
  const elements = pageElements();
  const shellPart = parts.find((part) => part.opacity < 1);
  fadedOpacityUniform.value = shellPart?.opacity ?? 1;
  for (const part of parts) {
    const geometry = createPartGeometry(part);
    if (part.shape !== "loft") {
      const rotation = part.rotation ?? [0, 0, 0];
      applyWorldSpaceBellyAmount(geometry, new Euler(rotation[0], rotation[1], rotation[2]));
    }
    const detailScale = detailScaleForGeometry(geometry);
    const surfaces: PartSurface[] = [
      {
        geometry,
        material: createSurfaceMaterial({
          color: part.color,
          skin: part.skin,
          tissue: part.tissue,
          detailScale,
          fadesWithShell: !part.inner,
          fade: surfaceFadeForPart(part),
        }),
      },
    ];
    if (part.opacity < 1 && part.skin?.interiorColor !== undefined) {
      surfaces.push({
        geometry: createInteriorWallGeometry(part, geometry),
        material: createInteriorMaterial(
          part.skin.interiorColor,
          detailScale,
          shellSurfaceUniforms,
        ),
      });
    }
    const root = createPartMeshes(part, surfaces);
    scene.add(root);
    root.updateMatrixWorld(true);
    sceneParts.push({
      id: part.id,
      labelText: part.label,
      isInner: part.inner,
      root,
      surfaces,
      label: createPartLabel(part, root, elements),
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
  onProgress: (progress: number) => void,
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
    onProgress(progress);
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
  setShellFade(0);
  fitKeyLightToScene();
  renderSceneOnce();
  const doNothing = () => {};
  scheduleAfterHold(tourId, () => {
    moveCamera(tourId, firstStop, secondStop, doNothing, () => {
      scheduleAfterHold(tourId, () => {
        moveCamera(
          tourId,
          secondStop,
          thirdStop,
          (progress) => {
            const fadeProgress = clampNumber(
              (progress - shellFadeStartProgress) /
                (shellFadeEndProgress - shellFadeStartProgress),
              0,
              1,
            );
            setShellFade(easeInOutCubic(fadeProgress));
          },
          () => {
            if (tourId !== activeTourId) {
              return;
            }
            setQuizLabelShowsQuestionMark(true);
          },
        );
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
