//
//  ShirtPaintedStillPhotoCheckTests.swift
//  leanring-buddyTests
//
//  Paints real store tops onto a real photo of a person through the real Worker, with the app's own pose, person mask, live
//  preview, paint mask, client, and paste, and measures what the painted still must get right. It runs only with
//  SHIRT_TRYON_PHOTOS_DIR (a folder with standing.jpg, a personal photo that is never committed), SHIRT_PAINT_PRODUCTS
//  (product photo paths, joined with commas), SHIRT_PAINT_OUTPUT_DIR, SHIRT_PAINT_WORKER (a local Worker's base URL), and
//  SHIRT_PAINT_APP_SECRET. Each painting costs an OpenAI image edit (about $0.06), so SHIRT_PAINT_REUSE=1 judges the
//  paintings an earlier run saved with no new call, and SHIRT_PAINT_MASKS_ONLY=1 writes only the masks. The garment's cut is
//  named by SHIRT_PAINT_KIND (tshirt, shirt, sweater, hoodie, jacket, coat, vest, dress, jumpsuit, or other), SHIRT_PAINT_SLEEVES
//  (none, short, or long), and SHIRT_PAINT_LENGTH (waist, hip, thigh, knee, or ankle), which default to a short-sleeved T-shirt
//  to the hip, so a long-sleeved jacket is painted and masked as one. The app is told the cloth color by the page reader, which
//  this check has none of, so each product also needs SHIRT_PAINT_COLOR_<product file name> (the cloth's main color as #RRGGBB
//  in sRGB, and SHIRT_PAINT_PRINT_<product file name> for its print, if any) before a painting is paid for. SHIRT_PAINT_GHOST=1 runs the ghost outline's path, as
//  the app does for a garment the live preview cannot draw: no garment is cut out, the preview is the camera as filmed, and
//  the mask takes its area from the coverage alone:
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos SHIRT_PAINT_PRODUCTS=/path/a.jpg,/path/b.jpg SHIRT_PAINT_OUTPUT_DIR=/path/out \
//  SHIRT_PAINT_WORKER=http://localhost:8794 SHIRT_PAINT_APP_SECRET=... SHIRT_PAINT_KIND=jacket SHIRT_PAINT_SLEEVES=long \
//  SHIRT_PAINT_COLOR_a=#2B4C7E SHIRT_PAINT_COLOR_b=#C9B79C \
//  tools/swift-check.sh --filter ShirtPaintedStillPhotoCheck
//
//  The numbers, per painting:
//  - the old top left showing: the share of the old top's pixels that look like it and are, with their 7 by 7 neighborhood,
//    as they were;
//  - the face, the hands, and the neck: the share of each one's pixels that are byte for byte as filmed, the neck's taken
//    inside the few pixels its put-back fades in over;
//  - print sharpness: the painting's mean gradient over the chest against the live preview's, which is the product photo
//    warped onto the same chest, so 1 is as sharp as the product;
//  - the old top at the neck: pixels in the band where the new collar meets the neck that came back as filmed and look like
//    the old top, per shoulder width, which showed as a stepped dark line between the new collar and the neck;
//  - the bare arms: the share of the arms and the room beside them, outside what the painting may draw and the new top
//    covers, more than 8 levels off the filmed frame, which the painting's redraw of the arm made as a doubled outline.
//
//  Each run keeps the Worker's reply (reply-<name>.png) beside the pasted still, so SHIRT_PAINT_REUSE=1 pastes it again with
//  the paste as it is now. A folder with only an older painted-<name>.png judges that paste as it was.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import SwiftUI
import Vision
import simd
@testable import Clicky

private let paintCheckEnvironment = ProcessInfo.processInfo.environment

struct ShirtPaintedStillMetrics: Codable {
    var shirtName = ""
    var paintableShareOfTheFrame = 0.0
    var oldTopLeftShowingShare = 0.0
    var faceExactShare = 0.0
    var handsExactShare = 0.0
    var neckExactShare = 0.0
    var printSharpnessAgainstThePreview = 0.0
    var oldTopAtTheNeckPixelsPerShoulderWidth = 0.0
    var bareArmsChangedShare = 0.0
    var seconds = 0.0
}

