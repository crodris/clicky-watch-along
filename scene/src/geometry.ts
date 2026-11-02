import {
  BufferAttribute,
  BufferGeometry,
  CatmullRomCurve3,
  type Euler,
  Vector2,
  Vector3,
} from "three";
import type { FinPart, LoftPart, TubePart } from "./spec";

// Every generated surface carries this vec4 so the surface shader has stable
// coordinates: fraction along the part, belly amount from 0 on top to 1 on the
// belly, angle around the body in radians folded to 0..pi, and cavity depth.
export const surfaceCoordinateAttribute = "surfaceCoordinate";

// Mesh density follows the size of the part, so a small organ does not carry a
// whale's vertex count. The ceilings are what a mouth line needs on a whale.
const loftRingsPerUnit = 52;
const loftSegmentsPerUnit = 57;
const loftMinimumResolution = 96;
const loftMaximumRings = 760;
const loftMaximumSegments = 320;
const loftCapRingCount = 14;
// A crease this deep reads as a full shadow. Shallower ones shade less.
const fullCavityDepth = 0.034;
const finOutlineSampleCount = 420;
const finRingCount = 14;
const tubeRingsPerUnit = 90;
const tubeRadialSegments = 20;
const tubeCapRingCount = 6;

// Fritsch-Carlson monotone cubic. A plain spline overshoots near the snout and
// tail, where stations bunch up and the values fall quickly.
function monotoneCubic(
  knotPositions: number[],
  knotValues: number[],
): (position: number) => number {
  const knotCount = knotPositions.length;
  const intervalLengths: number[] = [];
  const secants: number[] = [];
  for (let knotIndex = 0; knotIndex < knotCount - 1; knotIndex += 1) {
    const intervalLength = knotPositions[knotIndex + 1] - knotPositions[knotIndex];
    intervalLengths.push(intervalLength);
    secants.push((knotValues[knotIndex + 1] - knotValues[knotIndex]) / intervalLength);
  }
  const tangents: number[] = [secants[0]];
  for (let knotIndex = 1; knotIndex < knotCount - 1; knotIndex += 1) {
    const secantBefore = secants[knotIndex - 1];
    const secantAfter = secants[knotIndex];
    if (secantBefore * secantAfter <= 0) {
      tangents.push(0);
      continue;
    }
    const weightBefore = 2 * intervalLengths[knotIndex] + intervalLengths[knotIndex - 1];
    const weightAfter = intervalLengths[knotIndex] + 2 * intervalLengths[knotIndex - 1];
    tangents.push(
      (weightBefore + weightAfter) / (weightBefore / secantBefore + weightAfter / secantAfter),
    );
  }
  tangents.push(secants[knotCount - 2]);

  return (position: number) => {
    let intervalIndex = 0;
    while (
      intervalIndex < knotCount - 2 &&
      position > knotPositions[intervalIndex + 1]
    ) {
      intervalIndex += 1;
    }
    const intervalLength = intervalLengths[intervalIndex];
    const progress = Math.min(
      1,
      Math.max(0, (position - knotPositions[intervalIndex]) / intervalLength),
    );
    const progressSquared = progress * progress;
    const progressCubed = progressSquared * progress;
    return (
      (2 * progressCubed - 3 * progressSquared + 1) * knotValues[intervalIndex] +
      (progressCubed - 2 * progressSquared + progress) * intervalLength * tangents[intervalIndex] +
      (-2 * progressCubed + 3 * progressSquared) * knotValues[intervalIndex + 1] +
      (progressCubed - progressSquared) * intervalLength * tangents[intervalIndex + 1]
    );
  };
}

function gaussian(distance: number, spread: number): number {
  return Math.exp((-distance * distance) / (2 * spread * spread));
}

