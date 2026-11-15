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

describe("scene-tools.js simulation tools", () => {
  it("lists set_control and run_simulation only when the page has controls, setControl, and run", () => {
    expect(toolNames(loadSceneTools({ rotateBy: () => true, zoomBy: () => true, focusPart: () => false }).clickyTools)).not.toContain("set_control");

    const { clickyTools } = loadSceneTools(simulationPage());
    expect(toolNames(clickyTools)).toEqual(expect.arrayContaining(["set_control", "run_simulation"]));

    expect(toolNames(loadSceneTools(simulationPage({ run: undefined })).clickyTools)).not.toContain("run_simulation");
    expect(toolNames(loadSceneTools(simulationPage({ setControl: undefined })).clickyTools)).not.toContain("set_control");
    expect(toolNames(loadSceneTools(simulationPage({ controls: [] })).clickyTools)).not.toContain("run_simulation");
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
    const page = simulationPage();
    const { clickyTools, postedEvents } = loadSceneTools(page);

    const started = clickyTools.call("run_simulation", {});

    expect(started.ok).toBe(true);
    expect(started.state.runIsGoing).toBe(true);
    expect(page.run).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => expect(postedEvents).toHaveLength(1));
    expect(postedEvents[0]).toBe('runFinished:[{"label":"Landing distance","value":40.8,"unit":"m"}]');
    expect(clickyTools.state().runIsGoing).toBe(false);
  });

  it("ignores the end of a run that a newer run replaced", async () => {
    let finishFirstRun: () => void = () => {};
    const runs = [new Promise<void>((resolve) => (finishFirstRun = resolve)), Promise.resolve()];
    const page = simulationPage({ run: vi.fn(() => runs.shift()) });
    const { clickyTools, postedEvents } = loadSceneTools(page);

    clickyTools.call("run_simulation", {});
    clickyTools.call("run_simulation", {});
    await vi.waitFor(() => expect(postedEvents).toHaveLength(1));
    finishFirstRun();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(postedEvents).toHaveLength(1);
  });

  it("passes on at most 3 short readouts with real numbers, since the page's text is spoken aloud", async () => {
    const longLabel = "x".repeat(80);
    const page = simulationPage({
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
    const { clickyTools, postedEvents } = loadSceneTools(page);

    clickyTools.call("run_simulation", {});
    await vi.waitFor(() => expect(postedEvents).toHaveLength(1));

    const readouts: Array<{ label: string }> = JSON.parse(postedEvents[0]!.slice("runFinished:".length));
    expect(readouts.map((readout) => readout.label)).toEqual(["x".repeat(40), "Two", "Three"]);
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