/// The picture as the room art panel reads a page's image file: its long side at most 1280.
private func scaledLikeThePagePicture(_ image: CGImage) -> CGImage {
    let scale = min(1, Double(RoomArtPictureSource.longestSide) / Double(max(image.width, image.height)))
    guard scale < 1 else { return image }
    let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// The mean absolute difference between neighbors over a box, in 8-bit levels of luma: how much fine detail it holds.
private func meanGradient(of pixels: [UInt8], width: Int, box: CGRect) -> Double {
    var total = 0.0, count = 0
    func luma(_ index: Int) -> Double { 0.299 * Double(pixels[index * 4]) + 0.587 * Double(pixels[index * 4 + 1]) + 0.114 * Double(pixels[index * 4 + 2]) }
    for row in Int(box.minY)..<(Int(box.maxY) - 1) {
        for column in Int(box.minX)..<(Int(box.maxX) - 1) {
            let index = row * width + column
            total += abs(luma(index + 1) - luma(index)) + abs(luma(index + width) - luma(index))
            count += 1
        }
    }
    return count > 0 ? total / Double(count) : 0
}

/// Side by side at one height: the photo, the product, the live preview, and the painted still.
private func sideBySide(_ images: [CGImage], height: Int) -> CGImage? {
    let scaledWidths = images.map { Int(Double($0.width) * Double(height) / Double($0.height)) }
    let gap = 12
    let width = scaledWidths.reduce(0, +) + gap * (images.count + 1)
    guard let context = CGContext(data: nil, width: width, height: height + 2 * gap, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height + 2 * gap))
    context.interpolationQuality = .high
    var nextImageLeftEdge = gap
    for (image, scaledWidth) in zip(images, scaledWidths) {
        context.draw(image, in: CGRect(x: nextImageLeftEdge, y: gap, width: scaledWidth, height: height))
        nextImageLeftEdge += scaledWidth + gap
    }
    return context.makeImage()
}