function distanceToSegment(
  pointX: number,
  pointY: number,
  startX: number,
  startY: number,
  endX: number,
  endY: number,
): number {
  const deltaX = endX - startX;
  const deltaY = endY - startY;
  const lengthSquared = deltaX * deltaX + deltaY * deltaY;
  const projection =
    lengthSquared === 0
      ? 0
      : Math.min(
          1,
          Math.max(0, ((pointX - startX) * deltaX + (pointY - startY) * deltaY) / lengthSquared),
        );
  return Math.hypot(pointX - startX - projection * deltaX, pointY - startY - projection * deltaY);
}

type LoftRing = { axialPosition: number; sectionScale: number };
type LoftStation = LoftPart["stations"][number];

// An ellipse is joined part way along its curve, so the cap leaves the body at
// the slope the body already has. Joining at the ellipse's flat crown would
// leave a shoulder wherever the body is still tapering.
const capJoinPosition = 0.5;

function capLengthBeyond(endStation: LoftStation, neighborStation: LoftStation): number {
  const stationGap = Math.max(1e-4, Math.abs(endStation.x - neighborStation.x));
  const sectionChannels = [
    [endStation.top, neighborStation.top],
    [endStation.bottom, neighborStation.bottom],
    [endStation.width, neighborStation.width],
  ];
  const meanRelativeSlope =
    sectionChannels.reduce(
      (total, [endValue, neighborValue]) =>
        total + Math.abs(neighborValue - endValue) / Math.max(1e-4, endValue) / stationGap,
      0,
    ) / sectionChannels.length;
  const largestEndRadius = Math.max(endStation.top, endStation.bottom, endStation.width);
  const fullEllipseLength =
    capJoinPosition /
    ((1 - capJoinPosition * capJoinPosition) * Math.max(meanRelativeSlope, 0.01));
  return Math.min(fullEllipseLength * (1 - capJoinPosition), largestEndRadius * 1.5);
}

function capSectionScale(capProgress: number): number {
  const ellipsePosition = capJoinPosition + (1 - capJoinPosition) * capProgress;
  return (
    Math.sqrt(Math.max(1e-5, 1 - ellipsePosition * ellipsePosition)) /
    Math.sqrt(1 - capJoinPosition * capJoinPosition)
  );
}

// More rings on the front half, where the mouth line and pleats need them.
function loftRings(
  firstX: number,
  lastX: number,
  capLengths: [number, number],
  mainRingCount: number,
): LoftRing[] {
  const rings: LoftRing[] = [];
  for (let capRingIndex = loftCapRingCount; capRingIndex > 0; capRingIndex -= 1) {
    const capProgress = capRingIndex / loftCapRingCount;
    rings.push({
      axialPosition: firstX - capLengths[0] * capProgress,
      sectionScale: capSectionScale(capProgress),
    });
  }
  for (let ringIndex = 0; ringIndex < mainRingCount; ringIndex += 1) {
    const progress = ringIndex / (mainRingCount - 1);
    const frontWeightedProgress = 0.62 * progress * progress + 0.38 * progress;
    rings.push({
      axialPosition: firstX + (lastX - firstX) * frontWeightedProgress,
      sectionScale: 1,
    });
  }
  for (let capRingIndex = 1; capRingIndex <= loftCapRingCount; capRingIndex += 1) {
    const capProgress = capRingIndex / loftCapRingCount;
    rings.push({
      axialPosition: lastX + capLengths[1] * capProgress,
      sectionScale: capSectionScale(capProgress),
    });
  }
  return rings;
}

function gridTriangleIndices(ringCount: number, segmentCount: number): Uint32Array {
  const indices = new Uint32Array((ringCount - 1) * segmentCount * 6);
  let writeIndex = 0;
  for (let ringIndex = 0; ringIndex < ringCount - 1; ringIndex += 1) {
    for (let segmentIndex = 0; segmentIndex < segmentCount; segmentIndex += 1) {
      const nextSegmentIndex = (segmentIndex + 1) % segmentCount;
      const cornerA = ringIndex * segmentCount + segmentIndex;
      const cornerB = ringIndex * segmentCount + nextSegmentIndex;
      const cornerC = (ringIndex + 1) * segmentCount + segmentIndex;
      const cornerD = (ringIndex + 1) * segmentCount + nextSegmentIndex;
      indices[writeIndex++] = cornerA;
      indices[writeIndex++] = cornerB;
      indices[writeIndex++] = cornerC;
      indices[writeIndex++] = cornerB;
      indices[writeIndex++] = cornerD;
      indices[writeIndex++] = cornerC;
    }
  }
  return indices;
}

