//
//  RoomFurnitureRoomCheckTests.swift
//  leanring-buddyTests
//
//  Renders a real model (a store's GLB or USDZ) into a recorded room frame with the real floor measurement, and writes what
//  the panel would show as PNGs plus a metrics JSON: the model's size against the page's, its projected height, its lowest
//  point against the floor, how much the shadow darkens the floor around the footprint and whether it fades outward, its
//  whites against the wall's lit white, its edge softness against the frame's own edges, and the tracker's error at the
//  piece's base across a pan with known motion. It runs only with its environment variables set, for example:
//
//  ROOM_FURNITURE_FRAME=room.jpg ROOM_FURNITURE_FLOOR_REPLY=floor.json ROOM_FURNITURE_MODEL=lack.glb \
//  ROOM_FURNITURE_SIZE_CM=55x45x55 ROOM_FURNITURE_OUT=out ROOM_FURNITURE_ITEM_IS_LIGHT=1 \
//  tools/swift-check.sh --filter RoomFurnitureRoomCheck
//
//  ROOM_FURNITURE_ANCHOR=u,v moves the piece along the floor to the floor point under that pixel (or ROOM_FURNITURE_ANCHOR=spot
//  to the spot the app picks, `roomFurnitureSpotWhereTheWholePieceFits`), and
//  ROOM_FURNITURE_ITEM_IS_LIGHT says the piece is white or pale, so its whites are held to the wall's.
//
//  With ROOM_FURNITURE_WORKER (a local Worker's base URL), ROOM_FURNITURE_APP_SECRET, and ROOM_FURNITURE_PRODUCT_JPEG also
//  set, a second check paints the same item into the same frame through the real composite client (about $0.045) and
//  writes the render and the painted composite side by side, to judge which looks more real. ROOM_FURNITURE_PAINTING judges a
//  painting an earlier run wrote (its `-painting.png` when the check refused it) instead of asking for a new one.
//

import AppKit
import CoreImage
import Foundation
import ImageIO
import SceneKit
import Testing
import UniformTypeIdentifiers
import simd
@testable import Clicky

private let roomCheckEnvironment = ProcessInfo.processInfo.environment
private let roomCheckIsSetUp = ["ROOM_FURNITURE_FRAME", "ROOM_FURNITURE_FLOOR_REPLY", "ROOM_FURNITURE_MODEL", "ROOM_FURNITURE_SIZE_CM", "ROOM_FURNITURE_OUT"]
    .allSatisfy { roomCheckEnvironment[$0] != nil }
private let sideBySideIsSetUp = roomCheckIsSetUp
    && ["ROOM_FURNITURE_WORKER", "ROOM_FURNITURE_APP_SECRET", "ROOM_FURNITURE_PRODUCT_JPEG"].allSatisfy { roomCheckEnvironment[$0] != nil }

/// What both checks start from: the keyframe, its floor (moved to `ROOM_FURNITURE_ANCHOR` when set), the page's size, and
/// the loaded model.
private struct RoomCheckInputs {
    let keyframeImage: CGImage
    let keyframeJPEG: Data
    let floor: FloorPlane
    let widthMeters: Double, heightMeters: Double, depthMeters: Double
    let modelRootNode: SCNNode
    let outputFolder: URL
    let runName: String