@MainActor
struct ShirtPaintedStillPhotoCheckTests {
    @Test(.enabled(if: ["SHIRT_TRYON_PHOTOS_DIR", "SHIRT_PAINT_PRODUCTS", "SHIRT_PAINT_OUTPUT_DIR", "SHIRT_PAINT_WORKER"].allSatisfy { paintCheckEnvironment[$0] != nil }, "Set the SHIRT_PAINT variables"))
    func eachStoreTopIsPaintedOnThePersonWithTheirFaceHandsAndNeckAsFilmed() async throws {
        let photosFolder = URL(fileURLWithPath: try #require(paintCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let outputFolder = URL(fileURLWithPath: try #require(paintCheckEnvironment["SHIRT_PAINT_OUTPUT_DIR"]))
        let productPaths = try #require(paintCheckEnvironment["SHIRT_PAINT_PRODUCTS"]).split(separator: ",").map(String.init)
        let reusesSavedPaintings = paintCheckEnvironment["SHIRT_PAINT_REUSE"] == "1"
        let garmentKind = try #require(RoomArtGarment(rawValue: paintCheckEnvironment["SHIRT_PAINT_KIND"] ?? "tshirt"), "SHIRT_PAINT_KIND names no garment")
        let garmentSleeves = try #require(RoomArtSleeves(rawValue: paintCheckEnvironment["SHIRT_PAINT_SLEEVES"] ?? "short"), "SHIRT_PAINT_SLEEVES is none, short, or long")
        let garmentLength = try #require(RoomArtGarmentLength(rawValue: paintCheckEnvironment["SHIRT_PAINT_LENGTH"] ?? "hip"), "SHIRT_PAINT_LENGTH names no length")
        let coverage = ShirtCoverage(sleeves: garmentSleeves, length: garmentLength)
        let usesTheGhostOutline = paintCheckEnvironment["SHIRT_PAINT_GHOST"] == "1"
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        // The client reads the secret from the defaults, as the app does, and the test takes it out again after.
        if let appSecret = paintCheckEnvironment["SHIRT_PAINT_APP_SECRET"] { UserDefaults.standard.set(appSecret, forKey: ClickyAppSecret.defaultsKey) }
        defer { UserDefaults.standard.removeObject(forKey: ClickyAppSecret.defaultsKey) }

        let context = CIContext()
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let standingPhoto = try loadImage(at: photosFolder.appendingPathComponent("standing.jpg"))
        let width = standingPhoto.width, height = standingPhoto.height
        let frame = CIImage(cgImage: standingPhoto)
        let frameExtent = frame.extent
        var frameBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frameBuffer)
        let cameraFrame = try #require(frameBuffer)
        context.render(frame, to: cameraFrame, bounds: frameExtent, colorSpace: sRGB)
        let torso = try #require(ShirtPoseTracker.detectTorso(in: cameraFrame))
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: cameraFrame, orientation: .up).perform([segmentation])
        let personMask = CIImage(cvPixelBuffer: try #require(segmentation.results?.first?.pixelBuffer), options: [.colorSpace: NSNull()])
        let personMaskAtFrameSize = personMask
            .transformed(by: CGAffineTransform(scaleX: frameExtent.width / personMask.extent.width, y: frameExtent.height / personMask.extent.height))
            .cropped(to: frameExtent)
        func redChannel(of image: CIImage) -> [UInt8] {
            var rgbaBytes = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image.cropped(to: frameExtent), toBitmap: &rgbaBytes, rowBytes: width * 4, bounds: frameExtent, format: .RGBA8, colorSpace: nil)
            return stride(from: 0, to: rgbaBytes.count, by: 4).map { rgbaBytes[$0] }
        }
        let personBytes = redChannel(of: personMaskAtFrameSize)
        let originalPixels = try #require(rgbaBytes(of: standingPhoto, width: width, height: height))
        let bodyPartsStartedAt = Date()
        let bodyParts = shirtPaintBodyParts(in: standingPhoto)
        print(String(format: "Shirt paint check: Vision read the faces and hands in %.2f s", Date().timeIntervalSince(bodyPartsStartedAt)))
        print("Shirt paint check: \(bodyParts.faceBoxes.count) faces, \(bodyParts.hands.count) hands")

        // The regions measured, from the frame alone, the same for every top.
        let analysisFrame = ShirtSmallFrame(width: width, height: height, rgba: originalPixels, personMask: personBytes, torso: torso)
        let oldShirtColor = try #require(analysisFrame.measureOldShirtColor())
        let analysis = ShirtFrameAnalysis(frame: analysisFrame, oldShirtColor: oldShirtColor)
        let oldShirtLab = ShirtColorMath.lab(red: ShirtColorMath.byte(oldShirtColor.x), green: ShirtColorMath.byte(oldShirtColor.y), blue: ShirtColorMath.byte(oldShirtColor.z))
        let faceRegion = ShirtPaintMask.handAndFaceRegion(bodyParts: ShirtPaintBodyParts(faceBoxes: bodyParts.faceBoxes.map { $0.insetBy(dx: $0.width * 0.1, dy: $0.height * 0.1) }), width: width, height: height, shoulderWidth: torso.shoulderWidth)
        let handRegion = ShirtPaintMask.handAndFaceRegion(bodyParts: ShirtPaintBodyParts(hands: bodyParts.hands.filter { $0.count > 1 }), width: width, height: height, shoulderWidth: 0)
        // The neck is the skin above the neck's base, within the neck's width, below the face.
        let shoulderAxis = SIMD2(Double(torso.imageRightShoulder.x - torso.imageLeftShoulder.x), Double(torso.imageRightShoulder.y - torso.imageLeftShoulder.y)) / torso.shoulderWidth
        var upAxis = SIMD2(shoulderAxis.y, -shoulderAxis.x)
        if upAxis.y > 0 { upAxis = -upAxis }
        let shoulderMiddle = SIMD2(Double(torso.shoulderMidpoint.x), Double(torso.shoulderMidpoint.y))
        let neckBase = shoulderMiddle + upAxis * 0.10 * torso.shoulderWidth
        let neckRegion = (0..<(width * height)).map { index -> Bool in
            let point = SIMD2(Double(index % width), Double(index / width))
            guard personBytes[index] > 127, !faceRegion[index], simd_dot(point - neckBase, upAxis) > 0,
                  abs(simd_dot(point - shoulderMiddle, shoulderAxis)) < 0.25 * torso.shoulderWidth else { return false }
            return ShirtPaintMask.looksLikeSkin(red: originalPixels[index * 4], green: originalPixels[index * 4 + 1], blue: originalPixels[index * 4 + 2])
        }
        let chestBox = CGRect(
            x: torso.shoulderMidpoint.x - 0.3 * torso.shoulderWidth, y: torso.shoulderMidpoint.y + 0.15 * torso.shoulderWidth,
            width: 0.6 * torso.shoulderWidth, height: 0.6 * torso.shoulderWidth
        ).intersection(frameExtent)

