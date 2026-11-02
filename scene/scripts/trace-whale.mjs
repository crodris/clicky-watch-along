// Traces the side profile, mouth line, flipper, and dorsal fin out of
// fixtures/blue-whale-size.svg and writes those numbers into fixtures/whale.json.
// Everything else in whale.json is hand-authored and left alone.
// Run with: node scripts/trace-whale.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const fixturesDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "../fixtures");
const svgText = readFileSync(resolve(fixturesDirectory, "blue-whale-size.svg"), "utf8");

const bodyLengthUnits = 16;
const svgWidth = 2332.2947;
const unitsPerSvgPixel = bodyLengthUnits / svgWidth;
const layerTranslate = { x: 798.77305, y: -104.38806 };
const dorsalFinStart = 1560;
const dorsalFinEnd = 1732;
const tailStockEnd = 2126;

// Half widths are estimates from aerial photographs, because the side view cannot show them.
const halfWidthByFraction = [
  [0, 0.2], [0.012, 0.25], [0.03, 0.31], [0.06, 0.38], [0.1, 0.45], [0.14, 0.51],
  [0.18, 0.58], [0.22, 0.67], [0.27, 0.77], [0.32, 0.84], [0.38, 0.87], [0.45, 0.85],
  [0.52, 0.8], [0.59, 0.7], [0.66, 0.58], [0.73, 0.45], [0.79, 0.33], [0.84, 0.24],
  [0.88, 0.17], [0.92, 0.12], [0.95, 0.1], [0.975, 0.09], [0.99, 0.085], [1, 0.08],
];

function pathData(pathId) {
  const pathElement = svgText.match(new RegExp(`<path[^>]*?\\bid="${pathId}"[^>]*?>`));
  if (pathElement === null) throw new Error(`Missing SVG path ${pathId}`);
  const dataAttribute = pathElement[0].match(/\bd="([^"]+)"/);
  if (dataAttribute === null) throw new Error(`Path ${pathId} has no data`);
  return dataAttribute[1];
}

// Handles the m, l, L, c, C, z commands this file uses and flattens each curve.
function flattenPath(data) {
  const tokens = data.match(/[a-zA-Z]|-?\d*\.?\d+(?:e-?\d+)?/g) ?? [];
  const flattenedPoints = [];
  let command = "";
  let tokenIndex = 0;
  let currentX = 0;
  let currentY = 0;
  const readNumber = () => Number(tokens[tokenIndex++]);
  while (tokenIndex < tokens.length) {
    if (/[a-zA-Z]/.test(tokens[tokenIndex])) command = tokens[tokenIndex++];
    if (command === "z") continue;
    const isRelative = command === command.toLowerCase();
    const originX = isRelative ? currentX : 0;
    const originY = isRelative ? currentY : 0;
    if (command.toLowerCase() === "c") {
      const firstX = originX + readNumber();
      const firstY = originY + readNumber();
      const secondX = originX + readNumber();
      const secondY = originY + readNumber();
      const endX = originX + readNumber();
      const endY = originY + readNumber();
      for (let stepIndex = 1; stepIndex <= 24; stepIndex += 1) {
        const progress = stepIndex / 24;
        const remaining = 1 - progress;
        flattenedPoints.push([
          remaining ** 3 * currentX + 3 * remaining ** 2 * progress * firstX +
            3 * remaining * progress ** 2 * secondX + progress ** 3 * endX,
          remaining ** 3 * currentY + 3 * remaining ** 2 * progress * firstY +
            3 * remaining * progress ** 2 * secondY + progress ** 3 * endY,
        ]);
      }
      currentX = endX;
      currentY = endY;
    } else {
      currentX = originX + readNumber();
      currentY = originY + readNumber();
      flattenedPoints.push([currentX, currentY]);
      if (command === "m") command = "l";
    }
  }
  return flattenedPoints.map(([pointX, pointY]) => [
    pointX + layerTranslate.x,
    pointY + layerTranslate.y,
  ]);
}

function valueAtX(sortedPoints, targetX) {
  for (let pointIndex = 1; pointIndex < sortedPoints.length; pointIndex += 1) {
    const [leftX, leftY] = sortedPoints[pointIndex - 1];
    const [rightX, rightY] = sortedPoints[pointIndex];
    if (targetX >= leftX && targetX <= rightX) {
      const span = rightX - leftX;
      return span === 0 ? rightY : leftY + ((rightY - leftY) * (targetX - leftX)) / span;
    }
  }
  throw new Error(`x ${targetX} is outside the traced profile`);
}

function roundTo(value, decimals = 3) {
  return Number(value.toFixed(decimals));
}

