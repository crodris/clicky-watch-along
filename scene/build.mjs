import * as esbuild from "esbuild";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const sceneDirectory = dirname(fileURLToPath(import.meta.url));
const cssText = readFileSync(resolve(sceneDirectory, "src/scene.css"), "utf8");

const buildResult = await esbuild.build({
  absWorkingDir: sceneDirectory,
  entryPoints: ["src/main.ts"],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "es2022",
  write: false,
});

const outputFile = buildResult.outputFiles[0];
if (outputFile === undefined) {
  throw new Error("esbuild did not produce a bundle");
}

const bundledJavaScript = outputFile.text.replaceAll("</script", "<\\/script");
const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Field trip</title>
<style>
${cssText}
</style>
</head>
<body>
<canvas id="field-trip-canvas"></canvas>
<svg id="field-trip-leaders"></svg>
<div id="field-trip-labels"></div>
<script>
${bundledJavaScript}
</script>
</body>
</html>
`;

writeFileSync(
  resolve(sceneDirectory, "../leanring-buddy/FieldTripScene.html"),
  html,
);