function clampedResolution(wanted: number, maximum: number): number {
  return Math.min(maximum, Math.max(loftMinimumResolution, Math.round(wanted)));
}

// resolutionScale below 1 suits a surface with no fine detail of its own.
export function createLoftGeometry(loftPart: LoftPart, resolutionScale = 1): BufferGeometry {
  const stations = loftPart.stations;
  const stationPositions = stations.map((station) => station.x);
  const axisHeightAt = monotoneCubic(stationPositions, stations.map((station) => station.y));
  const topAt = monotoneCubic(stationPositions, stations.map((station) => station.top));
  const bottomAt = monotoneCubic(stationPositions, stations.map((station) => station.bottom));
  const widthAt = monotoneCubic(stationPositions, stations.map((station) => station.width));

  const firstStation = stations[0];
  const lastStation = stations[stations.length - 1];
  const firstX = firstStation.x;
  const lastX = lastStation.x;
  const bodyLength = lastX - firstX;
  const largestRadius = stations.reduce(
    (largest, station) => Math.max(largest, station.top, station.bottom, station.width),
    0,
  );
  const mainRingCount = clampedResolution(
    bodyLength * loftRingsPerUnit * resolutionScale,
    loftMaximumRings,
  );
  const segmentCount = clampedResolution(
    Math.PI * 2 * largestRadius * loftSegmentsPerUnit * resolutionScale,
    loftMaximumSegments,
  );
  const rings = loftRings(
    firstX,
    lastX,
    [
      capLengthBeyond(firstStation, stations[1]),
      capLengthBeyond(lastStation, stations[stations.length - 2]),
    ],
    mainRingCount,
  );
  const ringCount = rings.length;
  const vertexCount = ringCount * segmentCount;
  const positions = new Float32Array(vertexCount * 3);
  const surfaceCoordinates = new Float32Array(vertexCount * 4);

  rings.forEach((ring, ringIndex) => {
    const clampedX = Math.min(lastX, Math.max(firstX, ring.axialPosition));
    const axisHeight = axisHeightAt(clampedX);
    const top = topAt(clampedX) * ring.sectionScale;
    const bottom = bottomAt(clampedX) * ring.sectionScale;
    const width = widthAt(clampedX) * ring.sectionScale;
    for (let segmentIndex = 0; segmentIndex < segmentCount; segmentIndex += 1) {
      // Zero is the top line, so the seam never needs to appear in the angle.
      const aroundAngle = (segmentIndex / segmentCount) * Math.PI * 2;
      const cosine = Math.cos(aroundAngle);
      const sine = Math.sin(aroundAngle);
      const vertexIndex = ringIndex * segmentCount + segmentIndex;
      positions[vertexIndex * 3] = ring.axialPosition;
      positions[vertexIndex * 3 + 1] = axisHeight + (cosine >= 0 ? top : bottom) * cosine;
      positions[vertexIndex * 3 + 2] = width * sine;
      surfaceCoordinates[vertexIndex * 4] = (ring.axialPosition - firstX) / bodyLength;
      surfaceCoordinates[vertexIndex * 4 + 1] = (1 - cosine) / 2;
      surfaceCoordinates[vertexIndex * 4 + 2] = Math.acos(cosine);
    }
  });

  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new BufferAttribute(positions, 3));
  geometry.setAttribute(surfaceCoordinateAttribute, new BufferAttribute(surfaceCoordinates, 4));
  geometry.setIndex(new BufferAttribute(gridTriangleIndices(ringCount, segmentCount), 1));
  geometry.computeVertexNormals();

  const normals = geometry.getAttribute("normal");
  // The crease test is the most expensive step here, and most rings are nowhere
  // near a crease.
  const creasesWithReach = loftPart.creases.map((crease) => ({
    ...crease,
    firstX: Math.min(...crease.path.map(([pathX]) => pathX)),
    lastX: Math.max(...crease.path.map(([pathX]) => pathX)),
    reach: crease.width * 6,
  }));
  rings.forEach((ring, ringIndex) => {
    const clampedX = Math.min(lastX, Math.max(firstX, ring.axialPosition));
    const meanRadius =
      (topAt(clampedX) + bottomAt(clampedX) + 2 * widthAt(clampedX)) / 4;
    for (let segmentIndex = 0; segmentIndex < segmentCount; segmentIndex += 1) {
      const vertexIndex = ringIndex * segmentCount + segmentIndex;
      const aroundAngle = surfaceCoordinates[vertexIndex * 4 + 2];
      let displacement = 0;
      let cavity = 0;
      for (const crease of creasesWithReach) {
        if (
          ring.axialPosition < crease.firstX - crease.reach ||
          ring.axialPosition > crease.lastX + crease.reach
        ) {
          continue;
        }
        let nearestDistance = Number.POSITIVE_INFINITY;
        for (let pathIndex = 1; pathIndex < crease.path.length; pathIndex += 1) {
          const [startX, startDegrees] = crease.path[pathIndex - 1];
          const [endX, endDegrees] = crease.path[pathIndex];
          nearestDistance = Math.min(
            nearestDistance,
            distanceToSegment(
              ring.axialPosition,
              aroundAngle * meanRadius,
              startX,
              (startDegrees * Math.PI * meanRadius) / 180,
              endX,
              (endDegrees * Math.PI * meanRadius) / 180,
            ),
          );
        }
        if (nearestDistance < crease.width * 6) {
          const profile = gaussian(nearestDistance, crease.width);
          displacement -= crease.depth * profile;
          if (crease.depth > 0) {
            cavity = Math.max(cavity, profile * Math.min(1, crease.depth / fullCavityDepth));
          }
        }
      }
      for (const bump of loftPart.bumps) {
        const alongDistance = (ring.axialPosition - bump.x) / bump.length;
        const aroundDistance = (aroundAngle - (bump.around * Math.PI) / 180) * meanRadius / bump.span;
        const reachSquared = alongDistance * alongDistance + aroundDistance * aroundDistance;
        if (reachSquared < 16) {
          displacement += bump.height * Math.exp(-reachSquared / 2);
        }
      }
      positions[vertexIndex * 3] += normals.getX(vertexIndex) * displacement;
      positions[vertexIndex * 3 + 1] += normals.getY(vertexIndex) * displacement;
      positions[vertexIndex * 3 + 2] += normals.getZ(vertexIndex) * displacement;
      surfaceCoordinates[vertexIndex * 4 + 3] = cavity;
    }
  });
  geometry.computeVertexNormals();
  geometry.computeBoundingBox();
  return geometry;
}