// Keeps the outline points that bend the most, so fin tips survive the 24-point limit.
function simplifyOutline(points, targetCount) {
  const keptPoints = [...points];
  while (keptPoints.length > targetCount) {
    let cheapestIndex = 1;
    let cheapestArea = Number.POSITIVE_INFINITY;
    for (let pointIndex = 1; pointIndex < keptPoints.length - 1; pointIndex += 1) {
      const [previousX, previousY] = keptPoints[pointIndex - 1];
      const [pointX, pointY] = keptPoints[pointIndex];
      const [nextX, nextY] = keptPoints[pointIndex + 1];
      const area = Math.abs(
        (pointX - previousX) * (nextY - previousY) - (nextX - previousX) * (pointY - previousY),
      );
      if (area < cheapestArea) {
        cheapestArea = area;
        cheapestIndex = pointIndex;
      }
    }
    keptPoints.splice(cheapestIndex, 1);
  }
  return keptPoints;
}

const outline = flattenPath(pathData("path3981"));
const snoutIndex = outline.reduce(
  (bestIndex, point, pointIndex) => (point[0] < outline[bestIndex][0] ? pointIndex : bestIndex),
  0,
);
const backOutline = outline.slice(0, snoutIndex + 1).reverse();
const bellyOutline = outline.slice(snoutIndex);
const snoutX = backOutline[0][0];
const backWithoutDorsal = backOutline.filter(
  ([pointX]) => pointX <= dorsalFinStart || pointX >= dorsalFinEnd,
);
const dorsalBaseStartY = valueAtX(backOutline, dorsalFinStart);
const dorsalBaseEndY = valueAtX(backOutline, dorsalFinEnd);
const mouthLine = flattenPath(pathData("path3984")).sort((left, right) => left[0] - right[0]);
const verticalOrigin = valueAtX(mouthLine, 300);

const toBodyX = (svgX) => (svgX - snoutX) * unitsPerSvgPixel - bodyLengthUnits / 2;
const toBodyY = (svgY) => (verticalOrigin - svgY) * unitsPerSvgPixel;

function smoothStep(edgeStart, edgeEnd, value) {
  const progress = Math.min(1, Math.max(0, (value - edgeStart) / (edgeEnd - edgeStart)));
  return progress * progress * (3 - 2 * progress);
}

function bodyStationAt(svgX, fraction, halfWidth) {
  const backY = valueAtX(backWithoutDorsal, svgX);
  const bellyY = valueAtX(bellyOutline, svgX);
  // The axis follows the lip on the head, so the widest line of the egg section
  // is the mouth. Further back it settles just under the middle of the body.
  const midBodyAxis = bellyY + (backY - bellyY) * 0.54;
  const lipAxis = valueAtX(mouthLine, Math.min(Math.max(svgX, mouthLine[0][0]), 320));
  const lipBlend = smoothStep(0.14, 0.3, fraction);
  const axisY = lipAxis + (midBodyAxis - lipAxis) * lipBlend;
  // In the side view the tail stock runs straight into the flukes. Thinning it
  // here lets it slip inside the fluke instead of ending in a visible bulb.
  const tailStockTaper = 1 - 0.62 * smoothStep(0.88, 1, fraction);
  return {
    x: roundTo(toBodyX(svgX)),
    y: roundTo(toBodyY(axisY)),
    top: roundTo(Math.max(0.03, (axisY - backY) * unitsPerSvgPixel * tailStockTaper)),
    bottom: roundTo(Math.max(0.03, (bellyY - axisY) * unitsPerSvgPixel * tailStockTaper)),
    width: halfWidth,
  };
}

// Stations start a few pixels back from the very tip, because the loft rounds its own ends.
const profileStart = snoutX + 8;
const stations = halfWidthByFraction.map(([fraction, halfWidth]) =>
  bodyStationAt(profileStart + (tailStockEnd - profileStart) * fraction, fraction, halfWidth),
);

function interpolateStationField(bodyX, fieldName) {
  for (let stationIndex = 1; stationIndex < stations.length; stationIndex += 1) {
    const leftStation = stations[stationIndex - 1];
    const rightStation = stations[stationIndex];
    if (bodyX <= rightStation.x) {
      const progress = (bodyX - leftStation.x) / (rightStation.x - leftStation.x);
      return leftStation[fieldName] + (rightStation[fieldName] - leftStation[fieldName]) * progress;
    }
  }
  return stations[stations.length - 1][fieldName];
}

function aroundDegreesForSidePoint(bodyX, bodyY) {
  const axisY = interpolateStationField(bodyX, "y");
  const offset = bodyY - axisY;
  const reach = interpolateStationField(bodyX, offset >= 0 ? "top" : "bottom");
  const cosine = Math.min(1, Math.max(-1, offset / reach));
  return (Math.acos(cosine) * 180) / Math.PI;
}

