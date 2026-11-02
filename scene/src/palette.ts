import { Vector3 } from "three";

// sRGB hex, compared in gamma space by the quantize pass. Copied from the
// birthday dither palette. One art pixel is 2 CSS pixels so the organs stay
// readable. The source pipeline used 3.
export const virtualPixelCssSize = 2;

const paletteHexColors = [
  "#f0ece1",
  "#c9c2b2",
  "#978f7e",
  "#665f51",
  "#3b362c",
  "#fff6d8",
  "#f5d78a",
  "#e0aa4e",
  "#a97a35",
  "#6e4d20",
  "#f0a071",
  "#d1521f",
  "#93330f",
  "#571d07",
  "#ffcf99",
  "#f97316",
  "#c2410c",
  "#7a2c06",
  "#b8d7f0",
  "#5f9fdf",
  "#2f66b8",
  "#1b3d7a",
  "#101f47",
  "#d8f0ec",
  "#8fd0c6",
  "#4f9e96",
  "#2b6660",
  "#a7c957",
  "#6a994e",
  "#386641",
  "#ffffff",
];

export const paletteSize = paletteHexColors.length;

function srgbHexToUnitVector(hexColor: string): Vector3 {
  const rgbInteger = Number.parseInt(hexColor.slice(1), 16);
  const red = ((rgbInteger >> 16) & 255) / 255;
  const green = ((rgbInteger >> 8) & 255) / 255;
  const blue = (rgbInteger & 255) / 255;
  return new Vector3(red, green, blue);
}

export const paletteVectors = paletteHexColors.map(srgbHexToUnitVector);
