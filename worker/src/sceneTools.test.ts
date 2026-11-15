import { describe, expect, it, vi } from "vitest";
// Vite reads the app's page script as text, so this test runs the real file the overlay injects.
import sceneToolsSource from "../../leanring-buddy/LiveSceneAssets/scene-tools.js?raw";

type ToolDescriptor = { name: string; description: string; inputSchema: unknown };
type ToolCallResult = { ok: boolean; error?: string; state: Record<string, unknown> };

/** Runs scene-tools.js against a page whose window.liveScene is `liveScene`. With no document given there is no body, so no panel is drawn. */
function loadSceneTools(liveScene: Record<string, unknown>, fakeDocument: Record<string, unknown> = { body: null, querySelectorAll: () => [] }) {
  const postedEvents: string[] = [];
  const fakeWindow: Record<string, unknown> = {
    liveScene,
    webkit: { messageHandlers: { liveSceneEvent: { postMessage: (message: string) => postedEvents.push(message) } } },
    addEventListener: () => {},
  };
  new Function(
    "window",
    "document",
    "matchMedia",
    "performance",
    "requestAnimationFrame",
    "setInterval",
    "clearInterval",
    "setTimeout",
    sceneToolsSource,
  )(
    fakeWindow,
    fakeDocument,
    () => ({ matches: true }),
    { now: () => 0 },
    () => 0,
    () => 0,
    () => {},
    () => 0,
  );
  const clickyTools = fakeWindow.clickyTools as {
    list: () => ToolDescriptor[];
    call: (name: string, input: unknown) => ToolCallResult;
    state: () => Record<string, unknown>;
    simulation: { guessHeard: () => boolean; startChallenge: () => string | null };
  };
  return { clickyTools, postedEvents };
}

const angleControl = { name: "angle", label: "Launch angle", min: 5, max: 85, step: 1, value: 45, unit: "degrees" };

function simulationPage(overrides: Record<string, unknown> = {}) {
  const controls = [{ ...angleControl }];
  return {
    controls,
    setControl: vi.fn((name: string, value: number) => {
      const control = controls.find((candidate) => candidate.name === name);
      if (!control) return false;
      control.value = Math.max(control.min, Math.min(control.max, value));
      return true;
    }),
    run: vi.fn(() => Promise.resolve()),
    getState: () => ({ readouts: [{ label: "Landing distance", value: 40.8, unit: "m" }] }),
    endTour: vi.fn(),
    rotateBy: () => true,
    zoomBy: () => true,
    focusPart: () => false,
    ...overrides,
  };
}

const toolNames = (clickyTools: { list: () => ToolDescriptor[] }) => clickyTools.list().map((tool) => tool.name);

/** A page past the guess, so Run is unlocked. */
function loadGuessedSimulation(overrides: Record<string, unknown> = {}) {
  const page = simulationPage(overrides);
  const loaded = loadSceneTools(page);
  loaded.clickyTools.simulation.guessHeard();
  return { page, ...loaded };
}

type RunReport = {
  readouts: Array<{ label: string; value: number; unit: string }>;
  pastRuns: Array<{ controls: Array<{ label: string; value: number; unit: string }>; readouts: unknown[] }>;
  challenge: { status: string; attempts: number; difference: number; unit: string; readoutLabel: string } | null;
};
const runReport = (postedEvent: string | undefined): RunReport => JSON.parse(String(postedEvent).slice("runFinished:".length));

const finishARun = async (clickyTools: { call: (name: string, input: unknown) => ToolCallResult }, postedEvents: string[]) => {
  const eventCountBefore = postedEvents.length;
  clickyTools.call("run_simulation", {});
  await vi.waitFor(() => expect(postedEvents.length).toBe(eventCountBefore + 1));
  return runReport(postedEvents.at(-1));
};

const rangeChallenge = { prompt: "Can you land the ball in the ring?", readoutLabel: "Landing distance", target: 30, tolerance: 1 };

