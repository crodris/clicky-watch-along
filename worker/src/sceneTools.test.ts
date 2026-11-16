import { describe, expect, it, vi } from "vitest";
// Vite reads the app's page script as text, so this test runs the real file the overlay injects.
import sceneToolsSource from "../../leanring-buddy/LiveSceneAssets/scene-tools.js?raw";

type ToolDescriptor = { name: string; description: string; inputSchema: unknown };
type ToolCallResult = { ok: boolean; error?: string; state: Record<string, unknown> };

/** Runs scene-tools.js against a page whose window.liveScene is `liveScene`. With no document given there is no body, so no panel is drawn. */
function loadSceneTools(
  liveScene: Record<string, unknown>,
  fakeDocument: Record<string, unknown> = { body: null, querySelectorAll: () => [] },
  timers: { setTimeout?: (callback: () => void, milliseconds: number) => unknown; setInterval?: (callback: () => void, milliseconds: number) => unknown } = {},
) {
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
    timers.setInterval ?? (() => 0),
    () => {},
    timers.setTimeout ?? (() => 0),
  );
  const clickyTools = fakeWindow.clickyTools as {
    list: () => ToolDescriptor[];
    call: (name: string, input: unknown) => ToolCallResult;
    state: () => Record<string, unknown>;
    simulation: { guessHeard: () => boolean; startChallenge: () => string | null; showQuestion: (questionText: string) => void };
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
  pastRuns: Array<{ trial: number; controls: Array<{ label: string; value: number; unit: string }>; readouts: unknown[] }>;
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

  it("describes each control to the model with its range, and leaves its current value to the state", () => {
    const setControlTool = loadSceneTools(simulationPage()).clickyTools.list().find((tool) => tool.name === "set_control");

    expect(setControlTool?.description).toContain("angle (Launch angle, 5 to 85 degrees)");
    // The current value lives in the state, so a slider move never changes the tool list the Worker caches.
    expect(setControlTool?.description).not.toContain("45");
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
      pastRuns: [{ trial: 1, controls: [{ label: "Launch angle", value: 45, unit: "degrees" }], readouts: [{ label: "Landing distance", value: 40.8, unit: "m" }] }],
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

  it("keeps the last 5 trials, newest first, numbered, with the controls each one started with", async () => {
    const { clickyTools, postedEvents } = loadGuessedSimulation();

    for (const angle of [20, 30, 40, 50, 60, 70]) {
      clickyTools.call("set_control", { name: "angle", value: angle });
      await finishARun(clickyTools, postedEvents);
    }

    const pastRuns = runReport(postedEvents.at(-1)).pastRuns;
    expect(pastRuns.map((pastRun) => pastRun.controls[0]?.value)).toEqual([70, 60, 50, 40, 30]);
    expect(pastRuns.map((pastRun) => pastRun.trial)).toEqual([6, 5, 4, 3, 2]);
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

  it("does not count a run that started before the challenge as a challenge try", async () => {
    let finishTheRun: () => void = () => {};
    const { clickyTools, postedEvents } = loadGuessedSimulation({
      challenge: rangeChallenge,
      run: vi.fn(() => new Promise<void>((resolve) => (finishTheRun = resolve))),
    });

    clickyTools.call("run_simulation", {});
    clickyTools.simulation.startChallenge();
    finishTheRun();
    await vi.waitFor(() => expect(postedEvents).toHaveLength(1));

    expect(runReport(postedEvents[0]).challenge).toBeNull();
    expect(clickyTools.state()).toMatchObject({ challenge: { attempts: 0 } });
  });

  it("adds no trial and reports nothing for a run that fails, since the readouts are the run before's", async () => {
    const { clickyTools, postedEvents } = loadGuessedSimulation({ run: vi.fn(() => Promise.reject(new Error("page broke"))) });
    vi.spyOn(console, "error").mockImplementation(() => {});

    clickyTools.call("run_simulation", {});
    await vi.waitFor(() => expect(clickyTools.state().runIsGoing).toBe(false));

    expect(postedEvents).toEqual([]);
    expect(clickyTools.state().pastRuns).toEqual([]);
  });

  it("sets a control by the cut name the model saw, and passes the page its real name", () => {
    const longName = "angle_of_the_launcher_measured_from_the_ground_in_degrees";
    const page = simulationPage({ controls: [{ ...angleControl, name: longName }] });
    page.setControl = vi.fn((name: string) => name === longName);
    const { clickyTools } = loadSceneTools(page);
    const nameTheModelSaw = longName.slice(0, 40);

    expect(clickyTools.call("set_control", { name: nameTheModelSaw, value: 30 }).ok).toBe(true);
    expect(page.setControl).toHaveBeenLastCalledWith(longName, 30);

    const refused = clickyTools.call("set_control", { name: "mass", value: 3 });
    expect(refused.error).toContain(nameTheModelSaw);
    expect(refused.error).not.toContain(longName);
  });

  it("has the panel's slider hand the page a long control's real name", () => {
    const longName = "angle_of_the_launcher_measured_from_the_ground_in_degrees";
    const inputHandlers: Array<{ element: Record<string, unknown>; handler: () => void }> = [];
    const fakeDocument = {
      body: {},
      documentElement: { append: () => {} },
      createElement: () => {
        const element: Record<string, unknown> = { style: {}, offsetHeight: 60, append: () => {}, replaceChildren: () => {} };
        element.addEventListener = (eventName: string, handler: () => void) => {
          if (eventName === "input") inputHandlers.push({ element, handler });
        };
        return element;
      },
      querySelectorAll: () => [],
    };
    const page = simulationPage({ controls: [{ ...angleControl, name: longName }] });
    page.setControl = vi.fn((name: string) => name === longName);
    const { clickyTools } = loadSceneTools(page, fakeDocument);
    // Any tool call draws the panel, as the end of the tour does in the app.
    clickyTools.call("rotate_model", { yawDegrees: 0 });

    const slider = inputHandlers[0];
    expect(slider).toBeDefined();
    if (!slider) return;
    slider.element.value = "30";
    slider.handler();

    expect(page.setControl).toHaveBeenLastCalledWith(longName, 30);
  });

  it("cuts a control's page text short before it reaches the model or the panel", () => {
    const { clickyTools } = loadSceneTools(simulationPage({
      controls: [{ name: "angle", label: "A".repeat(90), min: 5, max: 85, step: 1, value: 45, unit: "u".repeat(40) }],
    }));

    const [control] = clickyTools.state().controls as Array<{ label: string; unit: string }>;
    expect(control?.label).toHaveLength(40);
    expect(control?.unit).toHaveLength(16);
  });

  it("refuses a challenge with no real target or tolerance", () => {
    for (const challenge of [{ ...rangeChallenge, target: "far" }, { ...rangeChallenge, tolerance: 0 }, { ...rangeChallenge, prompt: " " }, "land it"]) {
      const { clickyTools } = loadGuessedSimulation({ challenge });
      expect(clickyTools.simulation.startChallenge()).toBeNull();
    }
  });

  it("declines a challenge about a readout the page does not report, so it never scores the wrong readout", () => {
    const { clickyTools } = loadGuessedSimulation({
      challenge: { ...rangeChallenge, readoutLabel: "Impact speed" },
      getState: () => ({ readouts: [{ label: "Landing distance", value: 40.8, unit: "m" }] }),
    });

    expect(clickyTools.simulation.startChallenge()).toBeNull();
    expect(clickyTools.state()).toMatchObject({ lessonStage: "explore", challenge: null });
  });

  it("reports no challenge outcome for a try whose readout the page stopped reporting", async () => {
    let readouts = [{ label: "Landing distance", value: 40.8, unit: "m" }];
    const { clickyTools, postedEvents } = loadGuessedSimulation({ challenge: rangeChallenge, getState: () => ({ readouts }) });
    await finishARun(clickyTools, postedEvents);
    clickyTools.simulation.startChallenge();

    readouts = [{ label: "Flight time", value: 2, unit: "s" }];
    const report = await finishARun(clickyTools, postedEvents);

    expect(report.challenge).toBeNull();
    expect(clickyTools.state()).toMatchObject({ challenge: { attempts: 0, hit: false } });
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

  it("abandons a run in flight when set_control changes a control, so its end adds no trial", async () => {
    let finishTheRun: () => void = () => {};
    const { clickyTools, postedEvents } = loadGuessedSimulation({ run: vi.fn(() => new Promise<void>((resolve) => (finishTheRun = resolve))) });

    clickyTools.call("run_simulation", {});
    expect(clickyTools.state().runIsGoing).toBe(true);
    expect(clickyTools.call("set_control", { name: "angle", value: 30 }).state.runIsGoing).toBe(false);
    finishTheRun();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(postedEvents).toEqual([]);
    expect(clickyTools.state().pastRuns).toEqual([]);
  });

  it("keeps a run going when set_control refuses an unknown control name", () => {
    const { clickyTools } = loadGuessedSimulation({ run: vi.fn(() => new Promise<void>(() => {})) });

    clickyTools.call("run_simulation", {});

    expect(clickyTools.call("set_control", { name: "mass", value: 3 }).state.runIsGoing).toBe(true);
  });

  it("abandons a run in flight when the learner drags a slider, so its end adds no trial", async () => {
    const inputHandlers: Array<{ element: Record<string, unknown>; handler: () => void }> = [];
    const fakeDocument = {
      body: {},
      documentElement: { append: () => {} },
      createElement: () => {
        const element: Record<string, unknown> = { style: {}, offsetHeight: 60, append: () => {}, replaceChildren: () => {} };
        element.addEventListener = (eventName: string, handler: () => void) => {
          if (eventName === "input") inputHandlers.push({ element, handler });
        };
        return element;
      },
      querySelectorAll: () => [],
    };
    let finishTheRun: () => void = () => {};
    const page = simulationPage({ run: vi.fn(() => new Promise<void>((resolve) => (finishTheRun = resolve))) });
    const { clickyTools, postedEvents } = loadSceneTools(page, fakeDocument);
    clickyTools.simulation.guessHeard();
    clickyTools.call("run_simulation", {});
    const slider = inputHandlers[0];
    expect(slider).toBeDefined();
    if (!slider) return;

    slider.element.value = "30";
    slider.handler();
    expect(clickyTools.state().runIsGoing).toBe(false);
    finishTheRun();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(postedEvents).toEqual([]);
    expect(clickyTools.state().pastRuns).toEqual([]);
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

  it("puts the readout that answers the experiment in the trials table, not a fixed control sample", async () => {
    /** Runs one trial per pair of times on a page whose first readout is a control beaker, and returns the table's measurement column, header first. */
    const measurementColumnAfterTrials = async (challenge: unknown, coolTimes: number[], warmTimes: number[]) => {
      const createdElements: Array<Record<string, unknown>> = [];
      const fakeDocument = {
        body: {},
        documentElement: { append: () => {} },
        createElement: () => {
          const element: Record<string, unknown> = { style: {}, offsetHeight: 60, append: () => {}, replaceChildren: () => {}, addEventListener: () => {} };
          createdElements.push(element);
          return element;
        },
        querySelectorAll: () => [],
      };
      let trialsRun = 0;
      const page = simulationPage({
        challenge,
        run: vi.fn(() => {
          trialsRun += 1;
          return Promise.resolve();
        }),
        getState: () => ({
          readouts: [
            { label: "Cool sample dissolving time", value: coolTimes[Math.max(0, trialsRun - 1)], unit: "s" },
            { label: "Warm sample dissolving time", value: warmTimes[Math.max(0, trialsRun - 1)], unit: "s" },
          ],
        }),
      });
      const { clickyTools, postedEvents } = loadSceneTools(page, fakeDocument);
      clickyTools.simulation.guessHeard();
      for (let trial = 0; trial < warmTimes.length; trial += 1) await finishARun(clickyTools, postedEvents);
      // The table's cells are the only elements styled with an ellipsis, 3 to a row (trial, control, measurement).
      const tableRowCount = Math.min(warmTimes.length, 5) + 1;
      const tableCells = createdElements.filter((element) => String((element.style as { cssText?: string }).cssText).includes("text-overflow:ellipsis"));
      return tableCells.slice(-tableRowCount * 3).filter((_, cellIndex) => cellIndex % 3 === 2).map((element) => element.textContent);
    };

    // With no challenge, the control beaker's time never changes, so the table shows the time that does.
    expect(await measurementColumnAfterTrials(undefined, [120, 120], [120, 30])).toEqual(["Warm sample dissolving time", "120 s", "30 s"]);
    // The challenge's readout wins even when another readout changes too.
    const challenge = { prompt: "Can you make the warm sample dissolve in 15 seconds?", readoutLabel: " warm sample dissolving time", target: 15, tolerance: 0.5 };
    expect(await measurementColumnAfterTrials(challenge, [120, 100], [120, 30])).toEqual(["Warm sample dissolving time", "120 s", "30 s"]);
    // When nothing has changed yet, the first readout fills the column.
    expect(await measurementColumnAfterTrials(undefined, [120, 120], [30, 30])).toEqual(["Cool sample dissolving time", "120 s", "120 s"]);
    // Once a readout has changed, it keeps the column after 5 runs at one setting push that change out of the table.
    expect(await measurementColumnAfterTrials(undefined, Array(7).fill(120), [120, 30, 30, 30, 30, 30, 30])).toEqual(["Warm sample dissolving time", "30 s", "30 s", "30 s", "30 s", "30 s"]);
    // A cool time that never ends is dropped, which moves the warm time first, so each trial finds the column by its label.
    expect(await measurementColumnAfterTrials(undefined, [Infinity, 120, Infinity], [120, 30, 60])).toEqual(["Warm sample dissolving time", "120 s", "30 s", "60 s"]);
  });

  it("shows each readout's value as an ellipsis while a run plays, since the values are still the run before's", async () => {
    const createdElements: Array<Record<string, unknown>> = [];
    const fakeDocument = {
      body: {},
      documentElement: { append: () => {} },
      createElement: () => {
        const element: Record<string, unknown> = { style: {}, offsetHeight: 60, append: () => {}, replaceChildren: () => {}, addEventListener: () => {} };
        createdElements.push(element);
        return element;
      },
      querySelectorAll: () => [],
    };
    let endTheRun = () => {};
    const page = simulationPage({ run: vi.fn(() => new Promise<void>((resolve) => (endTheRun = resolve))) });
    const { clickyTools, postedEvents } = loadSceneTools(page, fakeDocument);
    clickyTools.simulation.guessHeard();
    const latestReadoutValue = () => createdElements.filter((element) => element.textContent === "…" || element.textContent === "40.8 m").at(-1)?.textContent;

    clickyTools.call("run_simulation", {});
    expect(latestReadoutValue()).toBe("…");

    endTheRun();
    await vi.waitFor(() => expect(postedEvents.length).toBeGreaterThan(0));
    expect(latestReadoutValue()).toBe("40.8 m");
  });

  it("shows the hypothesis in the panel while Clicky waits for the guess", () => {
    const createdElements: Array<Record<string, unknown>> = [];
    const fakeDocument = {
      body: {},
      documentElement: { append: () => {} },
      createElement: () => {
        const element: Record<string, unknown> = { style: {}, offsetHeight: 60, append: () => {}, replaceChildren: () => {}, addEventListener: () => {} };
        createdElements.push(element);
        return element;
      },
      querySelectorAll: () => [],
    };
    const { clickyTools } = loadSceneTools(simulationPage(), fakeDocument);
    clickyTools.call("set_control", { name: "angle", value: 30 });

    clickyTools.simulation.showQuestion("Will 30 or 60 degrees send the ball farther?");

    const questionLine = createdElements.find((element) => element.textContent === "Will 30 or 60 degrees send the ball farther?");
    expect(questionLine?.style).toMatchObject({ display: "block" });
    clickyTools.simulation.guessHeard();
    expect(questionLine?.style).toMatchObject({ display: "none" });
  });

  it("draws the panel when the app shows the question, even if the page never set __tourFinished", () => {
    const appendedElements: unknown[] = [];
    const fakeDocument = {
      body: {},
      documentElement: { append: (element: unknown) => appendedElements.push(element) },
      createElement: () => ({ style: {}, offsetHeight: 60, append: () => {}, replaceChildren: () => {}, addEventListener: () => {} }),
      querySelectorAll: () => [],
    };
    const setInterval = vi.fn(() => 0);
    const { clickyTools } = loadSceneTools(simulationPage(), fakeDocument, { setInterval });
    expect(appendedElements).toHaveLength(0);

    clickyTools.simulation.showQuestion("Will 30 or 60 degrees send the ball farther?");

    expect(appendedElements).toHaveLength(1);
    // The page script no longer polls for __tourFinished, so showQuestion is the only way the panel appears after a tour.
    expect(setInterval).not.toHaveBeenCalled();
  });

  it("skips the guess when the learner clicks the locked Run button, and tells the app", () => {
    const clickHandlers: Array<() => void> = [];
    const fakeDocument = {
      body: {},
      documentElement: { append: () => {} },
      createElement: (tagName: string) => ({
        style: {},
        offsetHeight: 60,
        append: () => {},
        replaceChildren: () => {},
        addEventListener: (eventName: string, handler: () => void) => {
          if (tagName === "button" && eventName === "click") clickHandlers.push(handler);
        },
      }),
      querySelectorAll: () => [],
    };
    const page = simulationPage();
    const { clickyTools, postedEvents } = loadSceneTools(page, fakeDocument);
    clickyTools.call("set_control", { name: "angle", value: 30 });
    const clickRun = clickHandlers[0];
    expect(clickRun).toBeDefined();

    clickRun?.();

    expect(postedEvents).toEqual(["guessSkipped"]);
    expect(clickyTools.state().lessonStage).toBe("explore");
    expect(page.run).not.toHaveBeenCalled();
    clickRun?.();
    expect(page.run).toHaveBeenCalledTimes(1);
  });

  it.each([
    { panelHeight: 92, lift: 158 },
    { panelHeight: 340, lift: 178 },
  ])("moves the camera's view up by half the panel's full height from the start, so the scene stays still as rows arrive (panel $panelHeight)", ({ panelHeight, lift }) => {
    const fakeElement = (): Record<string, unknown> => ({
      style: {},
      offsetHeight: panelHeight,
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

    // Reduce Motion is on in this harness, so the lift jumps straight to half of the full-table height, 300, or of a
    // taller panel, plus its 16 point margin.
    expect(setViewOffset).toHaveBeenLastCalledWith(800, 450, 0, lift, 800, 450);
  });
});