        var everyMetric: [ShirtPaintedStillMetrics] = []
        for productPath in productPaths {
            let shirtName = URL(fileURLWithPath: productPath).deletingPathExtension().lastPathComponent
            let productPhoto = scaledLikeThePagePicture(try loadImage(at: URL(fileURLWithPath: productPath)))
            let wholePhoto = RoomArtCorners(
                topLeft: .zero, topRight: CGPoint(x: productPhoto.width, y: 0),
                bottomRight: CGPoint(x: productPhoto.width, y: productPhoto.height), bottomLeft: CGPoint(x: 0, y: productPhoto.height)
            )
            // Only a painting that is paid for needs the color, so the masks and a saved painting can be checked without one.
            let paintsForReal = !reusesSavedPaintings && paintCheckEnvironment["SHIRT_PAINT_MASKS_ONLY"] != "1"
            let baseColorHex = paintCheckEnvironment["SHIRT_PAINT_COLOR_\(shirtName)"] ?? ""
            if paintsForReal, RoomArtClothingReading.uppercasedColorHex(baseColorHex) == nil {
                Issue.record("Set SHIRT_PAINT_COLOR_\(shirtName) to the cloth's main color as #RRGGBB, as the page reader would name it. There is none, or it is not #RRGGBB, so no painting is made for \(shirtName).")
                continue
            }
            print("Shirt paint check: \(shirtName) cloth \(baseColorHex.isEmpty ? "(none needed)" : baseColorHex), \(garmentKind) \(garmentSleeves) sleeves to the \(garmentLength)\(usesTheGhostOutline ? ", ghost outline" : "")")
            // The live preview draws the garment over the learner. The ghost outline draws nothing on the camera.
            let previewImage: CGImage
            let previewCoverage: [UInt8]
            if usesTheGhostOutline {
                previewImage = standingPhoto
                previewCoverage = [UInt8](repeating: 0, count: width * height)
            } else {
                let garment = try #require(ShirtGarment.make(productPhoto: productPhoto, itemCorners: wholePhoto), "no garment in \(shirtName)")
                let renderer = ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false)
                for _ in 0..<8 { _ = renderer.composition(frame: frame, personMask: personMask, torso: torso, garment: garment) }
                let composition = try #require(renderer.composition(frame: frame, personMask: personMask, torso: torso, garment: garment))
                previewImage = try #require(context.createCGImage(composition.image.cropped(to: frameExtent), from: frameExtent, format: .RGBA8, colorSpace: sRGB))
                previewCoverage = redChannel(of: composition.totalAlpha)
            }
            let frozenFrame = ShirtFrozenFrame(
                cameraImage: standingPhoto, previewImage: previewImage, personMask: personBytes,
                previewGarmentCoverage: previewCoverage, torso: torso
            )
            let maskStartedAt = Date()
            let masks = try #require(ShirtPaintMask.make(frame: frozenFrame, bodyParts: bodyParts, coverage: coverage))
            print(String(format: "Shirt paint check: %@ mask made in %.2f s, %.1f%% of the frame", shirtName, Date().timeIntervalSince(maskStartedAt), masks.paintableShare * 100))
            let maskOverlay = originalPixels.enumerated().map { byteIndex, value -> UInt8 in
                let pixelIndex = byteIndex / 4, channel = byteIndex % 4
                guard channel < 3 else { return 255 }
                if masks.protected[pixelIndex] == 255 { return channel == 1 ? 220 : value / 2 }
                if masks.paintable[pixelIndex] > 127 { return channel == 0 ? 255 : (channel == 2 ? 160 : value / 2) }
                return value
            }
            // The two outlines the loop traces: the learner's own top (yellow) and the area being painted (cyan).
            let maskOverlayContext = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            maskOverlayContext.draw(try #require(rgbImage(bytes: maskOverlay, width: width, height: height)), in: frameExtent)
            maskOverlayContext.translateBy(x: 0, y: CGFloat(height))
            maskOverlayContext.scaleBy(x: 1, y: -1)
            let outlineScale = Double(ShirtPaintMask.outlineLongestSide) / Double(max(width, height))
            let smallWidth = Int((Double(width) * outlineScale).rounded()), smallHeight = Int((Double(height) * outlineScale).rounded())
            let ownTopOutline = ShirtPaintMask.oldGarmentArea(
                rgba: try #require(rgbaBytes(of: standingPhoto, width: smallWidth, height: smallHeight)),
                personMask: try #require(ShirtPaintMask.resizedGrayBytes(personBytes, width: width, height: height, toWidth: smallWidth, toHeight: smallHeight)),
                torso: torso.scaled(by: Double(smallWidth) / Double(width)), width: smallWidth, height: smallHeight
            ).flatMap { ShirtOutline.outline(of: $0, width: smallWidth, height: smallHeight) }.map { ShirtOutline.scaled($0, fromMaskScale: Double(smallWidth) / Double(width)) }
            for (outline, color) in [(ownTopOutline, CGColor(red: 1, green: 0.85, blue: 0, alpha: 1)), (ShirtPaintMask.outlineOfThePaintableArea(masks), CGColor(red: 0, green: 0.9, blue: 1, alpha: 1))] {
                guard let outline, let path = RoomArtLoopOutline.closedPath(through: outline) else { continue }
                maskOverlayContext.setStrokeColor(color)
                maskOverlayContext.setLineWidth(4)
                maskOverlayContext.addPath(path.cgPath)
                maskOverlayContext.strokePath()
                print("Shirt paint check: \(shirtName) outline of \(outline.count) points")
            }
            try savePNG(try #require(maskOverlayContext.makeImage()), to: outputFolder.appendingPathComponent("mask-\(shirtName).png"))
            // SHIRT_PAINT_MASKS_ONLY=1 checks the masks by eye before any painting is paid for.
            if paintCheckEnvironment["SHIRT_PAINT_MASKS_ONLY"] == "1" { continue }

            let paintedURL = outputFolder.appendingPathComponent("painted-\(shirtName).png")
            // The Worker's reply before the paste, so SHIRT_PAINT_REUSE=1 pastes it again with the paste as it is now.
            let replyURL = outputFolder.appendingPathComponent("reply-\(shirtName).png")
            let startedAt = Date()
            let painted: CGImage
            if reusesSavedPaintings {
                if FileManager.default.fileExists(atPath: replyURL.path) {
                    painted = try #require(shirtPaintedStillPasted(keyframe: standingPhoto, painted: try loadImage(at: replyURL), masks: masks, context: context))
                    try savePNG(painted, to: paintedURL)
                } else {
                    // A painting saved before the reply was kept can only be judged as it was pasted then.
                    painted = try loadImage(at: paintedURL)
                }
            } else {
                let productJPEG = try #require(shirtPaintingProductJPEG(picture: productPhoto, itemCorners: wholePhoto))
                let client = ShirtPaintingClient(workerBaseURL: try #require(paintCheckEnvironment["SHIRT_PAINT_WORKER"]))
                let reply = try await client.paintedReply(ShirtPaintingRequest(
                    keyframe: standingPhoto, productJPEG: productJPEG, masks: masks, itemTitle: shirtName,
                    garment: ShirtPaintingGarment(
                        kind: garmentKind, sleeves: garmentSleeves, length: garmentLength, baseColorHex: baseColorHex.uppercased(),
                        printDescription: paintCheckEnvironment["SHIRT_PAINT_PRINT_\(shirtName)"] ?? ""
                    )
                ))
                try savePNG(reply, to: replyURL)
                painted = try #require(shirtPaintedStillPasted(keyframe: standingPhoto, painted: reply, masks: masks, context: context))
                try savePNG(painted, to: paintedURL)
            }
            let paintedPixels = try #require(rgbaBytes(of: painted, width: width, height: height))
            let previewPixels = try #require(rgbaBytes(of: previewImage, width: width, height: height))

            func exactShare(_ region: [Bool]) -> Double {
                var count = 0, exact = 0
                for index in region.indices where region[index] {
                    count += 1
                    if (0..<3).allSatisfy({ paintedPixels[index * 4 + $0] == originalPixels[index * 4 + $0] }) { exact += 1 }
                }
                return count > 0 ? Double(exact) / Double(count) : 1
            }
            // A pixel of the old top is left showing when it and its whole 7 by 7 neighborhood are as they were, as a leftover
            // sleeve stub or hem is. A single pixel of a new navy stripe can land within a few levels of an old navy top.
            let unchanged = (0..<(width * height)).map { index in
                (0..<3).allSatisfy { abs(Int(paintedPixels[index * 4 + $0]) - Int(originalPixels[index * 4 + $0])) < 6 }
            }
            let unchangedPatch = ShirtPaintMask.eroded(unchanged, width: width, height: height, radius: 3)
            var oldTopPixels = 0, oldTopStillShowing = 0
            for index in 0..<(width * height) where masks.oldShirt[index] > 127 {
                oldTopPixels += 1
                let lab = ShirtColorMath.quickLab(red: paintedPixels[index * 4], green: paintedPixels[index * 4 + 1], blue: paintedPixels[index * 4 + 2])
                if unchangedPatch[index] && ShirtColorMath.distance(from: lab, to: oldShirtLab) < ShirtColorMath.oldShirtDistanceLimit { oldTopStillShowing += 1 }
            }
            var metrics = ShirtPaintedStillMetrics()
            metrics.shirtName = shirtName
            metrics.paintableShareOfTheFrame = masks.paintableShare
            metrics.oldTopLeftShowingShare = Double(oldTopStillShowing) / Double(max(oldTopPixels, 1))
            metrics.faceExactShare = exactShare(faceRegion)
            metrics.handsExactShare = exactShare(handRegion)
            // The neck fades in over a few pixels inside its edge, so its edge pixels are a blend and only the rest is exact.
            metrics.neckExactShare = exactShare(ShirtPaintMask.eroded(
                neckRegion, width: width, height: height, radius: ShirtPaintMask.neckEdgeFadePixels + ShirtPaintMask.neckEdgeSmoothingRadiusPixels
            ))
            metrics.printSharpnessAgainstThePreview = meanGradient(of: paintedPixels, width: width, box: chestBox) / max(meanGradient(of: previewPixels, width: width, box: chestBox), 0.001)

            // The old top at the neck: pixels in the band where the new collar meets the neck that the paste put back as
            // filmed (within 2 levels) and that look like the old top, as its collar and the tops of its shoulders did when
            // they showed between the new collar and the neck. Counted per shoulder width. Darkness alone cannot tell them
            // from a neck in shadow.
            var oldTopAtTheNeckPixels = 0
            for index in 0..<(width * height) where personBytes[index] > 127 && !faceRegion[index] {
                let point = SIMD2(Double(index % width), Double(index / width))
                let aboveTheNeckBase = simd_dot(point - neckBase, upAxis)
                guard abs(simd_dot(point - shoulderMiddle, shoulderAxis)) < 0.4 * torso.shoulderWidth,
                      aboveTheNeckBase > -0.15 * torso.shoulderWidth, aboveTheNeckBase < 0.15 * torso.shoulderWidth,
                      (0..<3).allSatisfy({ abs(Int(paintedPixels[index * 4 + $0]) - Int(originalPixels[index * 4 + $0])) <= 2 }) else { continue }
                let lab = ShirtColorMath.quickLab(red: paintedPixels[index * 4], green: paintedPixels[index * 4 + 1], blue: paintedPixels[index * 4 + 2])
                if ShirtColorMath.distance(from: lab, to: oldShirtLab) < ShirtColorMath.oldShirtDistanceLimit { oldTopAtTheNeckPixels += 1 }
            }
            metrics.oldTopAtTheNeckPixelsPerShoulderWidth = Double(oldTopAtTheNeckPixels) / torso.shoulderWidth
            // The bare arms and the room beside them, where the new top does not reach and the painting may not draw, are
            // as filmed: the share of their pixels more than 8 levels off. The gap the put-back leaves beside the painting
            // for the new sleeve's edge, the pixels inside its fade, and the hands are left out.
            let paintableRegion = masks.paintable.map { $0 > 127 }
            let newGarmentCovers = coverage.area(for: torso).mask(width: width, height: height)
            let armGapPixels = Int((ShirtPaintMask.armGapInShoulderWidths * torso.shoulderWidth).rounded())
            let nearThePainting = ShirtPaintMask.dilated(
                zip(paintableRegion, newGarmentCovers).map { $0 || $1 }, width: width, height: height,
                radius: armGapPixels + ShirtPaintMask.armEdgeSmoothingRadiusPixels + ShirtPaintMask.armEdgeFadePixels + 1
            )
            let armZone = ShirtPaintMask.armZone(torso: torso, width: width, height: height)
            var armPixels = 0, armPixelsChanged = 0
            for index in 0..<(width * height) where armZone[index] && !nearThePainting[index] && !handRegion[index] {
                armPixels += 1
                if (0..<3).contains(where: { abs(Int(paintedPixels[index * 4 + $0]) - Int(originalPixels[index * 4 + $0])) > 8 }) { armPixelsChanged += 1 }
            }
            metrics.bareArmsChangedShare = Double(armPixelsChanged) / Double(max(armPixels, 1))
            metrics.seconds = Date().timeIntervalSince(startedAt)
            everyMetric.append(metrics)
            print("Shirt paint check: \(shirtName) \(String(data: try JSONEncoder().encode(metrics), encoding: .utf8) ?? "")")

            let product = try loadImage(at: URL(fileURLWithPath: productPath))
            if let sheet = sideBySide([standingPhoto, product, previewImage, painted], height: 720) {
                try savePNG(sheet, to: outputFolder.appendingPathComponent("side-by-side-\(shirtName).png"))
            }
            #expect(metrics.oldTopLeftShowingShare < 0.01, "\(shirtName): old top left showing")
            #expect(metrics.faceExactShare == 1 && metrics.handsExactShare == 1 && metrics.neckExactShare == 1, "\(shirtName): face, hands, neck")
            #expect(metrics.oldTopAtTheNeckPixelsPerShoulderWidth < 0.1, "\(shirtName): the old top put back at the neck")
            #expect(metrics.bareArmsChangedShare < 0.002, "\(shirtName): the bare arms or the room beside them repainted")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(everyMetric).write(to: outputFolder.appendingPathComponent("painted-metrics.json"))
    }
}