    init() throws {
        let framePath = try #require(roomCheckEnvironment["ROOM_FURNITURE_FRAME"])
        keyframeJPEG = try Data(contentsOf: URL(fileURLWithPath: framePath))
        keyframeImage = try loadImage(framePath)
        var floor = try FloorPlane(responseData: Data(contentsOf: URL(fileURLWithPath: try #require(roomCheckEnvironment["ROOM_FURNITURE_FLOOR_REPLY"]))))
        let sizeCentimeters = try #require(roomCheckEnvironment["ROOM_FURNITURE_SIZE_CM"]).split(separator: "x").compactMap { Double($0) }
        try #require(sizeCentimeters.count == 3)
        (widthMeters, heightMeters, depthMeters) = (sizeCentimeters[0] / 100, sizeCentimeters[1] / 100, sizeCentimeters[2] / 100)
        if roomCheckEnvironment["ROOM_FURNITURE_ANCHOR"] == "spot" {
            // The spot the app picks, with no texture map, so the check paints where the live panel stands the piece.
            floor = roomFurnitureSpotWhereTheWholePieceFits(
                measuredFloor: floor, widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters,
                frameSize: CGSize(width: keyframeImage.width, height: keyframeImage.height), texture: nil
            ).floor
        } else if let anchorText = roomCheckEnvironment["ROOM_FURNITURE_ANCHOR"] {
            // The floor point under another pixel: the same plane, met by that pixel's ray.
            let anchorNumbers = anchorText.split(separator: ",").compactMap { Double($0) }
            let ray = SIMD3((anchorNumbers[0] - floor.principalPoint.x) / floor.focalLengthPixels, (anchorNumbers[1] - floor.principalPoint.y) / floor.focalLengthPixels, 1)
            let center = ray * (simd_dot(floor.center, floor.up) / simd_dot(ray, floor.up))
            floor = FloorPlane(center: center, right: floor.right, up: floor.up, forward: floor.forward, focalLengthPixels: floor.focalLengthPixels,
                               principalPoint: floor.principalPoint, distanceMeters: simd_length(center), floorTiltDegrees: floor.floorTiltDegrees, planeInlierShare: floor.planeInlierShare)
        }
        self.floor = floor
        let modelPath = try #require(roomCheckEnvironment["ROOM_FURNITURE_MODEL"])
        let modelData = try Data(contentsOf: URL(fileURLWithPath: modelPath))
        modelRootNode = try RoomFurnitureModelLoading.rootNode(fromFileData: modelData, kind: try #require(RoomFurnitureModelFileKind.sniff(modelData)))
        outputFolder = URL(fileURLWithPath: try #require(roomCheckEnvironment["ROOM_FURNITURE_OUT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        runName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
    }

    func placement() throws -> RoomFurniturePlacement {
        try #require(RoomFurniturePlacement(floor: floor, widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters))
    }

    func render() throws -> (layers: RoomFurnitureKeyframeLayers, report: RoomFurnitureRenderReport) {
        try #require(RoomFurnitureRenderer().render(RoomFurnitureRenderRequest(
            modelRootNode: modelRootNode, placement: try placement(), focalLengthPixels: floor.focalLengthPixels,
            principalPoint: floor.principalPoint, keyframeImage: keyframeImage, look: .storeModel
        )))
    }

    /// The keyframe with the layers drawn as the panel draws them, with no tracking motion.
    func composed(_ layers: RoomFurnitureKeyframeLayers, withShadow: Bool = true) throws -> CGImage {
        let keyframe = CIImage(cgImage: keyframeImage)
        let image = RoomFurnitureComposition.frameWithTheFurniture(
            frame: keyframe, itemLayer: CIImage(cgImage: layers.itemLayer),
            shadowLayer: withShadow ? layers.shadowLayer.map { CIImage(cgImage: $0) } : nil,
            keyframeToCurrent: .identity, grainStandardDeviation: layers.cameraNoiseStandardDeviation, grainOffset: .zero
        )
        return try #require(CIContext().createCGImage(image, from: keyframe.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()))
    }
}

/// A gray image's pixels from 0 to 1, rows from the top.
private struct GrayPixels {
    let width: Int
    let height: Int
    let values: [Double]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var luminances = [Double](repeating: 0, count: width * height)
        for pixelIndex in 0..<(width * height) {
            let red = Double(bytes[pixelIndex * 4]), green = Double(bytes[pixelIndex * 4 + 1]), blue = Double(bytes[pixelIndex * 4 + 2])
            luminances[pixelIndex] = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        }
        values = luminances
    }

    subscript(column: Int, row: Int) -> Double { values[row * width + column] }
}

private func writePNG(_ image: CGImage, to fileURL: URL) {
    guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

private func loadImage(_ path: String) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// The edge spread (the Gaussian sigma of a blurred step) from the steepest slope across an edge: a step of height C
/// blurred by sigma rises at most C / (sigma * sqrt(2 pi)) per pixel.
private func sigma(ofStepHeight stepHeight: Double, steepestSlope: Double) -> Double {
    stepHeight / (steepestSlope * (2 * Double.pi).squareRoot())
}

/// The item's edge spread from its alpha: the 90th percentile slope of alpha where it is between clear and opaque.
private func itemEdgeSigma(_ itemPixels: RoomFurnitureTestPixels) -> Double? {
    var slopes: [Double] = []
    for row in 1..<(itemPixels.height - 1) {
        for column in 1..<(itemPixels.width - 1) {
            let alpha = Double(itemPixels.alpha(atColumn: column, row: row)) / 255
            guard alpha > 0.15, alpha < 0.85 else { continue }
            let alongX = (Double(itemPixels.alpha(atColumn: column + 1, row: row)) - Double(itemPixels.alpha(atColumn: column - 1, row: row))) / 510
            let alongY = (Double(itemPixels.alpha(atColumn: column, row: row + 1)) - Double(itemPixels.alpha(atColumn: column, row: row - 1))) / 510
            slopes.append(hypot(alongX, alongY))
        }
    }
    guard slopes.count > 20 else { return nil }
    let steepest = slopes.sorted()[Int(Double(slopes.count) * 0.9)]
    return sigma(ofStepHeight: 1, steepestSlope: steepest)
}

/// The frame's own edge spread: at the steepest one percent of pixels whose 7 by 7 neighborhood spans a strong step, the
/// median sigma of that step.
private func frameEdgeSigma(_ frame: GrayPixels) -> Double? {
    var candidates: [(slope: Double, stepHeight: Double)] = []
    for row in stride(from: 4, to: frame.height - 4, by: 1) {
        for column in stride(from: 4, to: frame.width - 4, by: 1) {
            let alongX = (frame[column + 1, row] - frame[column - 1, row]) / 2
            let alongY = (frame[column, row + 1] - frame[column, row - 1]) / 2
            let slope = hypot(alongX, alongY)
            guard slope > 0.04 else { continue }
            var darkest = 1.0, brightest = 0.0
            for neighborRow in (row - 3)...(row + 3) {
                for neighborColumn in (column - 3)...(column + 3) {
                    darkest = min(darkest, frame[neighborColumn, neighborRow])
                    brightest = max(brightest, frame[neighborColumn, neighborRow])
                }
            }
            if brightest - darkest > 0.25 { candidates.append((slope, brightest - darkest)) }
        }
    }
    guard candidates.count > 50 else { return nil }
    let steepest = candidates.sorted { $0.slope > $1.slope }.prefix(max(candidates.count / 100, 20))
    let sigmas = steepest.map { sigma(ofStepHeight: $0.stepHeight, steepestSlope: $0.slope) }.sorted()
    return sigmas[sigmas.count / 2]
}

struct RoomFurnitureRoomCheckTests {
    @Test(.enabled(if: roomCheckIsSetUp, "Set ROOM_FURNITURE_FRAME, _FLOOR_REPLY, _MODEL, _SIZE_CM, and _OUT"))
    func aRealModelStandsInARecordedRoom() throws {
        let inputs = try RoomCheckInputs()
        let (keyframeImage, floor, modelRootNode, outputFolder, runName) = (inputs.keyframeImage, inputs.floor, inputs.modelRootNode, inputs.outputFolder, inputs.runName)
        let (widthMeters, heightMeters, depthMeters) = (inputs.widthMeters, inputs.heightMeters, inputs.depthMeters)
        let placement = try inputs.placement()
        let rendered = try inputs.render()
        print(rendered.report.logLine)

        // The frame as the panel draws it, with no tracking motion, and the same with no shadow.
        let compositeImage = try inputs.composed(rendered.layers)
        let noShadowImage = try inputs.composed(rendered.layers, withShadow: false)
        writePNG(compositeImage, to: outputFolder.appendingPathComponent("\(runName)-composite.png"))
        writePNG(noShadowImage, to: outputFolder.appendingPathComponent("\(runName)-no-shadow.png"))
        writePNG(rendered.layers.itemLayer, to: outputFolder.appendingPathComponent("\(runName)-item.png"))
        if let shadowLayer = rendered.layers.shadowLayer {
            writePNG(shadowLayer, to: outputFolder.appendingPathComponent("\(runName)-shadow.png"))
        }

        // The model's box against the page's size, and its lowest point against the floor.
        let modelBox = try #require(RoomFurnitureRenderer.boundingBox(of: modelRootNode))
        let fit = rendered.report.fit
        let modelToCamera = placement.modelToCameraTransform * fit.modelToFurnitureTransform(boundingBoxMinimum: modelBox.minimum, boundingBoxMaximum: modelBox.maximum)
        var furnitureMinimum = SIMD3<Double>(repeating: .infinity), furnitureMaximum = SIMD3<Double>(repeating: -.infinity)
        var lowestHeightAboveTheFloor = Double.infinity
        let furnitureTransform = fit.modelToFurnitureTransform(boundingBoxMinimum: modelBox.minimum, boundingBoxMaximum: modelBox.maximum)
        for cornerX in [modelBox.minimum.x, modelBox.maximum.x] {
            for cornerY in [modelBox.minimum.y, modelBox.maximum.y] {
                for cornerZ in [modelBox.minimum.z, modelBox.maximum.z] {
                    let inFurniture = furnitureTransform * SIMD4(cornerX, cornerY, cornerZ, 1)
                    furnitureMinimum = simd_min(furnitureMinimum, SIMD3(inFurniture.x, inFurniture.y, inFurniture.z))
                    furnitureMaximum = simd_max(furnitureMaximum, SIMD3(inFurniture.x, inFurniture.y, inFurniture.z))
                    let inCamera = modelToCamera * SIMD4(cornerX, cornerY, cornerZ, 1)
                    lowestHeightAboveTheFloor = min(lowestHeightAboveTheFloor, simd_dot(SIMD3(inCamera.x, inCamera.y, inCamera.z) - floor.center, floor.up))
                }
            }
        }
        let modelSize = furnitureMaximum - furnitureMinimum
        let sizeErrors = [abs(modelSize.x / widthMeters - 1), abs(modelSize.y / heightMeters - 1), abs(modelSize.z / depthMeters - 1)]

        // The rendered height against the box's projected height.
        let itemPixels = RoomFurnitureTestPixels(rendered.layers.itemLayer)
        let renderedBox = try #require(itemPixels.boxAroundOpaquePixels())
        let projectedBox = try #require(floor.keyframeBoxCorners(widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters))
        // The model's own vertices through the pinhole: a sofa does not fill its bounding box, so its outline is the model's.
        var highestProjectedRow = Double.infinity, lowestProjectedRow = -Double.infinity
        modelRootNode.enumerateHierarchy { node, _ in
            guard let vertexSource = node.geometry?.sources(for: .vertex).first, vertexSource.bytesPerComponent == 4 else { return }
            let toRoot = node == modelRootNode ? matrix_identity_float4x4 : modelRootNode.simdConvertTransform(matrix_identity_float4x4, from: node)
            vertexSource.data.withUnsafeBytes { vertexBytes in
                for vertexIndex in stride(from: 0, to: vertexSource.vectorCount, by: 7) {
                    let offset = vertexSource.dataOffset + vertexIndex * vertexSource.dataStride
                    let position = SIMD4<Float>(vertexBytes.load(fromByteOffset: offset, as: Float.self), vertexBytes.load(fromByteOffset: offset + 4, as: Float.self), vertexBytes.load(fromByteOffset: offset + 8, as: Float.self), 1)
                    let inRoot = toRoot * position
                    let inCamera = modelToCamera * SIMD4(Double(inRoot.x), Double(inRoot.y), Double(inRoot.z), 1)
                    guard let pixel = pinholeProjection(of: SIMD3(inCamera.x, inCamera.y, inCamera.z), focalLengthPixels: floor.focalLengthPixels, principalPoint: floor.principalPoint) else { continue }
                    highestProjectedRow = min(highestProjectedRow, pixel.y)
                    lowestProjectedRow = max(lowestProjectedRow, pixel.y)
                }
            }
        }
        let projectedHeight = lowestProjectedRow - highestProjectedRow
        let projectedHeightError = abs(renderedBox.height / projectedHeight - 1)

        // The shadow: over the footprint grown by 6 cm, where the piece meets the floor, and over a ring 25 to 40 cm out.
        let withShadow = GrayPixels(compositeImage), withoutShadow = GrayPixels(noShadowImage)
        let frontLeft = projectedBox[3], frontRight = projectedBox[2]
        let frontRow = Int(max(frontLeft.y, frontRight.y))
        func floorPixels(grownFrom innerGrowthMeters: Double, to outerGrowthMeters: Double) -> [(column: Int, row: Int)] {
            var pixels: Set<Int> = []
            let halfWidth = widthMeters / 2 + outerGrowthMeters, halfDepth = depthMeters / 2 + outerGrowthMeters
            for alongRight in stride(from: -halfWidth, through: halfWidth, by: 0.005) {
                for alongFront in stride(from: -halfDepth, through: halfDepth, by: 0.005) {
                    let insideTheInnerEdge = abs(alongRight) < widthMeters / 2 + innerGrowthMeters && abs(alongFront) < depthMeters / 2 + innerGrowthMeters
                    guard innerGrowthMeters < 0 || !insideTheInnerEdge else { continue }
                    let floorPoint = placement.footprintCenter + placement.rightDirection * alongRight + placement.towardTheFrontDirection * alongFront
                    guard let pixel = pinholeProjection(of: floorPoint, focalLengthPixels: floor.focalLengthPixels, principalPoint: floor.principalPoint) else { continue }
                    let column = Int(pixel.x), row = Int(pixel.y)
                    guard column >= 0, row >= 0, column < withShadow.width, row < withShadow.height, itemPixels.alpha(atColumn: column, row: row) < 10 else { continue }
                    pixels.insert(row * withShadow.width + column)
                }
            }
            return pixels.map { (column: $0 % withShadow.width, row: $0 / withShadow.width) }
        }
        func darkening(over pixels: [(column: Int, row: Int)]) -> Double? {
            let withTotal = pixels.reduce(0.0) { $0 + withShadow[$1.column, $1.row] }
            let withoutTotal = pixels.reduce(0.0) { $0 + withoutShadow[$1.column, $1.row] }
            return withoutTotal > 0 ? 1 - withTotal / withoutTotal : nil
        }
        let nearDarkening = darkening(over: floorPixels(grownFrom: -1, to: 0.06))
        let farDarkening = darkening(over: floorPixels(grownFrom: 0.25, to: 0.4))

        // The whites: the 95th percentile of the item's own pixels against the wall's lit white above it.
        let compositePixels = withShadow
        var itemLuminances: [Double] = []
        for row in 0..<itemPixels.height {
            for column in 0..<itemPixels.width where itemPixels.alpha(atColumn: column, row: row) > 250 {
                itemLuminances.append(compositePixels[column, row])
            }
        }
        let itemWhite = itemLuminances.sorted()[Int(Double(itemLuminances.count) * 0.95)]
        let keyframePixels = GrayPixels(keyframeImage)
        let wallBandTop = max(0, Int(renderedBox.minY - renderedBox.height * 0.6)), wallBandBottom = max(1, Int(renderedBox.minY - 4))
        var wallLuminances: [Double] = []
        for row in wallBandTop..<wallBandBottom {
            for column in Int(renderedBox.minX)..<Int(renderedBox.maxX) { wallLuminances.append(keyframePixels[column, row]) }
        }
        let wallBrighterHalf = wallLuminances.sorted().suffix(max(wallLuminances.count / 2, 1))
        let nearWallWhite = wallBrighterHalf.reduce(0, +) / Double(max(wallBrighterHalf.count, 1))
        // The wall's lit white is the near wall's, unless that wall is in shade: then the share of the frame's own lit
        // white (its 95th percentile) the renderer holds to, which is a power of 1 / 2.4 in sRGB of the linear share.
        let frameLitWhite = keyframePixels.values.sorted()[Int(Double(keyframePixels.values.count) * 0.95)]
        let wallWhite = max(nearWallWhite, frameLitWhite * pow(RoomFurnitureRenderer.shareOfTheFramesLitWhite, 1 / 2.4))
        let whiteRatio = itemWhite / max(wallWhite, 1e-6)

        let itemSigma = itemEdgeSigma(itemPixels)
        let frameSigma = frameEdgeSigma(keyframePixels)
        let softnessRatio = itemSigma.flatMap { item in frameSigma.map { item / $0 } }

        let trackingError = try trackerErrorAtTheBaseAcrossAKnownPan(keyframeImage: keyframeImage, basePoint: CGPoint(x: (frontLeft.x + frontRight.x) / 2, y: Double(frontRow)))

        let metrics: [String: Any] = [
            "model": runName,
            "sizeErrors": sizeErrors,
            "projectedHeightError": projectedHeightError,
            "lowestPointMillimeters": lowestHeightAboveTheFloor * 1000,
            "nearShadowDarkening": nearDarkening ?? -1,
            "farShadowDarkening": farDarkening ?? -1,
            "itemWhite": itemWhite, "wallWhite": wallWhite, "nearWallWhite": nearWallWhite, "frameLitWhite": frameLitWhite, "whiteRatio": whiteRatio,
            "itemEdgeSigma": itemSigma ?? -1, "frameEdgeSigma": frameSigma ?? -1, "softnessRatio": softnessRatio ?? -1,
            "worstTrackingErrorPixels": trackingError,
            // The model's own width, height, and depth in centimeters once scaled to the page's height, to compare with
            // the page's size when it differs.
            "modelSizeCentimetersAtThePageHeight": [modelSize.x * 100, modelSize.y * 100, modelSize.z * 100],
            "fitScale": fit.scale, "fitTurnedAQuarter": fit.wasTurnedAQuarter, "fitWorstSideMismatch": fit.worstSideMismatch,
            "renderMilliseconds": rendered.report.renderMilliseconds,
        ]
        let metricsData = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try metricsData.write(to: outputFolder.appendingPathComponent("\(runName)-metrics.json"))
        print(String(decoding: metricsData, as: UTF8.self))

        #expect(sizeErrors.allSatisfy { $0 <= 0.05 }, "the model's box is within 5 percent of the page's size")
        #expect(projectedHeightError <= 0.03, "the rendered height is within 3 percent of the projected box")
        #expect(abs(lowestHeightAboveTheFloor) <= 0.005, "the lowest point is within 5 mm of the floor")
        if let nearDarkening, let farDarkening {
            #expect((0.08...0.35).contains(nearDarkening), "the shadow darkens the floor at the base 8 to 35 percent")
            #expect(farDarkening < nearDarkening, "the shadow fades outward")
        } else {
            Issue.record("no floor band around the footprint to measure")
        }
        if roomCheckEnvironment["ROOM_FURNITURE_ITEM_IS_LIGHT"] == "1" {
            #expect((0.75...1.15).contains(whiteRatio), "the item's whites are 0.75 to 1.15 of the wall's lit white")
        }
        if let softnessRatio {
            #expect((0.7...1.3).contains(softnessRatio), "the item's edges are within 30 percent of the frame's own")
        }
        #expect(trackingError < 2, "the tracker holds the piece's base within 2 pixels across the pan")
    }

    /// The same item on the same frame and floor, rendered from the model and painted by the composite service, written
    /// side by side (render on the left) to judge which looks more real.
    @MainActor
    @Test(.enabled(if: sideBySideIsSetUp, "Set the room check's variables and ROOM_FURNITURE_WORKER, _APP_SECRET, and _PRODUCT_JPEG"))
    func theRenderAndThePaintedCompositeSideBySide() async throws {
        let inputs = try RoomCheckInputs()
        let rendered = try inputs.render()
        let renderedFrame = try inputs.composed(rendered.layers)

        // The client reads the secret from this test process's own defaults, which are not the app's.
        UserDefaults.standard.set(try #require(roomCheckEnvironment["ROOM_FURNITURE_APP_SECRET"]), forKey: ClickyAppSecret.defaultsKey)
        let client = RoomFurnitureGenerationClient(workerBaseURL: try #require(roomCheckEnvironment["ROOM_FURNITURE_WORKER"]))
        let projectedBox = try #require(inputs.floor.keyframeBoxCorners(widthMeters: inputs.widthMeters, heightMeters: inputs.heightMeters, depthMeters: inputs.depthMeters))
        let maskPNG = try #require(furnitureCompositeMaskPNG(projectedCorners: projectedBox, frameWidth: inputs.keyframeImage.width, frameHeight: inputs.keyframeImage.height, shadowMarginPixels: 24))
        let sizeWords = String(format: "%.0f cm wide, %.0f cm tall, %.0f cm deep", inputs.widthMeters * 100, inputs.heightMeters * 100, inputs.depthMeters * 100)
        let paintingStartedAt = Date()
        // ROOM_FURNITURE_PAINTING judges a painting an earlier run saved, with no new request.
        let painted: CGImage
        if let savedPaintingPath = roomCheckEnvironment["ROOM_FURNITURE_PAINTING"] {
            painted = try loadImage(savedPaintingPath)
        } else {
            painted = try await client.paintTheItemIntoTheKeyframe(
                keyframeJPEG: inputs.keyframeJPEG, keyframeWidth: inputs.keyframeImage.width, keyframeHeight: inputs.keyframeImage.height,
                productJPEG: try Data(contentsOf: URL(fileURLWithPath: try #require(roomCheckEnvironment["ROOM_FURNITURE_PRODUCT_JPEG"]))),
                maskPNG: maskPNG, itemTitle: roomCheckEnvironment["ROOM_FURNITURE_TITLE"] ?? inputs.runName, itemSizeWords: sizeWords
            )
        }
        let paintingSeconds = Date().timeIntervalSince(paintingStartedAt)
        let painting = RoomFurniturePaintedComposite.itemLayers(painted: painted, keyframe: inputs.keyframeImage, maskPNG: maskPNG, projectedBox: projectedBox)
        print(String(format: "Room furniture check: painted in %.1f s, painted height %.2f of the measured box (%@)", paintingSeconds, painting.paintedHeightRatio ?? -1,
                     painting.paintedRows.map { roomFurniturePaintedRowsAgainstTheBox($0, projectedBox) } ?? "nothing painted"))
        let paintedFrame = try painting.layers.map { try inputs.composed($0) } ?? painted

        let width = inputs.keyframeImage.width, height = inputs.keyframeImage.height
        let sideBySide = try #require(CGContext(data: nil, width: width * 2, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sideBySide.draw(renderedFrame, in: CGRect(x: 0, y: 0, width: width, height: height))
        sideBySide.draw(paintedFrame, in: CGRect(x: width, y: 0, width: width, height: height))
        writePNG(try #require(sideBySide.makeImage()), to: inputs.outputFolder.appendingPathComponent("\(inputs.runName)-render-and-painting.png"))
        writePNG(paintedFrame, to: inputs.outputFolder.appendingPathComponent("\(inputs.runName)-painting.png"))
        #expect(painting.layers != nil, "the painted item stands within 15 percent of the measured height")
    }

    /// Pans across the keyframe with a known turn and shift each frame (a crop of the keyframe enlarged by 1.3, turned up to
    /// 1.5 degrees and shifted up to 60 pixels), tracks it with the real tracker, and returns the worst distance between
    /// where the tracker puts the piece's base and where the known motion puts it.
    private func trackerErrorAtTheBaseAcrossAKnownPan(keyframeImage: CGImage, basePoint: CGPoint) throws -> Double {
        let frameWidth = keyframeImage.width, frameHeight = keyframeImage.height
        let (trackWidth, trackHeight) = trackSize(forFrameWidth: frameWidth, frameHeight: frameHeight)
        let cameraPixelsPerTrackPixel = Double(frameWidth) / Double(trackWidth)
        let ciContext = CIContext()
        let source = CIImage(cgImage: keyframeImage)
        let frameRectangle = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        let enlargement = 1.3
        // Each frame's view: the source enlarged about its center, then turned and shifted, in y-down pixels.
        func viewTransform(step: Int, of stepCount: Int) -> EuclideanWarp {
            let progress = Double(step) / Double(stepCount - 1)
            return EuclideanWarp(angleRadians: (progress - 0.5) * 3 * .pi / 180, translationX: (progress - 0.5) * 120, translationY: sin(progress * .pi) * 30)
        }
        func frame(seenThrough warp: EuclideanWarp) throws -> (gray: RoomGrayscaleImage, mapping: (CGPoint) -> CGPoint) {
            // keyframe point p -> enlarged about the center -> turned and shifted: q = W(c + s (p - c)).
            let center = CGPoint(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2)
            let mapping: (CGPoint) -> CGPoint = { point in
                warp.apply(to: CGPoint(x: center.x + enlargement * (point.x - center.x), y: center.y + enlargement * (point.y - center.y)))
            }
            // The same mapping in Core Image's y-up coordinates.
            let height = Double(frameHeight)
            let origin = mapping(CGPoint(x: 0, y: height)), alongX = mapping(CGPoint(x: 1, y: height)), alongY = mapping(CGPoint(x: 0, y: height - 1))
            let transform = CGAffineTransform(
                a: alongX.x - origin.x, b: -(alongX.y - origin.y), c: alongY.x - origin.x, d: -(alongY.y - origin.y),
                tx: origin.x, ty: height - origin.y
            )
            let viewed = source.clampedToExtent().transformed(by: transform).cropped(to: frameRectangle)
            let small = viewed.transformed(by: CGAffineTransform(scaleX: Double(trackWidth) / Double(frameWidth), y: Double(trackHeight) / Double(frameHeight)))
            var grayBytes = [UInt8](repeating: 0, count: trackWidth * trackHeight)
            ciContext.render(small, toBitmap: &grayBytes, rowBytes: trackWidth, bounds: CGRect(x: 0, y: 0, width: trackWidth, height: trackHeight), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            return (RoomGrayscaleImage(width: trackWidth, height: trackHeight, pixels: grayBytes.map(Float.init)), mapping)
        }
        let stepCount = 40
        let firstFrame = try frame(seenThrough: viewTransform(step: 0, of: stepCount))
        let roomMask = roomMaskWithNoPerson(width: trackWidth, height: trackHeight)
        let tracker = RoomTracker(keyframeGrayscale: firstFrame.gray, keyframeRoomMask: roomMask)
        // The base as the first pan frame shows it.
        let baseInTheFirstFrame = firstFrame.mapping(basePoint)
        var worstError = 0.0
        for step in 1..<stepCount {
            let panFrame = try frame(seenThrough: viewTransform(step: step, of: stepCount))
            let trackStep = tracker.track(currentGrayscale: panFrame.gray, currentRoomMask: roomMask)
            let trackedBase = trackStep.warp.scaled(by: cameraPixelsPerTrackPixel).apply(to: baseInTheFirstFrame)
            let trueBase = panFrame.mapping(basePoint)
            worstError = max(worstError, hypot(trackedBase.x - trueBase.x, trackedBase.y - trueBase.y))
        }
        return worstError
    }
}