const mouthPath = simplifyOutline(mouthLine, 16)
  .filter(([svgX]) => svgX > snoutX + 16)
  .map(([svgX, svgY]) => [
    roundTo(toBodyX(svgX)),
    roundTo(aroundDegreesForSidePoint(toBodyX(svgX), toBodyY(svgY)), 1),
  ]);

function finPlacement(svgPoints, targetCount) {
  const rootX = (svgPoints[0][0] + svgPoints[svgPoints.length - 1][0]) / 2;
  const rootY = (svgPoints[0][1] + svgPoints[svgPoints.length - 1][1]) / 2;
  return {
    position: [roundTo(toBodyX(rootX)), roundTo(toBodyY(rootY))],
    outline: simplifyOutline(svgPoints, targetCount).map(([svgX, svgY]) => [
      roundTo((svgX - rootX) * unitsPerSvgPixel),
      roundTo((rootY - svgY) * unitsPerSvgPixel),
    ]),
  };
}

// The lower lip is a low ridge just under the mouth line.
const lipRidgePath = mouthPath.map(([bodyX, aroundDegrees]) => [
  bodyX,
  roundTo(aroundDegrees + 6, 1),
]);

const eyeMatrix = { scale: 4.1626224, offsetX: -1791.4692, offsetY: -280.34465 };
const eyeSvgX = -354.56354 * -eyeMatrix.scale + eyeMatrix.offsetX + layerTranslate.x;
const eyeSvgY = 146.44475 * eyeMatrix.scale + eyeMatrix.offsetY + layerTranslate.y;
const eyeBodyX = toBodyX(eyeSvgX);
const eyeBodyY = toBodyY(eyeSvgY);
const eyeAroundDegrees = aroundDegreesForSidePoint(eyeBodyX, eyeBodyY);
const eyeSurfaceZ =
  interpolateStationField(eyeBodyX, "width") * Math.sin((eyeAroundDegrees * Math.PI) / 180);

// The eyelid folds are two shallow arcs, written as [x, around] points. Smaller
// angles are higher on the body, so the upper lid has the smaller angles.
const eyelidArc = (arcSign) =>
  [-0.11, -0.055, 0, 0.055, 0.11].map((offsetX) => [
    roundTo(eyeBodyX + offsetX),
    roundTo(
      eyeAroundDegrees + arcSign * 5.5 * (1 - (offsetX / 0.11) ** 2) + (offsetX > 0 ? 1 : 0),
      1,
    ),
  ]);

const flipper = finPlacement(flattenPath(pathData("path3988")), 22);
const dorsalFinPoints = backOutline.filter(
  ([pointX]) => pointX >= dorsalFinStart && pointX <= dorsalFinEnd,
);
// The base sinks below the back line so the fin grows out of the skin.
const dorsalFin = finPlacement(
  [
    [dorsalFinStart, dorsalBaseStartY + 34],
    ...dorsalFinPoints,
    [dorsalFinEnd, dorsalBaseEndY + 34],
  ],
  18,
);

const whale = JSON.parse(readFileSync(resolve(fixturesDirectory, "whale.json"), "utf8"));
function partById(partId) {
  const foundPart = whale.parts.find((part) => part.id === partId);
  if (foundPart === undefined) throw new Error(`whale.json has no part ${partId}`);
  return foundPart;
}

const bodyPart = partById("body");
bodyPart.stations = stations;
bodyPart.creases[0].path = mouthPath;
bodyPart.creases[1].path = lipRidgePath;
bodyPart.creases[4].path = eyelidArc(-1);
bodyPart.creases[5].path = eyelidArc(1);
bodyPart.bumps[0].x = roundTo(eyeBodyX);
bodyPart.bumps[0].around = roundTo(eyeAroundDegrees, 1);
partById("eye").position = [roundTo(eyeBodyX), roundTo(eyeBodyY), roundTo(eyeSurfaceZ + 0.018)];
const flipperPart = partById("flipper");
flipperPart.outline = flipper.outline;
flipperPart.position[0] = flipper.position[0];
flipperPart.position[1] = flipper.position[1];
const dorsalPart = partById("dorsal-fin");
dorsalPart.outline = dorsalFin.outline;
dorsalPart.position[0] = dorsalFin.position[0];
dorsalPart.position[1] = dorsalFin.position[1];

writeFileSync(resolve(fixturesDirectory, "whale.json"), `${JSON.stringify(whale, null, 2)}\n`);
console.log(
  `Wrote ${stations.length} stations, ${mouthPath.length} mouth points, ` +
    `flipper ${flipper.outline.length} points, dorsal fin ${dorsalFin.outline.length} points.`,
);
