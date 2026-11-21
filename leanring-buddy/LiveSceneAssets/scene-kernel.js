// The scene kernel: everything a generated live scene page used to write for itself, so the model writes only the subject.
// The Worker wraps the model's build(kit) function into a page that imports this file from clicky-asset://three/ and calls
// startScene. The kernel draws the renderer, the camera, the lights, the lab room or the field, the camera tour, the part
// labels with their leader lines, dragging, and the whole window.liveScene contract that scene-tools.js, scene-rise.js,
// and the app read. For a simulation it also runs the controls, the dashed preview path, the run, the readouts, the faded
// paths of earlier runs, and the challenge marker, from the setup and simulate functions the model writes.
import * as THREE from "three";

const smoothstep = (progress) => {
  const clamped = Math.min(1, Math.max(0, progress));
  return clamped * clamped * (3 - 2 * clamped);
};
const degreesToRadians = THREE.MathUtils.degToRad;
const radiansToDegrees = THREE.MathUtils.radToDeg;
const toVector = (point) => (point instanceof THREE.Vector3 ? point.clone() : new THREE.Vector3(Number(point[0]), Number(point[1]), Number(point[2])));
const roundedToTwoDecimals = (value) => Math.round(value * 100) / 100;
const normalizedLabel = (labelText) => String(labelText ?? "").trim().toLowerCase();
const isAKernelObject = (object) => object.userData.isKernelObject === true;
const markAsKernelObject = (object) => {
  object.userData.isKernelObject = true;
  return object;
};

const pageStyle = `
html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
canvas.scene-canvas { position: absolute; left: 0; top: 0; display: block; width: 100%; height: 100%; }
svg.scene-leaders { position: absolute; left: 0; top: 0; width: 100%; height: 100%; pointer-events: none; overflow: visible;
  filter: drop-shadow(0 0 1.5px rgba(255, 255, 255, 0.95)); }
.scene-label { position: absolute; left: 0; top: 0; padding: 5px 10px; border-radius: 8px; background: rgba(250, 246, 240, 0.96); color: #222;
  font: 600 14px -apple-system, "Helvetica Neue", Arial, sans-serif; white-space: nowrap; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.3);
  pointer-events: none; transition: background-color 0.3s; }
.scene-label.focused { background: #ffe066; }
.scene-label.quiz-answer.unanswered { background: #2f7bf6; color: #fff; font-size: 20px; padding: 6px 15px; border-radius: 11px; }
`;

/** The camera always looks at an aim point from yaw and pitch angles (radians) and a distance, so moves blend cleanly. */
function cameraPosition(pose) {
  const horizontal = Math.cos(pose.pitch) * pose.distance;
  return new THREE.Vector3(
    pose.aim.x + Math.sin(pose.yaw) * horizontal,
    pose.aim.y + Math.sin(pose.pitch) * pose.distance,
    pose.aim.z + Math.cos(pose.yaw) * horizontal,
  );
}

function blendPoses(fromPose, toPose, progress) {
  return {
    aim: fromPose.aim.clone().lerp(toPose.aim, progress),
    yaw: fromPose.yaw + (toPose.yaw - fromPose.yaw) * progress,
    pitch: fromPose.pitch + (toPose.pitch - fromPose.pitch) * progress,
    // Distance blends on a log scale, so a long zoom in does not rush its last stretch.
    distance: Math.exp(Math.log(fromPose.distance) + (Math.log(toPose.distance) - Math.log(fromPose.distance)) * progress),
  };
}

/** The yaw nearest to fromYaw that faces the same way as toYaw, so a move turns the short way round. */
function nearestYaw(fromYaw, toYaw) {
  const fullTurn = Math.PI * 2;
  return fromYaw + ((((toYaw - fromYaw + Math.PI) % fullTurn) + fullTurn) % fullTurn) - Math.PI;
}

/** A procedural studio for reflections, since the page may load no image: a dim room with two bright panels. */
function studioEnvironment(renderer) {
  const roomScene = new THREE.Scene();
  roomScene.add(new THREE.Mesh(new THREE.BoxGeometry(12, 8, 12), new THREE.MeshBasicMaterial({ color: 0x6d7378, side: THREE.BackSide })));
  const addPanel = (x, y, z, width, height, brightness) => {
    const panel = new THREE.Mesh(new THREE.PlaneGeometry(width, height), new THREE.MeshBasicMaterial({ color: new THREE.Color(brightness, brightness, brightness) }));
    panel.position.set(x, y, z);
    panel.lookAt(0, 0, 0);
    roomScene.add(panel);
  };
  addPanel(-4, 3.5, 3, 5, 3, 6);
  addPanel(4.5, 1.5, -2, 3, 4, 3);
  addPanel(0, -3.9, 0, 10, 10, 0.6);
  const environmentGenerator = new THREE.PMREMGenerator(renderer);
  const environmentTexture = environmentGenerator.fromScene(roomScene, 0.04).texture;
  environmentGenerator.dispose();
  return environmentTexture;
}