describe("scene-tools.js simulation tools", () => {
  it("lists set_control and run_simulation only when the page has controls, setControl, and run", () => {
    expect(toolNames(loadSceneTools({ rotateBy: () => true, zoomBy: () => true, focusPart: () => false }).clickyTools)).not.toContain("set_control");

    const { clickyTools } = loadSceneTools(simulationPage());
    expect(toolNames(clickyTools)).toEqual(expect.arrayContaining(["set_control", "run_simulation"]));

    expect(toolNames(loadSceneTools(simulationPage({ run: undefined })).clickyTools)).not.toContain("run_simulation");
    expect(toolNames(loadSceneTools(simulationPage({ setControl: undefined })).clickyTools)).not.toContain("set_control");
    expect(toolNames(loadSceneTools(simulationPage({ controls: [] })).clickyTools)).not.toContain("run_simulation");
  });

  it("lists set_labels only when the page can show and hide its labels, and tracks whether they show", () => {
    expect(toolNames(loadSceneTools(simulationPage()).clickyTools)).not.toContain("set_labels");

    const setLabelsVisible = vi.fn(() => true);
    const { clickyTools } = loadSceneTools(simulationPage({ setLabelsVisible }));
    expect(toolNames(clickyTools)).toContain("set_labels");
    expect(clickyTools.state().labelsAreShown).toBe(false);

    expect(clickyTools.call("set_labels", { visible: true }).state.labelsAreShown).toBe(true);
    expect(setLabelsVisible).toHaveBeenLastCalledWith(true);
    expect(clickyTools.call("set_labels", { visible: false }).state.labelsAreShown).toBe(false);
    expect(setLabelsVisible).toHaveBeenLastCalledWith(false);
    // Anything but a real true hides them, so a model's stray string never shows them.
    clickyTools.call("set_labels", { visible: true });
    expect(clickyTools.call("set_labels", { visible: "yes" }).state.labelsAreShown).toBe(false);
  });

  it("keeps the labels state when the page refuses to change them", () => {
    const { clickyTools } = loadSceneTools(simulationPage({ setLabelsVisible: () => false }));

    const refused = clickyTools.call("set_labels", { visible: true });

    expect(refused.ok).toBe(false);
    expect(refused.state.labelsAreShown).toBe(false);
  });

  it("describes each control to the model with its range and current value", () => {
    const setControlTool = loadSceneTools(simulationPage()).clickyTools.list().find((tool) => tool.name === "set_control");

    expect(setControlTool?.description).toContain("angle (Launch angle, 5 to 85 degrees, now 45)");
  });

  it("sets a control through the page, and refuses a name the page does not have", () => {
    const page = simulationPage();
    const { clickyTools } = loadSceneTools(page);

    const changed = clickyTools.call("set_control", { name: "angle", value: 30 });
    expect(changed.ok).toBe(true);
    expect(page.setControl).toHaveBeenCalledWith("angle", 30);
    expect(page.endTour).toHaveBeenCalled();
    expect(changed.state.controls).toEqual([{ ...angleControl, value: 30 }]);

    const refused = clickyTools.call("set_control", { name: "mass", value: 3 });
    expect(refused).toMatchObject({ ok: false, error: expect.stringContaining("angle") });
    expect(clickyTools.call("set_control", { name: "angle", value: "steep" }).ok).toBe(false);
  });

  it("runs the simulation once and posts the readouts to the app when the run ends", async () => {
    const { page, clickyTools, postedEvents } = loadGuessedSimulation();

    const started = clickyTools.call("run_simulation", {});

    expect(started.ok).toBe(true);
    expect(started.state.runIsGoing).toBe(true);
    expect(page.run).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => expect(postedEvents).toHaveLength(1));
    expect(runReport(postedEvents[0])).toEqual({
      readouts: [{ label: "Landing distance", value: 40.8, unit: "m" }],
      pastRuns: [{ controls: [{ label: "Launch angle", value: 45, unit: "degrees" }], readouts: [{ label: "Landing distance", value: 40.8, unit: "m" }] }],
      challenge: null,
    });
    expect(clickyTools.state().runIsGoing).toBe(false);
  });

  it("locks Run and the dashed path until the learner guesses", () => {
    const setPreviewVisible = vi.fn();
    const page = simulationPage({ setPreviewVisible });
    const { clickyTools } = loadSceneTools(page);

    const refused = clickyTools.call("run_simulation", {});
    expect(refused).toMatchObject({ ok: false, error: expect.stringContaining("guess") });
    expect(page.run).not.toHaveBeenCalled();
    expect(clickyTools.state().lessonStage).toBe("guess");
    // A control may move before the guess. Only running and the path wait for it.
    expect(clickyTools.call("set_control", { name: "angle", value: 30 }).ok).toBe(true);
    expect(setPreviewVisible).not.toHaveBeenCalled();

    expect(clickyTools.simulation.guessHeard()).toBe(true);
    expect(clickyTools.state().lessonStage).toBe("explore");
    expect(setPreviewVisible).toHaveBeenLastCalledWith(true);
    expect(clickyTools.simulation.guessHeard()).toBe(false);
    expect(clickyTools.call("run_simulation", {}).ok).toBe(true);
  });

  it("keeps the last 3 runs, newest first, with the controls each one started with", async () => {
    const { clickyTools, postedEvents } = loadGuessedSimulation();

    for (const angle of [20, 30, 40, 50]) {
      clickyTools.call("set_control", { name: "angle", value: angle });
      await finishARun(clickyTools, postedEvents);
    }

    const pastAngles = runReport(postedEvents.at(-1)).pastRuns.map((pastRun) => pastRun.controls[0]?.value);
    expect(pastAngles).toEqual([50, 40, 30]);
  });

  it("starts the challenge only after the guess, hides the path, and shows the target", () => {
    const setPreviewVisible = vi.fn();
    const setChallengeVisible = vi.fn();
    const { clickyTools } = loadSceneTools(simulationPage({ setPreviewVisible, setChallengeVisible, challenge: rangeChallenge }));

    expect(clickyTools.simulation.startChallenge()).toBeNull();
    clickyTools.simulation.guessHeard();

    expect(clickyTools.simulation.startChallenge()).toBe("Can you land the ball in the ring?");
    expect(setPreviewVisible).toHaveBeenLastCalledWith(false);
    expect(setChallengeVisible).toHaveBeenCalledWith(true);
    expect(clickyTools.state()).toMatchObject({ lessonStage: "challenge", challenge: { target: 30, attempts: 0, hit: false } });
    expect(clickyTools.simulation.startChallenge()).toBeNull();
  });

  it("refuses a challenge with no real target or tolerance", () => {
    for (const challenge of [{ ...rangeChallenge, target: "far" }, { ...rangeChallenge, tolerance: 0 }, { ...rangeChallenge, prompt: " " }, "land it"]) {
      const { clickyTools } = loadGuessedSimulation({ challenge });
      expect(clickyTools.simulation.startChallenge()).toBeNull();
    }
  });

  it("counts each challenge try, says how far off a miss was, and ends on a hit", async () => {
    let landingDistance = 40.8;
    const setPreviewVisible = vi.fn();
    const { clickyTools, postedEvents } = loadGuessedSimulation({
      setPreviewVisible,
      challenge: rangeChallenge,
      getState: () => ({ readouts: [{ label: "Flight time", value: 2, unit: "s" }, { label: "Landing distance", value: landingDistance, unit: "m" }] }),
    });
    expect((await finishARun(clickyTools, postedEvents)).challenge).toBeNull();
    clickyTools.simulation.startChallenge();

    const miss = await finishARun(clickyTools, postedEvents);
    expect(miss.challenge).toEqual({ status: "missed", attempts: 1, difference: 10.8, unit: "m", readoutLabel: "Landing distance" });

    landingDistance = 30.6;
    const hit = await finishARun(clickyTools, postedEvents);
    expect(hit.challenge).toMatchObject({ status: "hit", attempts: 2 });
    expect(clickyTools.state()).toMatchObject({ lessonStage: "done", challenge: { hit: true, attempts: 2 } });
    expect(setPreviewVisible).toHaveBeenLastCalledWith(true);

    expect((await finishARun(clickyTools, postedEvents)).challenge).toBeNull();
  });

  it("ignores the end of a run that a newer run replaced", async () => {
    let finishFirstRun: () => void = () => {};
    const runs = [new Promise<void>((resolve) => (finishFirstRun = resolve)), Promise.resolve()];
    const { clickyTools, postedEvents } = loadGuessedSimulation({ run: vi.fn(() => runs.shift()) });

    clickyTools.call("run_simulation", {});
    clickyTools.call("run_simulation", {});
    await vi.waitFor(() => expect(postedEvents).toHaveLength(1));
    finishFirstRun();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(postedEvents).toHaveLength(1);
  });

  it("passes on at most 3 short readouts with real numbers, since the page's text is spoken aloud", async () => {
    const longLabel = "x".repeat(80);
    const { clickyTools, postedEvents } = loadGuessedSimulation({
      getState: () => ({
        readouts: [
          { label: longLabel, value: 1, unit: "m" },
          { label: "Bad number", value: "NaN", unit: "m" },
          { label: "Two", value: 2, unit: "s" },
          { label: "Three", value: 3, unit: "s" },
          { label: "Four", value: 4, unit: "s" },
        ],
      }),
    });

    const report = await finishARun(clickyTools, postedEvents);

    expect(report.readouts.map((readout) => readout.label)).toEqual(["x".repeat(40), "Two", "Three"]);
  });

  it("moves the camera's view up by half the panel's height, so the panel does not cover the scene", () => {
    const fakeElement = (): Record<string, unknown> => ({
      style: {},
      offsetHeight: 92,
      append: () => {},
      addEventListener: () => {},
      replaceChildren: () => {},
    });
    const fakeDocument = {
      body: {},
      documentElement: { append: () => {} },
      createElement: fakeElement,
      querySelectorAll: () => [],
    };
    const setViewOffset = vi.fn();
    const page = simulationPage({
      camera: { setViewOffset },
      renderer: { domElement: { clientWidth: 800, clientHeight: 450 } },
    });
    const { clickyTools } = loadSceneTools(page, fakeDocument);

    clickyTools.call("set_control", { name: "angle", value: 30 });

    // Reduce Motion is on in this harness, so the lift jumps straight to (92 + 16) / 2.
    expect(setViewOffset).toHaveBeenLastCalledWith(800, 450, 0, 54, 800, 450);
  });
});