type OutlineSample = {
  position: Vector2;
  medialCenter: Vector2;
  medialRadius: number;
};

function resampledClosedOutline(outline: FinPart["outline"]): Vector2[] {
  const curve = new CatmullRomCurve3(
    outline.map(([pointX, pointY]) => new Vector3(pointX, pointY, 0)),
    true,
    "centripetal",
  );
  return curve
    .getSpacedPoints(finOutlineSampleCount)
    .slice(0, -1)
    .map((point) => new Vector2(point.x, point.y));
}

function signedArea(polygon: Vector2[]): number {
  let doubledArea = 0;
  polygon.forEach((point, pointIndex) => {
    const next = polygon[(pointIndex + 1) % polygon.length];
    doubledArea += point.x * next.y - next.x * point.y;
  });
  return doubledArea / 2;
}

// Each boundary point gets the largest circle that touches the outline there
// and fits inside it. The circle's center lies on the medial axis, the fin's
// natural spine, so a sharp tip gets a tiny radius and a broad root a large one.
function outlineSamples(polygon: Vector2[]): OutlineSample[] {
  const windingSign = signedArea(polygon) > 0 ? 1 : -1;
  const sampleCount = polygon.length;
  return polygon.map((point, pointIndex) => {
    const previous = polygon[(pointIndex - 1 + sampleCount) % sampleCount];
    const next = polygon[(pointIndex + 1) % sampleCount];
    const tangentX = next.x - previous.x;
    const tangentY = next.y - previous.y;
    const tangentLength = Math.max(1e-6, Math.hypot(tangentX, tangentY));
    const inwardX = (-tangentY / tangentLength) * windingSign;
    const inwardY = (tangentX / tangentLength) * windingSign;
    let medialRadius = Number.POSITIVE_INFINITY;
    for (let otherIndex = 0; otherIndex < sampleCount; otherIndex += 1) {
      const indexDistance = Math.abs(otherIndex - pointIndex);
      if (Math.min(indexDistance, sampleCount - indexDistance) < 2) {
        continue;
      }
      const other = polygon[otherIndex];
      const offsetX = other.x - point.x;
      const offsetY = other.y - point.y;
      const inwardReach = offsetX * inwardX + offsetY * inwardY;
      if (inwardReach > 1e-6) {
        medialRadius = Math.min(
          medialRadius,
          (offsetX * offsetX + offsetY * offsetY) / (2 * inwardReach),
        );
      }
    }
    return {
      position: point,
      medialCenter: new Vector2(
        point.x + inwardX * medialRadius,
        point.y + inwardY * medialRadius,
      ),
      medialRadius,
    };
  });
}

