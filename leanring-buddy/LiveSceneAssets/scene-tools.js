// Clicky's voice tools for the page in the live scene window, added before any page script runs.
// Each tool is a plain function over the page's window.liveScene primitives, described in the same
// { name, description, inputSchema } shape WebMCP and MCP use. A tool is listed only while the page
// has the primitives it needs, so a generated page that skips one simply offers fewer tools.
// Every call ends the camera tour first, because the learner asking for a change means the tour is over.
// A simulation page also defines liveScene.controls, setControl, and run. This file draws the one panel for them
// (a slider per control, a Run button, and the readouts), so the model never draws its own, and offers set_control
// and run_simulation. A finished run is posted to the app as "runFinished:<readouts JSON>" so Clicky can say the result.
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

  // A simulation page defines up to 3 controls, setControl, and run. Anything less is a plain 3D model.
  const maximumControls = 3;
  const isUsableControl = (control) => control !== null && typeof control === "object" && typeof control.name === "string"
    && Number.isFinite(Number(control.min)) && Number.isFinite(Number(control.max)) && Number(control.max) > Number(control.min);
  const simulationControls = () => {
    const controls = liveScene()?.controls;
    return Array.isArray(controls) ? controls.filter(isUsableControl).slice(0, maximumControls) : [];
  };
  const hasSimulation = () => simulationControls().length > 0
    && typeof liveScene()?.setControl === "function"
    && typeof liveScene()?.run === "function";
  const controlSummary = (control) => ({
    name: control.name,
    label: String(control.label ?? control.name),
    min: Number(control.min),
    max: Number(control.max),
    step: Number(control.step) > 0 ? Number(control.step) : 1,
    value: Number(control.value),
    unit: String(control.unit ?? ""),
  });
  // What the page reports is untrusted text that Clicky may say out loud, so it is cut to a few short, plain entries.
  const currentReadouts = () => {
    const readouts = liveScene()?.getState?.()?.readouts;
    if (!Array.isArray(readouts)) return [];
    return readouts
      .filter((readout) => readout !== null && typeof readout === "object" && typeof readout.label === "string" && Number.isFinite(Number(readout.value)))
      .slice(0, maximumControls)
      .map((readout) => ({ label: readout.label.slice(0, 40), value: Number(readout.value), unit: String(readout.unit ?? "").slice(0, 16) }));
  };

  let runIsGoing = false;
  let latestRunNumber = 0;

  const pageState = () => ({
    ...(liveScene()?.getState?.() ?? {}),
    labels: labelsOnScreen(),
    explodeAmount,
    insideIsOpen,
    ...(hasSimulation() ? { controls: simulationControls().map(controlSummary), readouts: currentReadouts(), runIsGoing } : {}),
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

  // The panel is styled like the scene labels, and sits on the document root so the rise animation, which moves
  // the body, never carries it. It appears when the tour ends, which is when the overlay starts taking the mouse.
  const panel = { element: null, controlRows: [], runButton: null, readoutsElement: null };
  const decimalsOf = (step) => String(step).split(".")[1]?.length ?? 0;
  const valueText = (control) => `${control.value.toFixed(decimalsOf(control.step))}${control.unit ? " " + control.unit : ""}`;

  // The panel covers the bottom of the view, so the camera's view moves up by half the panel's height and the scene
  // stays centered in the space above it. The view offset is part of the projection, so the labels the page projects follow.
  let sceneLift = 0;
  let panelHeightTheLiftFits = 0;
  const applySceneLift = () => {
    const camera = liveScene()?.camera;
    const canvas = liveScene()?.renderer?.domElement;
    if (typeof camera?.setViewOffset !== "function" || !canvas) return;
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    if (width > 0 && height > 0) camera.setViewOffset(width, height, 0, sceneLift, width, height);
  };
  const keepSceneAbovePanel = () => {
    const panelHeight = panel.element.offsetHeight;
    if (panelHeight === panelHeightTheLiftFits) return;
    panelHeightTheLiftFits = panelHeight;
    const startLift = sceneLift;
    const targetLift = Math.round((panelHeight + 16) / 2);
    tween(0.4, (progress) => {
      sceneLift = startLift + (targetLift - startLift) * progress;
      applySceneLift();
    });
  };

  const refreshPanel = () => {
    if (!panel.element) return;
    simulationControls().map(controlSummary).forEach((control, index) => {
      const row = panel.controlRows[index];
      if (!row) return;
      row.valueElement.textContent = valueText(control);
      if (Number(row.slider.value) !== control.value) row.slider.value = String(control.value);
    });
    panel.runButton.disabled = runIsGoing;
    panel.runButton.textContent = runIsGoing ? "Running" : "Run";
    const readouts = currentReadouts();
    panel.readoutsElement.replaceChildren(...readouts.map((readout) => {
      const line = document.createElement("div");
      line.style.cssText = "display:flex;gap:6px;white-space:nowrap;";
      const labelElement = document.createElement("span");
      labelElement.textContent = readout.label;
      labelElement.style.opacity = "0.7";
      const valueElement = document.createElement("span");
      valueElement.textContent = `${readout.value} ${readout.unit}`.trim();
      valueElement.style.fontWeight = "700";
      line.append(labelElement, valueElement);
      return line;
    }));
    panel.readoutsElement.style.display = readouts.length > 0 ? "flex" : "none";
    keepSceneAbovePanel();
  };

  const ensurePanel = () => {
    if (panel.element || !document.body || !hasSimulation()) return;
    const element = document.createElement("div");
    element.id = "clicky-simulation-panel";
    element.style.cssText = "position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:10;box-sizing:border-box;width:min(560px,calc(100vw - 32px));display:flex;flex-wrap:wrap;align-items:flex-end;gap:8px 16px;padding:10px 14px;border-radius:12px;background:rgba(250,246,240,0.96);color:#222;font:600 13px -apple-system,system-ui,sans-serif;box-shadow:0 1px 4px rgba(0,0,0,0.3);-webkit-user-select:none;user-select:none;";
    const style = document.createElement("style");
    style.textContent = "#clicky-simulation-panel input[type=range]{width:100%;margin:4px 0 0;accent-color:#3380ff;cursor:pointer}#clicky-simulation-panel button{cursor:pointer}#clicky-simulation-panel button:hover:not(:disabled){filter:brightness(1.1)}#clicky-simulation-panel button:disabled{cursor:default;opacity:0.7}";
    element.append(style);
    // A press or wheel on the panel is the panel's. It must not turn or zoom the model behind it.
    for (const eventName of ["pointerdown", "mousedown", "touchstart", "wheel"]) {
      element.addEventListener(eventName, (event) => event.stopPropagation());
    }
    panel.controlRows = simulationControls().map(controlSummary).map((control) => {
      const row = document.createElement("div");
      row.style.cssText = "flex:1 1 140px;min-width:0;";
      const heading = document.createElement("div");
      heading.style.cssText = "display:flex;justify-content:space-between;gap:8px;white-space:nowrap;";
      const labelElement = document.createElement("span");
      labelElement.textContent = control.label;
      const valueElement = document.createElement("span");
      heading.append(labelElement, valueElement);
      const slider = document.createElement("input");
      slider.type = "range";
      slider.min = String(control.min);
      slider.max = String(control.max);
      slider.step = String(control.step);
      slider.value = String(control.value);
      slider.addEventListener("input", () => {
        liveScene().endTour?.();
        liveScene().setControl(control.name, Number(slider.value));
        refreshPanel();
      });
      row.append(heading, slider);
      element.append(row);
      return { slider, valueElement };
    });
    panel.runButton = document.createElement("button");
    panel.runButton.style.cssText = "flex:0 0 auto;min-width:84px;padding:7px 18px;border:0;border-radius:8px;background:#3380ff;color:#fff;font:700 14px -apple-system,system-ui,sans-serif;";
    panel.runButton.addEventListener("click", () => {
      liveScene().endTour?.();
      startRun();
    });
    panel.readoutsElement = document.createElement("div");
    panel.readoutsElement.style.cssText = "display:none;flex-basis:100%;flex-wrap:wrap;gap:4px 18px;padding-top:8px;border-top:1px solid rgba(0,0,0,0.15);font-weight:600;";
    element.append(panel.runButton, panel.readoutsElement);
    document.documentElement.append(element);
    panel.element = element;
    // The page's own resize handler resets the camera's aspect, so the lift is applied again after it with the new size.
    window.addEventListener("resize", () => requestAnimationFrame(applySceneLift));
    refreshPanel();
  };

  // Plays the simulation once. A run that never reports its end is given up after 20 seconds, so Run unlocks.
  // A newer run, from the button or the voice, replaces an older one, and the older one's end is ignored.
  const startRun = () => {
    runIsGoing = true;
    latestRunNumber += 1;
    const thisRunNumber = latestRunNumber;
    refreshPanel();
    // run() starts in this call, so the motion begins at once, and a throw ends the run like a rejection does.
    let runResult;
    try {
      runResult = liveScene().run();
    } catch (error) {
      runResult = Promise.reject(error);
    }
    const runEnded = Promise.race([Promise.resolve(runResult), new Promise((resolve) => setTimeout(resolve, 20000))]);
    runEnded.catch((error) => console.error("simulation run failed: " + error)).then(() => {
      if (thisRunNumber !== latestRunNumber) return;
      runIsGoing = false;
      refreshPanel();
      const readouts = currentReadouts();
      if (readouts.length > 0) window.webkit?.messageHandlers?.liveSceneEvent?.postMessage("runFinished:" + JSON.stringify(readouts));
    });
  };

  // The tour ends by itself or by a call, and either sets __tourFinished. The page defines liveScene during load, so wait for it.
  const panelWatcher = setInterval(() => {
    if (window.__tourFinished === true) ensurePanel();
    if (panel.element) clearInterval(panelWatcher);
  }, 150);
  setTimeout(() => clearInterval(panelWatcher), 120000);

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
        // Only resetView reports a refusal. focusPart("") may return false on a generated page after it restored the view.
        if (typeof liveScene().resetView === "function") {
          if (liveScene().resetView() === false) return stillLoading;
        } else {
          liveScene().focusPart("");
        }
        return { ok: true };
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
    {
      name: "set_control",
      // A getter, so the model reads the controls this page defines, with their ranges and current values.
      get description() {
        const controlList = simulationControls().map(controlSummary)
          .map((control) => `${control.name} (${control.label}, ${control.min} to ${control.max}${control.unit ? " " + control.unit : ""}, now ${control.value})`)
          .join("; ");
        return `Change one number of the simulation on screen and put it back at its start, without running it. The controls are: ${controlList}. Use the control's name and a value in its unit.`;
      },
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string", description: "The name of one control from the description." },
          value: { type: "number", description: "The new value in the control's unit. The page clamps it to the control's range." },
        },
        required: ["name", "value"],
      },
      isAvailable: hasSimulation,
      run: (input) => {
        const value = Number(input.value);
        if (!Number.isFinite(value)) return { ok: false, error: "value must be a number" };
        const name = String(input.name ?? "");
        if (liveScene().setControl(name, value) === false) {
          return { ok: false, error: `No control is named "${name}". The controls are: ${simulationControls().map((control) => control.name).join(", ")}` };
        }
        refreshPanel();
        return { ok: true };
      },
    },
    {
      name: "run_simulation",
      description: "Play the simulation on screen once from its start with the current controls. It takes a few seconds, and the state's readouts hold the result when it ends.",
      inputSchema: { type: "object", properties: {} },
      isAvailable: hasSimulation,
      run: () => {
        startRun();
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
        ensurePanel();
        const outcome = tool.run(input && typeof input === "object" ? input : {});
        return { ...outcome, state: pageState() };
      } catch (error) {
        return { ok: false, error: String(error), state: pageState() };
      }
    },
    state: pageState,
  };
})();
