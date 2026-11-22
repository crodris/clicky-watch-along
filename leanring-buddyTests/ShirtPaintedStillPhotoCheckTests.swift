//
//  ShirtPaintedStillPhotoCheckTests.swift
//  leanring-buddyTests
//
//  Paints real store tops onto a real photo of a person through the real Worker, with the app's own pose, person mask, live
//  preview, paint mask, client, and paste, and measures what the painted still must get right. It runs only with
//  SHIRT_TRYON_PHOTOS_DIR (a folder with standing.jpg, a personal photo that is never committed), SHIRT_PAINT_PRODUCTS
//  (product photo paths, joined with commas), SHIRT_PAINT_OUTPUT_DIR, SHIRT_PAINT_WORKER (a local Worker's base URL), and
//  SHIRT_PAINT_APP_SECRET. Each painting costs an OpenAI image edit (about $0.06), so SHIRT_PAINT_REUSE=1 judges the
//  paintings an earlier run saved with no new call, and SHIRT_PAINT_MASKS_ONLY=1 writes only the masks:
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos SHIRT_PAINT_PRODUCTS=/path/a.jpg,/path/b.jpg SHIRT_PAINT_OUTPUT_DIR=/path/out \
//  SHIRT_PAINT_WORKER=http://localhost:8794 SHIRT_PAINT_APP_SECRET=... tools/swift-check.sh --filter ShirtPaintedStillPhotoCheck
//
//  The numbers, per painting:
//  - the old top left showing: the share of the old top's pixels that look like it and are as they were;
//  - the face, the hands, and the neck: the share of each one's pixels that are byte for byte as filmed;
//  - print sharpness: the painting's mean gradient over the chest against the live preview's, which is the product photo
//    warped onto the same chest, so 1 is as sharp as the product.
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
    var seconds = 0.0
}

private func loadImage(at url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func savePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
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
    var x = gap
    for (image, scaledWidth) in zip(images, scaledWidths) {
        context.draw(image, in: CGRect(x: x, y: gap, width: scaledWidth, height: height))
        x += scaledWidth + gap
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
            let garment = try #require(ShirtGarment.make(productPhoto: productPhoto, itemCorners: wholePhoto), "no garment in \(shirtName)")
            let renderer = ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false)
            for _ in 0..<8 { _ = renderer.composition(frame: frame, personMask: personMask, torso: torso, garment: garment) }
            let composition = try #require(renderer.composition(frame: frame, personMask: personMask, torso: torso, garment: garment))
            let previewImage = try #require(context.createCGImage(composition.image.cropped(to: frameExtent), from: frameExtent, format: .RGBA8, colorSpace: sRGB))
            let frozenFrame = ShirtFrozenFrame(
                cameraImage: standingPhoto, previewImage: previewImage, personMask: personBytes,
                previewGarmentCoverage: redChannel(of: composition.totalAlpha), torso: torso
            )
            let maskStartedAt = Date()
            let masks = try #require(ShirtPaintMask.make(frame: frozenFrame, bodyParts: bodyParts))
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
            let startedAt = Date()
            let painted: CGImage
            if reusesSavedPaintings {
                painted = try loadImage(at: paintedURL)
            } else {
                let productJPEG = try #require(shirtPaintingProductJPEG(picture: productPhoto, itemCorners: wholePhoto))
                let client = ShirtPaintingClient(workerBaseURL: try #require(paintCheckEnvironment["SHIRT_PAINT_WORKER"]))
                painted = try await client.paint(ShirtPaintingRequest(
                    keyframe: standingPhoto, productJPEG: productJPEG, masks: masks, itemTitle: shirtName,
                    garment: ShirtPaintingGarment(kind: .tshirt, sleeves: .short, baseColorHex: sRGBHex(ofLinear: garment.baseColor), printDescription: paintCheckEnvironment["SHIRT_PAINT_PRINT_\(shirtName)"] ?? "")
                ))
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
            var oldTopPixels = 0, oldTopStillShowing = 0
            for index in 0..<(width * height) where masks.oldShirt[index] > 127 {
                oldTopPixels += 1
                let unchanged = (0..<3).allSatisfy { abs(Int(paintedPixels[index * 4 + $0]) - Int(originalPixels[index * 4 + $0])) < 6 }
                let lab = ShirtColorMath.quickLab(red: paintedPixels[index * 4], green: paintedPixels[index * 4 + 1], blue: paintedPixels[index * 4 + 2])
                if unchanged && ShirtColorMath.distance(from: lab, to: oldShirtLab) < ShirtColorMath.oldShirtDistanceLimit { oldTopStillShowing += 1 }
            }
            var metrics = ShirtPaintedStillMetrics()
            metrics.shirtName = shirtName
            metrics.paintableShareOfTheFrame = masks.paintableShare
            metrics.oldTopLeftShowingShare = Double(oldTopStillShowing) / Double(max(oldTopPixels, 1))
            metrics.faceExactShare = exactShare(faceRegion)
            metrics.handsExactShare = exactShare(handRegion)
            metrics.neckExactShare = exactShare(neckRegion)
            metrics.printSharpnessAgainstThePreview = meanGradient(of: paintedPixels, width: width, box: chestBox) / max(meanGradient(of: previewPixels, width: width, box: chestBox), 0.001)
            metrics.seconds = Date().timeIntervalSince(startedAt)
            everyMetric.append(metrics)
            print("Shirt paint check: \(shirtName) \(String(data: try JSONEncoder().encode(metrics), encoding: .utf8) ?? "")")

            let product = try loadImage(at: URL(fileURLWithPath: productPath))
            if let sheet = sideBySide([standingPhoto, product, previewImage, painted], height: 720) {
                try savePNG(sheet, to: outputFolder.appendingPathComponent("side-by-side-\(shirtName).png"))
            }
            #expect(metrics.oldTopLeftShowingShare < 0.01, "\(shirtName): old top left showing")
            #expect(metrics.faceExactShare == 1 && metrics.handsExactShare == 1 && metrics.neckExactShare == 1, "\(shirtName): face, hands, neck")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(everyMetric).write(to: outputFolder.appendingPathComponent("painted-metrics.json"))
    }
}