// Inflates the outline into a foil. Rings run from the edge to the medial axis,
// so the silhouette is the outline itself and thickness follows the local width.
// A fin is thick at its root and thins to a soft edge at the tip, instead of the
// flat plateau a beveled extrusion gives.
export function createFinGeometry(finPart: FinPart): BufferGeometry {
  const polygon = resampledClosedOutline(finPart.outline);
  const samples = outlineSamples(polygon);
  const sampleCount = samples.length;
  const largestRadius = samples.reduce(
    (largest, sample) => Math.max(largest, sample.medialRadius),
    0,
  );
  const vertexCount = sampleCount * (1 + 2 * finRingCount);
  const positions = new Float32Array(vertexCount * 3);
  const surfaceCoordinates = new Float32Array(vertexCount * 4);
  const minimumX = polygon.reduce((lowest, point) => Math.min(lowest, point.x), Infinity);
  const maximumX = polygon.reduce((highest, point) => Math.max(highest, point.x), -Infinity);
  const writeVertex = (vertexIndex: number, pointX: number, pointY: number, pointZ: number) => {
    positions[vertexIndex * 3] = pointX;
    positions[vertexIndex * 3 + 1] = pointY;
    positions[vertexIndex * 3 + 2] = pointZ;
    surfaceCoordinates[vertexIndex * 4] = (pointX - minimumX) / (maximumX - minimumX);
  };
  const frontVertexIndex = (ringIndex: number, sampleIndex: number) =>
    ringIndex === 0 ? sampleIndex : sampleCount * ringIndex + sampleIndex;
  const backVertexIndex = (ringIndex: number, sampleIndex: number) =>
    ringIndex === 0 ? sampleIndex : sampleCount * (finRingCount + ringIndex) + sampleIndex;

  samples.forEach((sample, sampleIndex) => {
    writeVertex(sampleIndex, sample.position.x, sample.position.y, 0);
    const peakHalfThickness =
      (finPart.thickness / 2) * (sample.medialRadius / largestRadius) ** 0.8;
    for (let ringIndex = 1; ringIndex <= finRingCount; ringIndex += 1) {
      const inwardProgress = ringIndex / finRingCount;
      // Bunches rings at the edge, where the section curves fastest.
      const ringPosition = 1 - (1 - inwardProgress) ** 2;
      const pointX = sample.position.x + (sample.medialCenter.x - sample.position.x) * ringPosition;
      const pointY = sample.position.y + (sample.medialCenter.y - sample.position.y) * ringPosition;
      const halfThickness =
        peakHalfThickness * Math.sqrt(1 - (1 - ringPosition) * (1 - ringPosition));
      writeVertex(frontVertexIndex(ringIndex, sampleIndex), pointX, pointY, halfThickness);
      writeVertex(backVertexIndex(ringIndex, sampleIndex), pointX, pointY, -halfThickness);
    }
  });

  const indices: number[] = [];
  const windingIsCounterClockwise = signedArea(polygon) > 0;
  for (let ringIndex = 0; ringIndex < finRingCount; ringIndex += 1) {
    for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex += 1) {
      const nextSample = (sampleIndex + 1) % sampleCount;
      const frontOuterA = frontVertexIndex(ringIndex, sampleIndex);
      const frontOuterB = frontVertexIndex(ringIndex, nextSample);
      const frontInnerA = frontVertexIndex(ringIndex + 1, sampleIndex);
      const frontInnerB = frontVertexIndex(ringIndex + 1, nextSample);
      const backOuterA = backVertexIndex(ringIndex, sampleIndex);
      const backOuterB = backVertexIndex(ringIndex, nextSample);
      const backInnerA = backVertexIndex(ringIndex + 1, sampleIndex);
      const backInnerB = backVertexIndex(ringIndex + 1, nextSample);
      if (windingIsCounterClockwise) {
        indices.push(frontOuterA, frontOuterB, frontInnerB, frontOuterA, frontInnerB, frontInnerA);
        indices.push(backOuterA, backInnerB, backOuterB, backOuterA, backInnerA, backInnerB);
      } else {
        indices.push(frontOuterA, frontInnerB, frontOuterB, frontOuterA, frontInnerA, frontInnerB);
        indices.push(backOuterA, backOuterB, backInnerB, backOuterA, backInnerB, backInnerA);
      }
    }
  }

  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new BufferAttribute(positions, 3));
  geometry.setAttribute(surfaceCoordinateAttribute, new BufferAttribute(surfaceCoordinates, 4));
  geometry.setIndex(indices);
  geometry.computeVertexNormals();
  geometry.computeBoundingBox();
  return geometry;
}

