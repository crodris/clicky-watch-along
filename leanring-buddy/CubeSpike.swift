//
//  CubeSpike.swift
//  leanring-buddy
//
//  Throwaway check: a transparent WKWebView inside OverlayWindow, drawing
//  an animated WebGL cube over whatever is behind the window.
//

import AppKit
import WebKit

enum CubeSpike {
    // A local OverlayWindow would be released when this function returns.
    // The spike has no other owner, so this static keeps it on screen.
    private static var retainedOverlayWindow: OverlayWindow?

    static func showSpinningCubeInOverlayWindow() {
        guard let mainScreen = NSScreen.main else {
            print("Cube spike: NSScreen.main was nil")
            return
        }

        let overlayWindow = OverlayWindow(screen: mainScreen)
        retainedOverlayWindow = overlayWindow

        let webView = WKWebView(frame: overlayWindow.contentView?.bounds ?? .zero)
        webView.autoresizingMask = [.width, .height]
        // drawsBackground is a private WKWebView switch. It has to be off or
        // WebKit paints an opaque layer over the desktop.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        overlayWindow.contentView = webView
        webView.loadHTMLString(spinningCubePageHTML, baseURL: nil)
        overlayWindow.orderFrontRegardless()
    }

    private static let spinningCubePageHTML = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html, body {
    margin: 0;
    width: 100%;
    height: 100%;
    overflow: hidden;
    background: rgba(0, 0, 0, 0);
  }
  canvas {
    position: fixed;
    left: 0;
    top: 0;
    width: 100%;
    height: 100%;
    display: block;
    background: rgba(0, 0, 0, 0);
  }
</style>
</head>
<body>
<canvas id="cube"></canvas>
<script>
const floatsPerVertex = 6;
const bytesPerFloat = 4;
const vertexStrideBytes = floatsPerVertex * bytesPerFloat;
const colorByteOffset = 3 * bytesPerFloat;
const fieldOfViewRadians = Math.PI / 4;
const cameraDistance = 6;
const cubeEdgePixels = 300;

function showNoWebGLMessage() {
  const failureMessage = document.createElement("div");
  failureMessage.textContent = "NO WEBGL";
  failureMessage.style.color = "red";
  failureMessage.style.font = "700 72px sans-serif";
  failureMessage.style.position = "fixed";
  failureMessage.style.left = "32px";
  failureMessage.style.top = "32px";
  document.body.appendChild(failureMessage);
}

function identityMatrix() {
  const matrix = new Float32Array(16);
  matrix[0] = 1;
  matrix[5] = 1;
  matrix[10] = 1;
  matrix[15] = 1;
  return matrix;
}

function multiplyMatrices(left, right) {
  const product = new Float32Array(16);
  for (let column = 0; column < 4; column += 1) {
    for (let row = 0; row < 4; row += 1) {
      const rightColumnOffset = column * 4;
      product[rightColumnOffset + row] =
        left[row] * right[rightColumnOffset] +
        left[4 + row] * right[rightColumnOffset + 1] +
        left[8 + row] * right[rightColumnOffset + 2] +
        left[12 + row] * right[rightColumnOffset + 3];
    }
  }
  return product;
}

function translationMatrix(x, y, z) {
  const matrix = identityMatrix();
  matrix[12] = x;
  matrix[13] = y;
  matrix[14] = z;
  return matrix;
}

function scaleMatrix(scale) {
  const matrix = identityMatrix();
  matrix[0] = scale;
  matrix[5] = scale;
  matrix[10] = scale;
  return matrix;
}

function rotationXMatrix(radians) {
  const matrix = identityMatrix();
  const cosine = Math.cos(radians);
  const sine = Math.sin(radians);
  matrix[5] = cosine;
  matrix[6] = sine;
  matrix[9] = -sine;
  matrix[10] = cosine;
  return matrix;
}

function rotationYMatrix(radians) {
  const matrix = identityMatrix();
  const cosine = Math.cos(radians);
  const sine = Math.sin(radians);
  matrix[0] = cosine;
  matrix[2] = -sine;
  matrix[8] = sine;
  matrix[10] = cosine;
  return matrix;
}

function perspectiveMatrix(aspect, near, far) {
  const matrix = new Float32Array(16);
  const focalLength = 1 / Math.tan(fieldOfViewRadians / 2);
  matrix[0] = focalLength / aspect;
  matrix[5] = focalLength;
  matrix[10] = (far + near) / (near - far);
  matrix[11] = -1;
  matrix[14] = (2 * far * near) / (near - far);
  return matrix;
}

function modelViewProjectionMatrix(aspect, cssHeight, rotationXRadians, rotationYRadians) {
  const focalLength = 1 / Math.tan(fieldOfViewRadians / 2);
  // An edge through the cube's center, parallel to the screen, covers 300 CSS
  // pixels. Perspective makes the front face a little larger.
  const scale = (cubeEdgePixels * cameraDistance) / (focalLength * cssHeight);
  const projection = perspectiveMatrix(aspect, 0.1, 100);
  const view = translationMatrix(0, 0, -cameraDistance);
  const model = multiplyMatrices(
    rotationYMatrix(rotationYRadians),
    multiplyMatrices(rotationXMatrix(rotationXRadians), scaleMatrix(scale))
  );
  return multiplyMatrices(projection, multiplyMatrices(view, model));
}

function appendFace(vertexData, corners, red, green, blue) {
  const cornerOrder = [0, 1, 2, 0, 2, 3];
  for (let orderIndex = 0; orderIndex < cornerOrder.length; orderIndex += 1) {
    const corner = corners[cornerOrder[orderIndex]];
    vertexData.push(corner[0], corner[1], corner[2], red, green, blue);
  }
}

function cubeVertexData() {
  const vertexData = [];
  // +Z red, -Z green, +X blue, -X yellow, +Y cyan, -Y magenta.
  appendFace(vertexData, [[-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]], 1, 0, 0);
  appendFace(vertexData, [[1, -1, -1], [-1, -1, -1], [-1, 1, -1], [1, 1, -1]], 0, 1, 0);
  appendFace(vertexData, [[1, -1, 1], [1, -1, -1], [1, 1, -1], [1, 1, 1]], 0, 0, 1);
  appendFace(vertexData, [[-1, -1, -1], [-1, -1, 1], [-1, 1, 1], [-1, 1, -1]], 1, 1, 0);
  appendFace(vertexData, [[-1, 1, 1], [1, 1, 1], [1, 1, -1], [-1, 1, -1]], 0, 1, 1);
  appendFace(vertexData, [[-1, -1, -1], [1, -1, -1], [1, -1, 1], [-1, -1, 1]], 1, 0, 1);
  return new Float32Array(vertexData);
}

const vertexShaderSource = `
attribute vec3 vertexPosition;
attribute vec3 vertexColor;
uniform mat4 modelViewProjection;
varying vec3 faceColor;
void main() {
  gl_Position = modelViewProjection * vec4(vertexPosition, 1.0);
  faceColor = vertexColor;
}
`;

const fragmentShaderSource = `
precision mediump float;
varying vec3 faceColor;
void main() {
  gl_FragColor = vec4(faceColor, 1.0);
}
`;

function compileShader(gl, shaderType, source) {
  const shader = gl.createShader(shaderType);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  return shader;
}

function createCubeProgram(gl) {
  const vertexShader = compileShader(gl, gl.VERTEX_SHADER, vertexShaderSource);
  const fragmentShader = compileShader(gl, gl.FRAGMENT_SHADER, fragmentShaderSource);
  const program = gl.createProgram();
  gl.attachShader(program, vertexShader);
  gl.attachShader(program, fragmentShader);
  gl.linkProgram(program);
  return program;
}

function syncCanvasSize(canvas) {
  const pixelRatio = window.devicePixelRatio || 1;
  const cssWidth = canvas.clientWidth;
  const cssHeight = canvas.clientHeight;
  if (cssWidth < 1 || cssHeight < 1) {
    return null;
  }
  const backingWidth = Math.max(1, Math.round(cssWidth * pixelRatio));
  const backingHeight = Math.max(1, Math.round(cssHeight * pixelRatio));
  if (canvas.width !== backingWidth || canvas.height !== backingHeight) {
    canvas.width = backingWidth;
    canvas.height = backingHeight;
  }
  return { cssWidth: cssWidth, cssHeight: cssHeight };
}

function startSpinningCube(gl, canvas) {
  const program = createCubeProgram(gl);
  const positionLocation = gl.getAttribLocation(program, "vertexPosition");
  const colorLocation = gl.getAttribLocation(program, "vertexColor");
  const modelViewProjectionLocation = gl.getUniformLocation(program, "modelViewProjection");
  const vertices = cubeVertexData();
  const vertexCount = vertices.length / floatsPerVertex;
  const vertexBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.STATIC_DRAW);