/** A soft grass texture drawn on a canvas, since the page may load no image. */
function grassTexture() {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 256;
  const context = canvas.getContext("2d");
  context.fillStyle = "#5d8a43";
  context.fillRect(0, 0, 256, 256);
  let seed = 7;
  const random = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  for (let speck = 0; speck < 9000; speck += 1) {
    const shade = 70 + Math.floor(random() * 70);
    context.fillStyle = `rgba(${shade - 30}, ${shade + 40}, ${shade - 45}, 0.35)`;
    context.fillRect(random() * 256, random() * 256, 1 + random() * 2, 1 + random() * 3);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

/**
 * Starts the page. kind is "model" or "simulation", answerLabel is the quiz's answer part (shown as "?" on a model
 * until reveal), and build is the model's build(kit) function.
 */
export function startScene({ kind, answerLabel, build }) {
  const isSimulation = kind === "simulation";
  const style = document.createElement("style");
  style.textContent = pageStyle;
  document.head.appendChild(style);

  const api = {};
  window.liveScene = api;
  window.__tourFinished = false;
  window.__ready = false;

  const scene = new THREE.Scene();
  const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true });
  renderer.setClearColor(0x000000, 0);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  // scene-tools.js cuts the outer shell open with a clipping plane.
  renderer.localClippingEnabled = true;
  renderer.domElement.className = "scene-canvas";
  document.body.prepend(renderer.domElement);
  const leaderLayer = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  leaderLayer.setAttribute("class", "scene-leaders");
  document.body.appendChild(leaderLayer);

  const camera = new THREE.PerspectiveCamera(38, window.innerWidth / Math.max(1, window.innerHeight), 0.01, 5000);
  scene.environment = studioEnvironment(renderer);
  scene.environmentIntensity = 0.55;

  const hemisphereLight = new THREE.HemisphereLight(0xf4f8ff, 0x4a4640, 1.25);
  const keyLight = new THREE.DirectionalLight(0xfff3e2, 2.6);
  keyLight.castShadow = true;
  keyLight.shadow.mapSize.set(2048, 2048);
  keyLight.shadow.bias = -0.0002;
  keyLight.shadow.normalBias = 0.02;
  const fillLight = new THREE.DirectionalLight(0xdbe8ff, 0.9);
  const rimLight = new THREE.DirectionalLight(0xffffff, 1.1);
  for (const light of [hemisphereLight, keyLight, keyLight.target, fillLight, rimLight]) scene.add(markAsKernelObject(light));

  api.THREE = THREE;
  api.camera = camera;
  api.renderer = renderer;
  api.parts = [];

  // What the model registers: each part with its label element and leader line.
  const registeredParts = [];
  const frameCallbacks = [];
  // The lab room, the field, and scenery the model adds through kit.scenery, which the camera never frames.
  const worldBackdrop = markAsKernelObject(new THREE.Group());
  scene.add(worldBackdrop);

  const kit = {
    THREE,
    scene,
    part(label, object, options = {}) {
      object.name = String(label);
      if (!object.parent) scene.add(object);
      const isAnswer = !isSimulation && normalizedLabel(label) === normalizedLabel(answerLabel);
      const labelElement = document.createElement("div");
      labelElement.className = isAnswer ? "scene-label quiz-answer unanswered" : "scene-label";
      labelElement.textContent = isAnswer ? "?" : String(label);
      document.body.appendChild(labelElement);
      const leaderLine = document.createElementNS("http://www.w3.org/2000/svg", "line");
      leaderLine.setAttribute("stroke", "rgba(34, 38, 42, 0.9)");
      leaderLine.setAttribute("stroke-width", "1.5");
      leaderLayer.appendChild(leaderLine);
      const leaderDot = document.createElementNS("http://www.w3.org/2000/svg", "circle");
      leaderDot.setAttribute("r", "3");
      leaderDot.setAttribute("fill", "rgba(34, 38, 42, 0.95)");
      leaderLayer.appendChild(leaderDot);
      registeredParts.push({
        label: String(label),
        object,
        isOuterShell: options.outerShell === true,
        isAnswer,
        anchor: options.anchor === undefined ? undefined : toVector(options.anchor),
        labelElement,
        leaderLine,
        leaderDot,
      });
      api.parts.push({ label: String(label), object, isOuterShell: options.outerShell === true });
      return object;
    },
    scenery(object) {
      worldBackdrop.add(object);
      return object;
    },
    material(color, options = {}) {
      return new THREE.MeshPhysicalMaterial({ color, roughness: 0.6, metalness: 0, ...options });
    },
    mesh(geometry, material, parent, position, rotation, scale) {
      const mesh = new THREE.Mesh(geometry, material);
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      if (position) mesh.position.set(position[0], position[1], position[2]);
      if (rotation) mesh.rotation.set(rotation[0], rotation[1], rotation[2]);
      if (typeof scale === "number") mesh.scale.setScalar(scale);
      else if (scale) mesh.scale.set(scale[0], scale[1], scale[2]);
      (parent ?? scene).add(mesh);
      return mesh;
    },
    tube(points, radius, material, parent) {
      const curve = new THREE.CatmullRomCurve3(points.map(toVector));
      return kit.mesh(new THREE.TubeGeometry(curve, Math.max(24, points.length * 16), radius, 20, false), material, parent);
    },
    lathe(profile, material, parent) {
      const lathePoints = profile.map(([radius, height]) => new THREE.Vector2(radius, height));
      return kit.mesh(new THREE.LatheGeometry(lathePoints, 64), material, parent);
    },
    onFrame(callback) {
      frameCallbacks.push(callback);
    },
    lab({ width = 1.6, depth = 0.8 } = {}) {
      const wallColor = 0xdde3e6;
      scene.background = new THREE.Color(wallColor);
      const benchWidth = width + 0.6;
      const benchDepth = depth + 0.4;
      const benchTop = new THREE.Mesh(new THREE.BoxGeometry(benchWidth, 0.05, benchDepth), new THREE.MeshPhysicalMaterial({ color: 0x3b4246, roughness: 0.55, clearcoat: 0.3 }));
      benchTop.position.y = -0.025;
      benchTop.receiveShadow = true;
      const cabinet = new THREE.Mesh(new THREE.BoxGeometry(benchWidth - 0.04, 0.85, benchDepth - 0.06), new THREE.MeshStandardMaterial({ color: 0xc9cfd2, roughness: 0.7 }));
      cabinet.position.y = -0.475;
      const floor = new THREE.Mesh(new THREE.PlaneGeometry(40, 40), new THREE.MeshStandardMaterial({ color: 0x9aa3a8, roughness: 0.9 }));
      floor.rotation.x = -Math.PI / 2;
      floor.position.y = -0.9;
      floor.receiveShadow = true;
      const wallMaterial = new THREE.MeshStandardMaterial({ color: wallColor, roughness: 0.95 });
      const backWall = new THREE.Mesh(new THREE.PlaneGeometry(40, 6), wallMaterial);
      backWall.position.set(0, 2.1, -benchDepth / 2 - 1.4);
      backWall.receiveShadow = true;
      const leftWall = new THREE.Mesh(new THREE.PlaneGeometry(40, 6), wallMaterial);
      leftWall.rotation.y = Math.PI / 2;
      leftWall.position.set(-benchWidth / 2 - 2.5, 2.1, 0);
      const rightWall = leftWall.clone();
      rightWall.rotation.y = -Math.PI / 2;
      rightWall.position.x = benchWidth / 2 + 2.5;
      worldBackdrop.add(benchTop, cabinet, floor, backWall, leftWall, rightWall);
      return { top: 0 };
    },
    field({ size = 120 } = {}) {
      const skyColor = 0xa9d1ee;
      scene.background = new THREE.Color(skyColor);
      scene.fog = new THREE.Fog(skyColor, size * 1.5, size * 9);
      const grass = grassTexture();
      grass.repeat.set(size * 2, size * 2);
      const ground = new THREE.Mesh(new THREE.PlaneGeometry(size * 40, size * 40), new THREE.MeshStandardMaterial({ map: grass, roughness: 1 }));
      ground.rotation.x = -Math.PI / 2;
      ground.receiveShadow = true;
      worldBackdrop.add(ground);
      hemisphereLight.color.set(0xdcefff);
      hemisphereLight.groundColor.set(0x56703c);
      return { top: 0 };
    },
  };

  const built = build(kit) ?? {};
  const answerPart = registeredParts.find((part) => part.isAnswer);

  // ---- Looks: dimming and glowing parts ----
  const meshesOf = (object) => {
    const meshes = [];
    object.traverse((child) => {
      if (child.isMesh && !isAKernelObject(child)) meshes.push(child);
    });
    return meshes;
  };
  // A material that meshes of two parts share is copied for each mesh the first time a part's look changes, so dimming
  // one part never dims another. A material one part owns is changed in place, so the model's own references to it,
  // such as a liquid it fills in show(t), keep working.
  const partsUsingMaterial = new Map();
  for (const part of registeredParts) {
    for (const mesh of meshesOf(part.object)) {
      for (const material of [mesh.material].flat()) {
        if (!partsUsingMaterial.has(material)) partsUsingMaterial.set(material, new Set());
        partsUsingMaterial.get(material).add(part);
      }
    }
  }
  const originalLooks = new Map();
  const lookOf = (material) => {
    if (!originalLooks.has(material)) {
      originalLooks.set(material, {
        opacity: material.opacity,
        transparent: material.transparent,
        depthWrite: material.depthWrite,
        emissive: material.emissive?.clone(),
        emissiveIntensity: material.emissiveIntensity,
      });
    }
    return originalLooks.get(material);
  };
  const ownMaterialsOf = (part) => {
    const materials = [];
    for (const mesh of meshesOf(part.object)) {
      const copyIfShared = (material) => {
        if ((partsUsingMaterial.get(material)?.size ?? 1) <= 1) return material;
        const copy = material.clone();
        originalLooks.set(copy, lookOf(material));
        partsUsingMaterial.set(copy, new Set([part]));
        return copy;
      };
      mesh.material = Array.isArray(mesh.material) ? mesh.material.map(copyIfShared) : copyIfShared(mesh.material);
      materials.push(...[mesh.material].flat());
    }
    return materials;
  };
  const setLook = (part, { opacity = 1, glow = false }) => {
    for (const material of ownMaterialsOf(part)) {
      const original = lookOf(material);
      const targetOpacity = original.opacity * opacity;
      const becomesTransparent = original.transparent || targetOpacity < 0.999;
      if (material.transparent !== becomesTransparent) material.needsUpdate = true;
      material.opacity = targetOpacity;
      material.transparent = becomesTransparent;
      material.depthWrite = original.depthWrite && targetOpacity > 0.6;
      if (material.emissive && original.emissive) {
        if (glow) {
          material.emissive.set(0xffc94a);
          material.emissiveIntensity = 0.35;
        } else {
          material.emissive.copy(original.emissive);
          material.emissiveIntensity = original.emissiveIntensity;
        }
      }
    }
  };

  // ---- Boxes and framing ----
  const boxOf = (object) => new THREE.Box3().setFromObject(object);
  // The subject is everything the model added, except the backdrop, so equipment with no label still counts.
  const subjectBox = () => {
    const box = new THREE.Box3();
    for (const child of scene.children) {
      if (!isAKernelObject(child) && !child.isLight) box.union(boxOf(child));
    }
    if (box.isEmpty()) box.set(new THREE.Vector3(-0.5, -0.5, -0.5), new THREE.Vector3(0.5, 0.5, 0.5));
    return box;
  };

  // The distance at which every corner of the box fits in the view from this direction, with fill the share of the view it may use.
  const fittedDistance = (box, aim, yaw, pitch, fill) => {
    const towardCamera = cameraPosition({ aim, yaw, pitch, distance: 1 }).sub(aim).normalize();
    const right = new THREE.Vector3(0, 1, 0).cross(towardCamera).normalize();
    const up = towardCamera.clone().cross(right).normalize();
    const halfHeightTangent = Math.tan(degreesToRadians(camera.fov / 2)) * fill;
    const halfWidthTangent = halfHeightTangent * camera.aspect;
    let distance = 0;
    for (let cornerIndex = 0; cornerIndex < 8; cornerIndex += 1) {
      const corner = new THREE.Vector3(
        cornerIndex & 1 ? box.max.x : box.min.x,
        cornerIndex & 2 ? box.max.y : box.min.y,
        cornerIndex & 4 ? box.max.z : box.min.z,
      ).sub(aim);
      const depthTowardCamera = corner.dot(towardCamera);
      distance = Math.max(
        distance,
        depthTowardCamera + Math.abs(corner.dot(right)) / halfWidthTangent,
        depthTowardCamera + Math.abs(corner.dot(up)) / halfHeightTangent,
      );
    }
    return Math.max(distance, box.getSize(new THREE.Vector3()).length() * 0.3, 0.05);
  };
  const framingPose = (box, yaw, pitch, fill, aim = box.getCenter(new THREE.Vector3())) => ({
    aim,
    yaw,
    pitch,
    distance: fittedDistance(box, aim, yaw, pitch, fill),
  });

  // ---- Simulation state ----
  const controls = Array.isArray(built.controls) ? built.controls : [];
  const controlValues = () => Object.fromEntries(controls.map((control) => [control.name, Number(control.value)]));
  let readouts = [];
  let previewLine = null;
  let previewRing = null;
  let previewIsVisible = false;
  const pastPaths = [];
  let tracedPath = null;
  let runInFlight = null;
  let challengeMarker = null;

  const pathMaterial = (color, opacity, dashed) => (dashed
    ? new THREE.LineDashedMaterial({ color, dashSize: 0.06, gapSize: 0.04, transparent: true, opacity, depthTest: false })
    : new THREE.LineBasicMaterial({ color, transparent: true, opacity, depthTest: false }));
  const flatRing = (radius, color) => {
    const ring = new THREE.Mesh(new THREE.TorusGeometry(radius, radius * 0.12, 12, 64), new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.5 }));
    ring.rotation.x = -Math.PI / 2;
    return markAsKernelObject(ring);
  };
  const pathLine = (points, material) => {
    const line = new THREE.Line(new THREE.BufferGeometry().setFromPoints(points), material);
    line.renderOrder = 5;
    return markAsKernelObject(line);
  };
  const removeFromTheScene = (object) => {
    if (!object) return;
    scene.remove(object);
    object.geometry?.dispose();
  };

  const runResultFor = (values) => {
    const result = built.simulate(values) ?? {};
    const path = Array.isArray(result.path) ? result.path.map(toVector) : [];
    return { ...result, path };
  };

  const putTheSetupAtItsStart = () => {
    stopRunInFlight();
    built.setup?.(controlValues());
  };
  function stopRunInFlight() {
    if (!runInFlight) return;
    runInFlight.resolve();
    runInFlight = null;
    removeFromTheScene(tracedPath);
    tracedPath = null;
  }

  // The challenge target comes from the model's own physics at control values inside every range, so it can always be hit.
  const challenge = (() => {
    const asked = built.challenge;
    if (!isSimulation || !asked || typeof asked.prompt !== "string") return undefined;
    const values = controlValues();
    for (const control of controls) {
      const askedValue = Number(asked.values?.[control.name]);
      if (Number.isFinite(askedValue)) values[control.name] = Math.min(control.max, Math.max(control.min, askedValue));
    }
    const result = runResultFor(values);
    const targetReadout = (result.readouts ?? []).find((readout) => normalizedLabel(readout.label) === normalizedLabel(asked.readoutLabel));
    if (!targetReadout) return undefined;
    const target = roundedToTwoDecimals(Number(targetReadout.value));
    const tolerance = Number(asked.tolerance) > 0 ? Number(asked.tolerance) : Math.max(0.01, roundedToTwoDecimals(Math.abs(target) * 0.03));
    const markerPoint = asked.markPathEnd === true && result.path.length > 0 ? result.path[result.path.length - 1] : undefined;
    return { prompt: asked.prompt, readoutLabel: String(targetReadout.label), target, tolerance, markerPoint };
  })();

  if (isSimulation) putTheSetupAtItsStart();
  // What the camera frames: the subject, and for a simulation the path of a run from the starting controls.
  const startingBox = () => {
    const box = subjectBox();
    if (isSimulation) {
      for (const point of runResultFor(controlValues()).path) box.expandByPoint(point);
    }
    return box;
  };
  const wholeBox = startingBox();
  const wholeCenter = wholeBox.getCenter(new THREE.Vector3());
  const wholeSize = Math.max(0.05, wholeBox.getSize(new THREE.Vector3()).length());

  // A part with no anchor gets one on its own surface: the first point a ray from outside hits on the way to its center.
  const raycaster = new THREE.Raycaster();
  for (const part of registeredParts) {
    if (part.anchor) continue;
    const partCenter = boxOf(part.object).getCenter(new THREE.Vector3());
    let outward = partCenter.clone().sub(wholeCenter);
    if (outward.length() < wholeSize * 0.08) outward = new THREE.Vector3(0.35, 0.5, 0.8);
    outward.normalize();
    raycaster.set(partCenter.clone().addScaledVector(outward, wholeSize * 2), outward.clone().negate());
    const hit = raycaster.intersectObject(part.object, true)[0];
    part.anchor = part.object.worldToLocal((hit ? hit.point : partCenter).clone());
  }

  // ---- Camera ----
  // A path much longer than the equipment, such as a launched ball's, is seen from behind its start and to one side, so the
  // equipment stands large in front and the path runs away across the view. Otherwise the model's view, or a front
  // three-quarter view, frames the setup.
  const startingPath = isSimulation ? runResultFor(controlValues()).path : [];
  const equipmentSize = subjectBox().getSize(new THREE.Vector3()).length();
  const pathRunsAway = startingPath.length >= 2
    && Math.hypot(startingPath[startingPath.length - 1].x - startingPath[0].x, startingPath[startingPath.length - 1].z - startingPath[0].z) > equipmentSize * 3;
  const viewYaw = pathRunsAway
    ? Math.atan2(startingPath[0].x - startingPath[startingPath.length - 1].x, startingPath[0].z - startingPath[startingPath.length - 1].z) + degreesToRadians(50)
    : degreesToRadians(Number(built.view?.yawDegrees ?? 32));
  const viewPitch = degreesToRadians(pathRunsAway ? 16 : Math.min(70, Math.max(5, Number(built.view?.pitchDegrees ?? 20))));
  // The aim sits near the equipment when the path runs away, so the camera stands close behind it and the path recedes.
  const simulationAim = pathRunsAway ? subjectBox().getCenter(new THREE.Vector3()).lerp(wholeBox.getCenter(new THREE.Vector3()), 0.3) : wholeBox.getCenter(new THREE.Vector3());
  const homePose = isSimulation
    ? framingPose(wholeBox, viewYaw, viewPitch, 0.92, simulationAim)
    : framingPose(wholeBox, degreesToRadians(25), degreesToRadians(14), 0.78);
  const closestDistance = homePose.distance * 0.25;
  const farthestDistance = homePose.distance * 2.4;

  // The key light and its shadow cover the subject at any size.
  const wholeRadius = wholeSize / 2;
  keyLight.target.position.copy(wholeCenter);
  keyLight.position.copy(wholeCenter).add(new THREE.Vector3(-0.6, 1.1, 0.8).multiplyScalar(wholeRadius * 3));
  Object.assign(keyLight.shadow.camera, { left: -wholeRadius * 1.3, right: wholeRadius * 1.3, top: wholeRadius * 1.3, bottom: -wholeRadius * 1.3, near: wholeRadius * 0.5, far: wholeRadius * 7 });
  keyLight.shadow.camera.updateProjectionMatrix();
  fillLight.position.copy(wholeCenter).add(new THREE.Vector3(1, 0.4, 0.6).multiplyScalar(wholeRadius * 3));
  rimLight.position.copy(wholeCenter).add(new THREE.Vector3(0.2, 0.8, -1).multiplyScalar(wholeRadius * 3));
  camera.near = Math.max(0.001, wholeRadius * 0.01);
  camera.far = Math.max(wholeRadius * 80, 200);
  camera.updateProjectionMatrix();

  let currentPose = { ...homePose, aim: homePose.aim.clone() };
  const applyPose = (pose) => {
    currentPose = pose;
    camera.position.copy(cameraPosition(pose));
    camera.lookAt(pose.aim);
  };

  // The tour, as the pose at the end of each step. A model holds outside, circles, then moves to the answer part.
  // A simulation holds, then moves to its three-quarter view and stays there.
  const insideView = !isSimulation && built.insideView === true && answerPart !== undefined;
  const answerCenter = answerPart ? boxOf(answerPart.object).getCenter(new THREE.Vector3()) : wholeCenter.clone();
  // Dragging and rotateBy orbit the whole subject, or the answer part for an inside view.
  const orbitCenter = insideView ? answerCenter : wholeCenter;
  const tour = (() => {
    if (isSimulation) {
      const startPose = framingPose(wholeBox, viewYaw + degreesToRadians(28), viewPitch + degreesToRadians(12), 0.7, simulationAim);
      return { startPose, steps: [{ seconds: 0.5, pose: startPose }, { seconds: 2, pose: homePose }] };
    }
    const circledPose = { ...homePose, yaw: homePose.yaw + Math.PI * 2 };
    let answerPose = circledPose;
    if (answerPart) {
      const answerBox = boxOf(answerPart.object);
      const outward = answerCenter.clone().sub(wholeCenter);
      const answerYaw = outward.x * outward.x + outward.z * outward.z > 1e-8 ? Math.atan2(outward.x, outward.z) : homePose.yaw;
      const yaw = nearestYaw(circledPose.yaw, answerYaw);
      const pitch = degreesToRadians(12);
      if (insideView) {
        // Beside the answer part, with the faded shell and the neighboring parts still in view.
        answerPose = { aim: answerCenter.clone(), yaw, pitch, distance: Math.min(homePose.distance * 0.6, Math.max(homePose.distance * 0.4, fittedDistance(answerBox, answerCenter, yaw, pitch, 0.25))) };
      } else {
        const aim = wholeCenter.clone().lerp(answerCenter, 0.75);
        const distance = Math.min(homePose.distance * 0.8, Math.max(homePose.distance * 0.4, fittedDistance(answerBox, aim, yaw, pitch, 0.3)));
        answerPose = { aim, yaw, pitch, distance };
      }
    }
    return {
      startPose: homePose,
      steps: [{ seconds: 1, pose: homePose }, { seconds: 3, pose: circledPose }, { seconds: 2, pose: answerPose, fadesTheShell: insideView }],
    };
  })();
  const tourEndPose = tour.steps[tour.steps.length - 1].pose;
  applyPose(tour.startPose);

  let tourIsFinished = false;
  let tourStartedAt = null;
  let shellOpacity = 1;
  let cameraMove = null;
  let focusedPart = null;

  const applyShellOpacity = (opacity) => {
    shellOpacity = opacity;
    for (const part of registeredParts) {
      if (part.isOuterShell && part !== focusedPart) setLook(part, { opacity });
    }
  };
  const finishTheTour = () => {
    if (tourIsFinished) return;
    tourIsFinished = true;
    window.__tourFinished = true;
    window.webkit?.messageHandlers?.liveSceneEvent?.postMessage("tourFinished");
  };
  const moveCameraTo = (pose, seconds) => {
    cameraMove = { fromPose: currentPose, toPose: pose, startedAt: performance.now(), seconds };
  };
  const poseAMoveStartsFrom = () => {
    const pose = cameraMove ? cameraMove.toPose : currentPose;
    return { ...pose, aim: pose.aim.clone() };
  };

  const stepTheTour = (now) => {
    if (tourIsFinished) return;
    tourStartedAt ??= now;
    let secondsIntoTheTour = (now - tourStartedAt) / 1000;
    let previousPose = tour.startPose;
    for (const step of tour.steps) {
      if (secondsIntoTheTour < step.seconds) {
        const progress = smoothstep(secondsIntoTheTour / step.seconds);
        applyPose(blendPoses(previousPose, step.pose, progress));
        if (step.fadesTheShell) applyShellOpacity(1 - 0.85 * progress);
        return;
      }
      secondsIntoTheTour -= step.seconds;
      previousPose = step.pose;
    }
    endTour();
  };

  function endTour() {
    if (tourIsFinished) return;
    applyPose({ ...tourEndPose, aim: tourEndPose.aim.clone() });
    if (insideView) applyShellOpacity(0.15);
    finishTheTour();
  }

  // ---- The window.liveScene contract ----
  const partNamed = (labelText) => registeredParts.find((part) =>
    normalizedLabel(part.label) === normalizedLabel(labelText) || normalizedLabel(part.labelElement.textContent) === normalizedLabel(labelText));

  api.reveal = () => {
    if (!answerPart) return;
    answerPart.labelElement.textContent = answerPart.label;
    answerPart.labelElement.classList.remove("unanswered");
  };

  api.focusPart = (labelText) => {
    if (String(labelText ?? "") === "") {
      focusedPart = null;
      for (const part of registeredParts) {
        part.labelElement.classList.remove("focused");
        setLook(part, { opacity: part.isOuterShell ? shellOpacity : 1 });
      }
      moveCameraTo({ ...homePose, aim: homePose.aim.clone(), yaw: nearestYaw(currentPose.yaw, homePose.yaw) }, 1.5);
      return true;
    }
    const part = partNamed(labelText);
    if (!part) return false;
    endTour();
    focusedPart = part;
    for (const otherPart of registeredParts) {
      otherPart.labelElement.classList.toggle("focused", otherPart === part);
      setLook(otherPart, otherPart === part ? { opacity: 1, glow: true } : { opacity: 0.35 });
    }
    const partBox = boxOf(part.object);
    const partCenter = partBox.getCenter(new THREE.Vector3());
    const outward = partCenter.clone().sub(wholeCenter);
    const partYaw = outward.x * outward.x + outward.z * outward.z > 1e-8 ? Math.atan2(outward.x, outward.z) : currentPose.yaw;
    const yaw = nearestYaw(currentPose.yaw, partYaw);
    const blendedYaw = currentPose.yaw + (yaw - currentPose.yaw) * 0.5;
    const pitch = Math.max(degreesToRadians(5), currentPose.pitch);
    const distance = Math.min(farthestDistance, Math.max(closestDistance, fittedDistance(partBox, partCenter, blendedYaw, pitch, 0.4)));
    moveCameraTo({ aim: partCenter, yaw: blendedYaw, pitch, distance }, 1.5);
    return true;
  };

  api.rotateBy = (yawDegrees, pitchDegrees) => {
    endTour();
    const startFrom = poseAMoveStartsFrom();
    const pitch = Math.min(degreesToRadians(80), Math.max(degreesToRadians(-30), startFrom.pitch + degreesToRadians(Number(pitchDegrees) || 0)));
    moveCameraTo({ ...startFrom, aim: orbitCenter.clone(), yaw: startFrom.yaw + degreesToRadians(Number(yawDegrees) || 0), pitch }, 0.6);
    return true;
  };

  api.zoomBy = (amount) => {
    if (!tourIsFinished) return false;
    const startFrom = poseAMoveStartsFrom();
    startFrom.distance = Math.min(farthestDistance, Math.max(closestDistance, startFrom.distance * (1 - Number(amount || 0))));
    moveCameraTo(startFrom, 0.4);
    return true;
  };

  api.endTour = () => {
    endTour();
    return true;
  };

  api.getState = () => ({
    yawDegrees: roundedToTwoDecimals(((((radiansToDegrees(currentPose.yaw) + 180) % 360) + 360) % 360) - 180),
    pitchDegrees: roundedToTwoDecimals(radiansToDegrees(currentPose.pitch)),
    zoom: roundedToTwoDecimals(1 - (Math.log(currentPose.distance) - Math.log(closestDistance)) / (Math.log(farthestDistance) - Math.log(closestDistance))),
    focusedLabel: focusedPart?.label ?? "",
    tourFinished: tourIsFinished,
    ...(isSimulation ? { readouts: readouts.map((readout) => ({ ...readout })) } : {}),
  });

  // A simulation's labels start hidden, because they cover the setup.
  let labelsAreVisible = !isSimulation;
  const showLabels = (visible) => {
    labelsAreVisible = visible;
    for (const part of registeredParts) {
      for (const element of [part.labelElement, part.leaderLine, part.leaderDot]) element.style.display = visible ? "" : "none";
    }
  };
  showLabels(labelsAreVisible);

  const redrawPreview = () => {
    removeFromTheScene(previewLine);
    removeFromTheScene(previewRing);
    previewLine = null;
    previewRing = null;
    const result = runResultFor(controlValues());
    if (result.path.length < 2) return;
    const material = pathMaterial(0x2fd8ff, 0.95, true);
    material.dashSize = wholeSize * 0.02;
    material.gapSize = wholeSize * 0.013;
    previewLine = pathLine(result.path, material);
    previewLine.computeLineDistances();
    previewLine.visible = previewIsVisible;
    scene.add(previewLine);
    if (result.ringAtEnd === true) {
      previewRing = flatRing(wholeSize * 0.025, 0x2fd8ff);
      previewRing.position.copy(result.path[result.path.length - 1]).add(new THREE.Vector3(0, wholeSize * 0.002, 0));
      previewRing.visible = previewIsVisible;
      scene.add(previewRing);
    }
  };

  const keepPastPath = (points) => {
    if (points.length < 2) return;
    const pastPath = pathLine(points, pathMaterial(0xfff0a8, 0.7, false));
    pastPaths.unshift(pastPath);
    scene.add(pastPath);
    for (const oldPath of pastPaths.splice(3)) removeFromTheScene(oldPath);
    pastPaths.forEach((path, index) => (path.material.opacity = [0.7, 0.4, 0.2][index]));
  };

  if (isSimulation) {
    api.controls = controls;
    api.setLabelsVisible = (visible) => {
      showLabels(visible === true);
      return true;
    };
    api.setPreviewVisible = (visible) => {
      previewIsVisible = visible === true;
      if (previewLine) previewLine.visible = previewIsVisible;
      if (previewRing) previewRing.visible = previewIsVisible;
      return true;
    };
    api.setControl = (name, value) => {
      const control = controls.find((candidate) => candidate.name === name);
      if (!control || !Number.isFinite(Number(value))) return false;
      const step = Number(control.step) > 0 ? Number(control.step) : 0;
      let snapped = Math.min(control.max, Math.max(control.min, Number(value)));
      if (step > 0) snapped = Math.min(control.max, control.min + Math.round((snapped - control.min) / step) * step);
      control.value = roundedToTwoDecimals(snapped);
      putTheSetupAtItsStart();
      redrawPreview();
      return true;
    };
    api.reset = () => {
      putTheSetupAtItsStart();
      return true;
    };
    api.run = () => {
      putTheSetupAtItsStart();
      const result = runResultFor(controlValues());
      const simulatedSeconds = Math.max(0.001, Number(result.seconds) || 1);
      // A run lasts 2 to 8 seconds on screen, faster or slower than real time.
      const playbackSeconds = Math.min(8, Math.max(2, simulatedSeconds));
      if (result.path.length >= 2) {
        tracedPath = pathLine(result.path, pathMaterial(0xfff0a8, 1, false));
        tracedPath.geometry.setDrawRange(0, 1);
        scene.add(tracedPath);
      }
      result.show?.(0);
      return new Promise((resolve) => {
        runInFlight = { result, simulatedSeconds, playbackSeconds, startedAt: performance.now(), resolve };
      });
    };
    api.challenge = challenge && { prompt: challenge.prompt, readoutLabel: challenge.readoutLabel, target: challenge.target, tolerance: challenge.tolerance };
    api.setChallengeVisible = (visible) => {
      if (!challenge?.markerPoint) return true;
      if (visible !== true) {
        if (challengeMarker) challengeMarker.visible = false;
        return true;
      }
      if (!challengeMarker) {
        challengeMarker = flatRing(Math.max(challenge.tolerance, wholeSize * 0.03), 0xffbf2e);
        challengeMarker.position.copy(challenge.markerPoint).add(new THREE.Vector3(0, wholeSize * 0.003, 0));
        scene.add(challengeMarker);
      }
      challengeMarker.visible = true;
      endTour();
      const box = startingBox().expandByObject(challengeMarker);
      moveCameraTo(framingPose(box, nearestYaw(currentPose.yaw, homePose.yaw), homePose.pitch, 0.9), 1);
      return true;
    };
    redrawPreview();
  }

  const stepTheRun = (now) => {
    if (!runInFlight) return;
    const { result, simulatedSeconds, playbackSeconds, startedAt } = runInFlight;
    const progress = Math.min(1, (now - startedAt) / 1000 / playbackSeconds);
    result.show?.(simulatedSeconds * progress);
    if (tracedPath) tracedPath.geometry.setDrawRange(0, Math.max(1, Math.ceil(result.path.length * progress)));
    if (progress < 1) return;
    readouts = (Array.isArray(result.readouts) ? result.readouts : []).slice(0, 3).map((readout) => ({
      label: String(readout.label),
      value: roundedToTwoDecimals(Number(readout.value)),
      unit: String(readout.unit ?? ""),
    }));
    removeFromTheScene(tracedPath);
    tracedPath = null;
    keepPastPath(result.path);
    const finishedRun = runInFlight;
    runInFlight = null;
    finishedRun.resolve();
  };

  // ---- Dragging and the wheel, after the tour only ----
  let drag = null;
  let dragHasAimedAtTheCenter = false;
  const canvas = renderer.domElement;
  canvas.style.touchAction = "none";
  canvas.addEventListener("pointerdown", (event) => {
    if (!tourIsFinished) return;
    drag = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
    canvas.setPointerCapture?.(event.pointerId);
    // The first drag eases the aim to the center it orbits, so nothing jumps.
    if (!dragHasAimedAtTheCenter) {
      dragHasAimedAtTheCenter = true;
      moveCameraTo({ ...poseAMoveStartsFrom(), aim: orbitCenter.clone() }, 0.5);
    }
  });
  canvas.addEventListener("pointermove", (event) => {
    if (!drag || drag.pointerId !== event.pointerId) return;
    const deltaX = event.clientX - drag.x;
    const deltaY = event.clientY - drag.y;
    drag.x = event.clientX;
    drag.y = event.clientY;
    const turnedPose = poseAMoveStartsFrom();
    turnedPose.yaw -= deltaX * 0.006;
    turnedPose.pitch = Math.min(degreesToRadians(80), Math.max(degreesToRadians(-30), turnedPose.pitch + deltaY * 0.005));
    if (cameraMove) cameraMove.toPose = turnedPose;
    else applyPose(turnedPose);
  });
  const stopDragging = (event) => {
    if (drag?.pointerId === event.pointerId) drag = null;
  };
  canvas.addEventListener("pointerup", stopDragging);
  canvas.addEventListener("pointercancel", stopDragging);
  canvas.addEventListener("wheel", (event) => {
    if (!tourIsFinished) return;
    event.preventDefault();
    api.zoomBy(Math.max(-0.3, Math.min(0.3, -event.deltaY * 0.0015)));
  }, { passive: false });

  window.addEventListener("resize", () => {
    renderer.setSize(window.innerWidth, window.innerHeight);
    camera.aspect = window.innerWidth / Math.max(1, window.innerHeight);
    camera.updateProjectionMatrix();
  });

  // ---- Labels ----
  const screenPointOf = (worldPoint) => {
    const projected = worldPoint.clone().project(camera);
    return { x: ((projected.x + 1) / 2) * window.innerWidth, y: ((1 - projected.y) / 2) * window.innerHeight, isInFront: projected.z < 1 };
  };
  const placeLabels = () => {
    if (!labelsAreVisible || registeredParts.length === 0) return;
    const subjectCenter = screenPointOf(isSimulation ? subjectBox().getCenter(new THREE.Vector3()) : wholeCenter);
    const placements = registeredParts.map((part, index) => {
      const anchor = screenPointOf(part.object.localToWorld(part.anchor.clone()));
      let directionX = anchor.x - subjectCenter.x;
      let directionY = anchor.y - subjectCenter.y;
      const length = Math.hypot(directionX, directionY);
      if (length < 24) {
        const fallbackAngle = -Math.PI / 2 + index * 2.1;
        directionX = Math.cos(fallbackAngle);
        directionY = Math.sin(fallbackAngle);
      } else {
        directionX /= length;
        directionY /= length;
      }
      const width = part.labelElement.offsetWidth;
      const height = part.labelElement.offsetHeight;
      return { part, anchor, width, height, centerX: anchor.x + directionX * (64 + width / 2), centerY: anchor.y + directionY * 52 };
    });
    // Labels that would overlap are pushed apart up and down for a few passes, then kept inside the window.
    for (let pass = 0; pass < 4; pass += 1) {
      for (const first of placements) {
        for (const second of placements) {
          if (first === second) continue;
          const overlapX = (first.width + second.width) / 2 + 8 - Math.abs(first.centerX - second.centerX);
          const overlapY = (first.height + second.height) / 2 + 6 - Math.abs(first.centerY - second.centerY);
          if (overlapX <= 0 || overlapY <= 0) continue;
          const push = overlapY / 2 + 1;
          const firstIsHigher = first.centerY <= second.centerY;
          first.centerY += firstIsHigher ? -push : push;
          second.centerY += firstIsHigher ? push : -push;
        }
      }
    }
    const margin = 10;
    for (const placement of placements) {
      const { part, anchor, width, height } = placement;
      const centerX = Math.min(window.innerWidth - margin - width / 2, Math.max(margin + width / 2, placement.centerX));
      const centerY = Math.min(window.innerHeight - margin - height / 2, Math.max(margin + height / 2, placement.centerY));
      const opacity = anchor.isInFront ? "1" : "0";
      part.labelElement.style.opacity = opacity;
      part.labelElement.style.transform = `translate(${centerX - width / 2}px, ${centerY - height / 2}px)`;
      part.leaderLine.setAttribute("x1", String(anchor.x));
      part.leaderLine.setAttribute("y1", String(anchor.y));
      part.leaderLine.setAttribute("x2", String(Math.min(centerX + width / 2, Math.max(centerX - width / 2, anchor.x))));
      part.leaderLine.setAttribute("y2", String(Math.min(centerY + height / 2, Math.max(centerY - height / 2, anchor.y))));
      part.leaderLine.style.opacity = opacity;
      part.leaderDot.setAttribute("cx", String(anchor.x));
      part.leaderDot.setAttribute("cy", String(anchor.y));
      part.leaderDot.style.opacity = opacity;
    }
  };

  // ---- The frame loop ----
  const startedAt = performance.now();
  const renderFrame = (now) => {
    stepTheTour(now);
    if (cameraMove) {
      const progress = smoothstep((now - cameraMove.startedAt) / 1000 / cameraMove.seconds);
      applyPose(blendPoses(cameraMove.fromPose, cameraMove.toPose, progress));
      if (progress >= 1) cameraMove = null;
    }
    stepTheRun(now);
    for (const callback of frameCallbacks) callback((now - startedAt) / 1000);
    renderer.render(scene, camera);
    placeLabels();
    window.__ready = true;
    requestAnimationFrame(renderFrame);
  };
  requestAnimationFrame(renderFrame);
}