// Gives parts with no body axis the coordinates the surface shader expects.
// Belly amount comes from the world normal, so the underside of a flipper is
// pale however the part is rotated.
export function applyWorldSpaceBellyAmount(geometry: BufferGeometry, rotation: Euler): void {
  const normals = geometry.getAttribute("normal");
  const vertexCount = normals.count;
  const existingCoordinates = geometry.getAttribute(surfaceCoordinateAttribute);
  const surfaceCoordinates = new Float32Array(vertexCount * 4);
  const worldNormal = new Vector3();
  for (let vertexIndex = 0; vertexIndex < vertexCount; vertexIndex += 1) {
    worldNormal.fromBufferAttribute(normals, vertexIndex).applyEuler(rotation);
    surfaceCoordinates[vertexIndex * 4] =
      existingCoordinates === undefined ? 0.5 : existingCoordinates.getX(vertexIndex);
    surfaceCoordinates[vertexIndex * 4 + 1] = (1 - worldNormal.y) / 2;
    surfaceCoordinates[vertexIndex * 4 + 3] =
      existingCoordinates === undefined ? 0 : existingCoordinates.getW(vertexIndex);
  }
  geometry.setAttribute(surfaceCoordinateAttribute, new BufferAttribute(surfaceCoordinates, 4));
}