  function drawFrame(timestampMilliseconds) {
    const cssSize = syncCanvasSize(canvas);
    if (cssSize === null) {
      requestAnimationFrame(drawFrame);
      return;
    }

    const seconds = timestampMilliseconds / 1000;
    // Initial turn shows three faces on the first frame. A zero angle would show only the front face.
    const rotationYRadians = seconds * 0.7 + 0.6;
    const rotationXRadians = seconds * 0.45 + 0.45;
    const modelViewProjection = modelViewProjectionMatrix(
      cssSize.cssWidth / cssSize.cssHeight,
      cssSize.cssHeight,
      rotationXRadians,
      rotationYRadians
    );

    gl.viewport(0, 0, canvas.width, canvas.height);
    // Nearer faces hide farther ones. The depth test keeps the back faces behind the front.
    gl.enable(gl.DEPTH_TEST);
    // Faces are opaque and already premultiplied, so blending stays off.
    gl.disable(gl.BLEND);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(program);
    gl.uniformMatrix4fv(modelViewProjectionLocation, false, modelViewProjection);
    gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
    gl.enableVertexAttribArray(positionLocation);
    gl.vertexAttribPointer(positionLocation, 3, gl.FLOAT, false, vertexStrideBytes, 0);
    gl.enableVertexAttribArray(colorLocation);
    gl.vertexAttribPointer(colorLocation, 3, gl.FLOAT, false, vertexStrideBytes, colorByteOffset);
    gl.drawArrays(gl.TRIANGLES, 0, vertexCount);
    requestAnimationFrame(drawFrame);
  }

  requestAnimationFrame(drawFrame);
}

const canvas = document.getElementById("cube");
const webglContext = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true });
if (webglContext === null) {
  showNoWebGLMessage();
} else {
  startSpinningCube(webglContext, canvas);
}
</script>
</body>
</html>
"""#
}
