// Clicky's voice tools for the page in the live scene window, added before any page script runs.
// Each tool is a plain function over the page's window.liveScene primitives, described in the same
// { name, description, inputSchema } shape WebMCP and MCP use. A tool is listed only while the page
// has the primitives it needs, so a generated page that skips one simply offers fewer tools.
// Every call ends the camera tour first, because the learner asking for a change means the tour is over.
(() => {
  const liveScene = () => window.liveScene;
  const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  // The landmark page styles its place name as a label too, and it is not a part.
  const labelsOnScreen = () => [...document.querySelectorAll(".scene-label:not(#placeName)")]
    .map((labelElement) => labelElement.textContent.trim())
    .filter((labelText) => labelText !== "");

  // A primitive returns false when the page refused the change, such as a landmark still loading.
  const stillLoading = { ok: false, error: "The scene is still loading, so try again in a moment" };

  let explodeAmount = 0;
  let insideIsOpen = false;

  const pageState = () => ({
    ...(liveScene()?.getState?.() ?? {}),
    labels: labelsOnScreen(),
    explodeAmount,
    insideIsOpen,
  });

  const hasParts = () => Array.isArray(liveScene()?.parts) && liveScene().parts.length > 0 && Boolean(liveScene().THREE);

  // One-shot tween driven by animation frames, so it stops on its own. Reduce Motion jumps to the end.
  const tween = (seconds, applyProgress) => {
    if (reducedMotion()) {
      applyProgress(1);
      return;
    }
    const startedAt = performance.now();
    const step = (now) => {
      const progress = Math.min(1, (now - startedAt) / 1000 / seconds);
      applyProgress(1 - Math.pow(1 - progress, 3));
      if (progress < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  };

  // Measured once, on the assembled model, so every later amount moves from the same starting layout.
  // Each part gets the offset, in its parent's space, that fully exploding moves it by: outward from
  // the model's center, 0.45 of the model's radius. A part at the center stays put.
  let explodeLayout = null;
  const measureExplodeLayout = () => {
    const { THREE, parts } = liveScene();
    const modelBox = new THREE.Box3();
    for (const part of parts) modelBox.expandByObject(part.object);
    const modelCenter = modelBox.getCenter(new THREE.Vector3());
    const modelRadius = modelBox.getSize(new THREE.Vector3()).length() / 2;
    return parts.map((part) => {
      const object = part.object;
      const partCenter = new THREE.Box3().setFromObject(object).getCenter(new THREE.Vector3());
      const outward = partCenter.sub(modelCenter);
      const outwardLength = outward.length();
      const fullOffsetInParent = new THREE.Vector3();
      if (outwardLength > modelRadius * 0.02 && object.parent) {
        const parentWorldOrigin = new THREE.Vector3().setFromMatrixPosition(object.parent.matrixWorld);
        const fullWorldOffset = outward.multiplyScalar((modelRadius * 0.45) / outwardLength);
        fullOffsetInParent.copy(object.parent.worldToLocal(parentWorldOrigin.add(fullWorldOffset)));
      }
      return { object, assembledPosition: object.position.clone(), fullOffsetInParent };
    });
  };
  const explode = (amount) => {
    explodeLayout ??= measureExplodeLayout();
    const moves = explodeLayout.map((layout) => ({
      object: layout.object,
      from: layout.object.position.clone(),
      target: layout.assembledPosition.clone().addScaledVector(layout.fullOffsetInParent, amount),
    }));
    tween(0.7, (progress) => {
      for (const move of moves) move.object.position.lerpVectors(move.from, move.target, progress);
    });
    explodeAmount = amount;
  };

  // The outer shell is cut by a plane through the model's center, facing away from the camera, so the half
  // nearer the learner disappears and the parts inside show. Shell materials are cloned first, because a
  // material shared with an inner part would cut that part too. The plane follows the camera as it orbits.
  const shellMeshes = [];
  const setInsideOpen = (open) => {
    const { THREE, parts, camera, renderer } = liveScene();
    if (renderer) renderer.localClippingEnabled = true;
    if (shellMeshes.length === 0) {
      for (const part of parts.filter((candidate) => candidate.isOuterShell)) {
        part.object.traverse((child) => {
          if (child.isMesh) shellMeshes.push({ mesh: child, originalMaterial: child.material, originalOnBeforeRender: child.onBeforeRender });
        });
      }
    }
    const cutPlane = new THREE.Plane();
    const modelBox = new THREE.Box3();
    for (const part of parts) modelBox.expandByObject(part.object);
    const modelCenter = modelBox.getCenter(new THREE.Vector3());
    for (const shell of shellMeshes) {
      if (open) {
        const cutMaterials = [shell.originalMaterial].flat().map((material) => {
          const cutMaterial = material.clone();
          cutMaterial.clippingPlanes = [cutPlane];
          cutMaterial.side = THREE.DoubleSide;
          return cutMaterial;
        });
        shell.mesh.material = Array.isArray(shell.originalMaterial) ? cutMaterials : cutMaterials[0];
        shell.mesh.onBeforeRender = () => {
          const awayFromCamera = modelCenter.clone().sub(camera.position).normalize();
          cutPlane.setFromNormalAndCoplanarPoint(awayFromCamera, modelCenter);
        };
      } else {
        shell.mesh.material = shell.originalMaterial;
        shell.mesh.onBeforeRender = shell.originalOnBeforeRender;
      }
    }
    insideIsOpen = open;
  };

  const tools = [
    {
      name: "rotate_model",
      description: "Orbit the camera around the model on screen. Positive yawDegrees moves the camera to the right around the model, negative to the left. Positive pitchDegrees moves the camera up to look down on it. The state's yawDegrees and pitchDegrees say where the camera is now.",
      inputSchema: {
        type: "object",
        properties: {
          yawDegrees: { type: "number", description: "Degrees to orbit left or right, from -360 to 360." },
          pitchDegrees: { type: "number", description: "Degrees to orbit up or down, from -80 to 80. Leave out to keep the height." },
        },
        required: ["yawDegrees"],
      },
      isAvailable: () => typeof liveScene()?.rotateBy === "function",
      run: (input) => {
        const yawDegrees = Number(input.yawDegrees);
        const pitchDegrees = Number(input.pitchDegrees ?? 0);
        if (!Number.isFinite(yawDegrees) || !Number.isFinite(pitchDegrees)) return { ok: false, error: "yawDegrees and pitchDegrees must be numbers" };
        const turned = liveScene().rotateBy(Math.max(-360, Math.min(360, yawDegrees)), Math.max(-80, Math.min(80, pitchDegrees)));
        return turned === false ? stillLoading : { ok: true };
      },
    },
    {
      name: "zoom",
      description: "Move the camera closer to or farther from what it looks at. factor 1.3 moves about 30 percent closer, 0.7 about 30 percent farther. The state's zoom runs from 0 (farthest) to 1 (closest).",
      inputSchema: {
        type: "object",
        properties: { factor: { type: "number", description: "Above 1 zooms in, below 1 zooms out, from 0.3 to 3." } },
        required: ["factor"],
      },
      isAvailable: () => typeof liveScene()?.zoomBy === "function",
      run: (input) => {
        const factor = Number(input.factor);
        if (!Number.isFinite(factor) || factor <= 0) return { ok: false, error: "factor must be a positive number" };
        // zoomBy(amount) scales the camera distance by (1 - amount), so moving factor times closer is 1 - 1 / factor.
        const zoomed = liveScene().zoomBy(1 - 1 / Math.max(0.3, Math.min(3, factor)));
        return zoomed === false ? stillLoading : { ok: true };
      },
    },
    {
      name: "zoom_to_part",
      description: "Move the camera to one labeled part, make it glow, and dim the others. label must be one of the state's labels.",
      inputSchema: {
        type: "object",
        properties: { label: { type: "string", description: "A label from the state's labels." } },
        required: ["label"],
      },
      isAvailable: () => typeof liveScene()?.focusPart === "function" && labelsOnScreen().length > 0,
      run: (input) => {
        const found = liveScene().focusPart(String(input.label ?? ""));
        return found ? { ok: true } : { ok: false, error: `No part is labeled "${input.label}". The labels are: ${labelsOnScreen().join(", ")}` };
      },
    },
    {
      name: "reset_view",
      description: "Show the whole model again from the starting angle, with no part highlighted, assembled and closed.",
      inputSchema: { type: "object", properties: {} },
      isAvailable: () => typeof liveScene()?.resetView === "function" || typeof liveScene()?.focusPart === "function",
      run: () => {
        if (hasParts() && explodeAmount !== 0) explode(0);
        if (hasParts() && insideIsOpen) setInsideOpen(false);
        const reset = typeof liveScene().resetView === "function" ? liveScene().resetView() : liveScene().focusPart("");
        return reset === false ? stillLoading : { ok: true };
      },
    },
    {
      name: "explode_view",
      description: "Pull the model's parts apart from its center so each one shows, or put them back. amount 0 is assembled, 1 is fully apart.",
      inputSchema: {
        type: "object",
        properties: { amount: { type: "number", description: "From 0 (assembled) to 1 (fully apart)." } },
        required: ["amount"],
      },
      isAvailable: () => hasParts() && liveScene().parts.length > 1,
      run: (input) => {
        const amount = Number(input.amount);
        if (!Number.isFinite(amount)) return { ok: false, error: "amount must be a number" };
        explode(Math.max(0, Math.min(1, amount)));
        return { ok: true };
      },
    },
    {
      name: "set_inside_view",
      description: "Cut away the half of the outer shell nearest the camera so the parts inside show, or close it again.",
      inputSchema: {
        type: "object",
        properties: { open: { type: "boolean", description: "true cuts the shell open, false closes it." } },
        required: ["open"],
      },
      isAvailable: () => hasParts()
        && liveScene().parts.some((part) => part.isOuterShell)
        && liveScene().parts.some((part) => !part.isOuterShell)
        && Boolean(liveScene().camera),
      run: (input) => {
        setInsideOpen(input.open === true);
        return { ok: true };
      },
    },
  ];

  window.clickyTools = {
    list: () => tools
      .filter((tool) => tool.isAvailable())
      .map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
    call: (name, input) => {
      const tool = tools.find((candidate) => candidate.name === name);
      if (!tool || !tool.isAvailable()) return { ok: false, error: `${name} is not available on this scene`, state: pageState() };
      try {
        liveScene().endTour?.();
        const outcome = tool.run(input && typeof input === "object" ? input : {});
        return { ...outcome, state: pageState() };
      } catch (error) {
        return { ok: false, error: String(error), state: pageState() };
      }
    },
    state: pageState,
  };
})();