export function createTubeGeometry(tubePart: TubePart): BufferGeometry {
  const points = tubePart.points;
  const curve = new CatmullRomCurve3(
    points.map(([pointX, pointY, pointZ]) => new Vector3(pointX, pointY, pointZ)),
    false,
    "centripetal",
  );
  const pointFractions = points.map((_, pointIndex) => pointIndex / (points.length - 1));
  const radiusAt = monotoneCubic(pointFractions, points.map((point) => point[3]));
  const mainRingCount = Math.max(32, Math.ceil(curve.getLength() * tubeRingsPerUnit));
  const ringFractions: number[] = [];
  const ringScales: number[] = [];
  const capFraction = Math.min(0.2, (points[0][3] * 1.2) / curve.getLength());
  for (let capIndex = 0; capIndex < tubeCapRingCount; capIndex += 1) {
    const capProgress = capIndex / tubeCapRingCount;
    ringFractions.push(capFraction * capProgress);
    ringScales.push(Math.sqrt(Math.max(1e-4, 1 - (1 - capProgress) ** 2)));
  }
  for (let ringIndex = 0; ringIndex <= mainRingCount; ringIndex += 1) {
    ringFractions.push(capFraction + (1 - 2 * capFraction) * (ringIndex / mainRingCount));
    ringScales.push(1);
  }
  for (let capIndex = 1; capIndex <= tubeCapRingCount; capIndex += 1) {
    const capProgress = capIndex / tubeCapRingCount;
    ringFractions.push(1 - capFraction * (1 - capProgress));
    ringScales.push(Math.sqrt(Math.max(1e-4, 1 - capProgress ** 2)));
  }

  const ringCount = ringFractions.length;
  const frames = curve.computeFrenetFrames(ringCount - 1, false);
  const positions = new Float32Array(ringCount * tubeRadialSegments * 3);
  const surfaceCoordinates = new Float32Array(ringCount * tubeRadialSegments * 4);
  const ringCenter = new Vector3();
  ringFractions.forEach((fraction, ringIndex) => {
    curve.getPointAt(fraction, ringCenter);
    const normal = frames.normals[ringIndex];
    const binormal = frames.binormals[ringIndex];
    // Beads are drums with a narrow waist between them, shaded by the cavity
    // channel so each joint reads as a gap instead of a dent.
    const beadWave = Math.abs(Math.sin(fraction * tubePart.beads * Math.PI));
    const jointAmount = tubePart.beads > 0 ? (1 - beadWave) ** 5 : 0;
    const beadRidge = tubePart.beads > 0 ? beadWave ** 2 * 0.1 : 0;
    const radius =
      radiusAt(fraction) * ringScales[ringIndex] * (1 + beadRidge - jointAmount * 0.24);
    for (let segmentIndex = 0; segmentIndex < tubeRadialSegments; segmentIndex += 1) {
      const aroundAngle = (segmentIndex / tubeRadialSegments) * Math.PI * 2;
      const cosine = Math.cos(aroundAngle);
      const sine = Math.sin(aroundAngle);
      const vertexIndex = ringIndex * tubeRadialSegments + segmentIndex;
      positions[vertexIndex * 3] = ringCenter.x + radius * (cosine * normal.x + sine * binormal.x);
      positions[vertexIndex * 3 + 1] = ringCenter.y + radius * (cosine * normal.y + sine * binormal.y);
      positions[vertexIndex * 3 + 2] = ringCenter.z + radius * (cosine * normal.z + sine * binormal.z);
      surfaceCoordinates[vertexIndex * 4] = fraction;
      surfaceCoordinates[vertexIndex * 4 + 3] = jointAmount * 0.8;
    }
  });

  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new BufferAttribute(positions, 3));
  geometry.setAttribute(surfaceCoordinateAttribute, new BufferAttribute(surfaceCoordinates, 4));
  geometry.setIndex(new BufferAttribute(gridTriangleIndices(ringCount, tubeRadialSegments), 1));
  geometry.computeVertexNormals();
  geometry.computeBoundingBox();
  return geometry;
}
