//
//  ShirtOnModelLookCheckTests.swift
//  leanring-buddyTests
//
//  The look check for a shirt from a photo of it worn by a model (ShirtOnModel.swift): real store photos of T-shirts on
//  models drawn on the same standing photo as ShirtLookCheckTests, held to the same limits as a flat lay, plus what only an
//  on-model photo can get wrong:
//  - the neck: the model's own neck must leave a hole, so no garment pixel lands on the learner's neck above the collar;
//  - the shoulder seam: the torso and each sleeve are mapped apart, so no gap may open between them;
//  - the sleeves: each must stay on its arm, neither turned off it into the room nor left with the arm coming out of it.
//  It runs only when SHIRT_TRYON_PHOTOS_DIR names the folder with standing.jpg and an `on-model` folder of model-*.jpg
//  product photos, and SHIRT_TRYON_OUTPUT_DIR names where the composites and their numbers go:
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos SHIRT_TRYON_OUTPUT_DIR=/path/out tools/swift-check.sh --filter ShirtOnModelLookCheck
//  The photos are personal or a store's, so they are never committed.
//

import CoreGraphics
import CoreImage
import Foundation
import Testing
import Vision
@testable import Clicky

private let onModelLookCheckEnvironment = ProcessInfo.processInfo.environment

/// What an on-model shirt is judged by beyond `ShirtLookMetrics`.
struct ShirtOnModelLookMetrics: Codable {
    var look = ShirtLookMetrics()
    /// The share of the learner's neck above the old collar that the garment covers. The neck is the person, in the run around
    /// the body's middle, from half a shoulder width above the shoulders down to 0.03 shoulder widths above the old collar.
    var neckCoveredShare = 0.0
    var neckPixelCount = 0
    /// For each sleeve, image left first, the share of points along its seam, on the person, that the garment leaves bare.
    var shoulderSeamGapShares: [Double] = []
    /// For each sleeve, image left first, how far its drawn axis turns from its upper arm, in degrees.
    var sleeveAngleOffTheArmDegrees: [Double] = []
}

enum ShirtOnModelLookLimits {
    static let neckCoveredShare = 0.01
    static let shoulderSeamGapShare = 0.02
    /// A short sleeve stands off a hanging arm, on a model as on the learner, but never this far.
    static let sleeveAngleOffTheArmDegrees = 35.0
}

/// The standing photo, its pose and person mask, read once and shared by every shirt.
struct ShirtLookScene {
    let frame: CIImage
    let frameExtent: CGRect
    let torso: BodyTorso
    let personMask: CIImage
    let original: LookPixels
    let person: LookPixels
    let fullSizeFrame: ShirtSmallFrame
    let oldShirtColor: SIMD3<Float>

    init(photosFolder: URL, context: CIContext) throws {
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let standingPhoto = try loadImage(at: photosFolder.appendingPathComponent("standing.jpg"))
        frame = CIImage(cgImage: standingPhoto)
        frameExtent = frame.extent
        var frameBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, standingPhoto.width, standingPhoto.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frameBuffer)
        let cameraFrame = try #require(frameBuffer)
        context.render(frame, to: cameraFrame, bounds: frameExtent, colorSpace: sRGB)
        torso = try #require(ShirtPoseTracker.detectTorso(in: cameraFrame))
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: cameraFrame, orientation: .up).perform([segmentation])
        personMask = CIImage(cvPixelBuffer: try #require(segmentation.results?.first?.pixelBuffer), options: [.colorSpace: NSNull()])
        let personMaskExtent = personMask.extent
        let personMaskAtFrameSize = personMask
            .transformed(by: CGAffineTransform(scaleX: frameExtent.width / personMaskExtent.width, y: frameExtent.height / personMaskExtent.height))
            .cropped(to: frameExtent)
        original = LookPixels(frame, extent: frameExtent, context: context, colorSpace: sRGB)
        person = LookPixels(personMaskAtFrameSize, extent: frameExtent, context: context, colorSpace: nil)
        let original = original, person = person
        fullSizeFrame = ShirtSmallFrame(
            width: original.width, height: original.height, rgba: original.bytes,
            personMask: (0..<(original.width * original.height)).map { person.channel(0, at: $0) }, torso: torso
        )
        oldShirtColor = try #require(fullSizeFrame.measureOldShirtColor())
    }
}

/// The on-model measures of one composite.
private func measureOnModel(
    composition: ShirtTryOnComposition, garmentAlpha: LookPixels, scene: ShirtLookScene, modelPose: ShirtModelPose
) -> (neckCoveredShare: Double, neckPixelCount: Int, seamGaps: [Double], sleeveAngles: [Double]) {
    let width = scene.original.width, height = scene.original.height
    let torso = scene.torso
    let shoulderWidth = torso.shoulderWidth
    let middle = torso.shoulderMidpoint

    // The neck: the learner's own collar row, found the renderer's way at full size.
    var neckPixelCount = 0, neckCoveredCount = 0
    if let collarRow = scene.fullSizeFrame.bodyNeckRow(oldShirtColor: scene.oldShirtColor) {
        let topRow = max(0, Int(middle.y - 0.5 * shoulderWidth)), bottomRow = min(height - 1, Int(collarRow - 0.03 * shoulderWidth))
        if topRow < bottomRow {
            for row in topRow...bottomRow {
                // The run of confident person around the middle column, within a quarter of a shoulder width of it.
                let middleColumn = Int(middle.x)
                guard middleColumn >= 0, middleColumn < width, scene.person.channel(0, at: row * width + middleColumn) >= 230 else { continue }
                var left = middleColumn, right = middleColumn
                let reach = Int(0.25 * shoulderWidth)
                while left > max(0, middleColumn - reach), scene.person.channel(0, at: row * width + left - 1) >= 230 { left -= 1 }
                while right < min(width - 1, middleColumn + reach), scene.person.channel(0, at: row * width + right + 1) >= 230 { right += 1 }
                for column in left...right {
                    neckPixelCount += 1
                    if garmentAlpha.channel(0, at: row * width + column) >= 128 { neckCoveredCount += 1 }
                }
            }
        }
    }

    // Each sleeve's seam, from its top to its bottom, sampled every pixel: bare where the garment and the 2 pixels on each
    // side of the point across the seam are all under half covered.
    var seamGaps: [Double] = []
    var sleeveAngles: [Double] = []
    for sleeve in composition.sleeves {
        let seamTop = SIMD2(Double(sleeve.landing[0].x), Double(sleeve.landing[0].y)), seamBottom = SIMD2(Double(sleeve.landing[3].x), Double(sleeve.landing[3].y))
        let seam = seamBottom - seamTop, seamLength = simd_length(seam)
        var onThePerson = 0, bare = 0
        if seamLength > 1 {
            let across = SIMD2(-seam.y, seam.x) / seamLength
            for step in 0...Int(seamLength) {
                let point = seamTop + seam * (Double(step) / seamLength)
                let column = Int(point.x), row = Int(point.y)
                guard column >= 2, column < width - 2, row >= 0, row < height, scene.person.channel(0, at: row * width + column) >= 230 else { continue }
                onThePerson += 1
                let covered = (-2...2).contains { offset in
                    let sample = point + across * Double(offset)
                    let sampleColumn = Int(sample.x), sampleRow = Int(sample.y)
                    guard sampleColumn >= 0, sampleColumn < width, sampleRow >= 0, sampleRow < height else { return false }
                    return garmentAlpha.channel(0, at: sampleRow * width + sampleColumn) >= 128
                }
                if !covered { bare += 1 }
            }
        }
        seamGaps.append(Double(bare) / Double(max(onThePerson, 1)))
        let isImageLeft = sleeve.side == .imageLeft
        if let elbow = isImageLeft ? torso.imageLeftElbow : torso.imageRightElbow {
            let shoulder = isImageLeft ? torso.imageLeftShoulder : torso.imageRightShoulder
            let arm = simd_normalize(SIMD2(Double(elbow.x - shoulder.x), Double(elbow.y - shoulder.y)))
            let axis = simd_normalize(SIMD2(Double(sleeve.axis.dx), Double(sleeve.axis.dy)))
            sleeveAngles.append(acos(max(-1, min(1, simd_dot(arm, axis)))) * 180 / .pi)
        }
    }
    return (Double(neckCoveredCount) / Double(max(neckPixelCount, 1)), neckPixelCount, seamGaps, sleeveAngles)
}

struct ShirtOnModelLookCheckTests {
    @Test(.enabled(if: onModelLookCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil && onModelLookCheckEnvironment["SHIRT_TRYON_OUTPUT_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR and SHIRT_TRYON_OUTPUT_DIR"))
    func eachShirtOnAModelLooksWornInTheRoom() throws {
        let photosFolder = URL(fileURLWithPath: try #require(onModelLookCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let onModelFolder = photosFolder.appendingPathComponent("on-model")
        let outputFolder = URL(fileURLWithPath: try #require(onModelLookCheckEnvironment["SHIRT_TRYON_OUTPUT_DIR"]))
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let context = CIContext()
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let scene = try ShirtLookScene(photosFolder: photosFolder, context: context)

        let photoNames = try FileManager.default.contentsOfDirectory(atPath: onModelFolder.path).filter { $0.hasPrefix("model-") && $0.hasSuffix(".jpg") }.sorted()
        #expect(photoNames.count >= 5)
        var everyShirtsMetrics: [ShirtOnModelLookMetrics] = []
        for photoName in photoNames {
            let shirtName = photoName.replacingOccurrences(of: ".jpg", with: "")
            let productPhoto = try loadImage(at: onModelFolder.appendingPathComponent(photoName))
            let wholePhoto = RoomArtCorners(
                topLeft: .zero, topRight: CGPoint(x: productPhoto.width, y: 0),
                bottomRight: CGPoint(x: productPhoto.width, y: productPhoto.height), bottomLeft: CGPoint(x: 0, y: productPhoto.height)
            )
            let madeAt = Date()
            let garment = try #require(ShirtGarment.make(onModelPhoto: productPhoto, itemCorners: wholePhoto), "no garment found in \(photoName)")
            let modelPose = try #require(garment.modelPose)
            print("Shirt on-model look check: \(shirtName) corners \(garment.torsoCorners.clockwiseFromTopLeft) neck \(garment.frontNeckPoint)")
            print("Shirt on-model look check: \(shirtName) garment made in \(Int(Date().timeIntervalSince(madeAt) * 1000)) ms, \(garment.sleeves.count) sleeves apart")
            let renderer = ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false)
            for _ in 0..<8 { _ = renderer.composition(frame: scene.frame, personMask: scene.personMask, torso: scene.torso, garment: garment) }
            let composition = try #require(renderer.composition(frame: scene.frame, personMask: scene.personMask, torso: scene.torso, garment: garment))

            print("Shirt on-model look check: \(shirtName) landed \(composition.landedTorsoCorners)")
            let garmentAlpha = LookPixels(composition.garmentAlpha, extent: scene.frameExtent, context: context, colorSpace: nil)
            let inputs = LookInputs(
                original: scene.original, composite: LookPixels(composition.image, extent: scene.frameExtent, context: context, colorSpace: sRGB), person: scene.person,
                garmentAlpha: garmentAlpha, totalAlpha: LookPixels(composition.totalAlpha, extent: scene.frameExtent, context: context, colorSpace: nil),
                warpedGarment: LookPixels(composition.warpedGarmentColor, extent: scene.frameExtent, context: context, colorSpace: sRGB),
                sleeves: sleeveLayers(of: composition, torso: scene.torso), landedTorsoCorners: composition.landedTorsoCorners, torso: scene.torso,
                oldShirtColor: scene.oldShirtColor, photoWhite: productPhotoWhite(productPhoto: productPhoto, garment: garment, context: context)
            )
            var metrics = ShirtOnModelLookMetrics(look: measure(inputs, shirtName: shirtName))
            let onModel = measureOnModel(composition: composition, garmentAlpha: garmentAlpha, scene: scene, modelPose: modelPose)
            metrics.neckCoveredShare = onModel.neckCoveredShare
            metrics.neckPixelCount = onModel.neckPixelCount
            metrics.shoulderSeamGapShares = onModel.seamGaps
            metrics.sleeveAngleOffTheArmDegrees = onModel.sleeveAngles
            everyShirtsMetrics.append(metrics)

            let rendered = try #require(context.createCGImage(composition.image, from: scene.frameExtent, format: .RGBA8, colorSpace: sRGB))
            try savePNG(rendered, to: outputFolder.appendingPathComponent("on-model-\(shirtName).png"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metrics).write(to: outputFolder.appendingPathComponent("on-model-\(shirtName).json"))
            print("Shirt on-model look check: \(shirtName) \(String(data: try JSONEncoder().encode(metrics), encoding: .utf8) ?? "")")

            let look = metrics.look
            #expect(look.clippedShareOfTheGarment <= look.clippedShareOfTheOriginal + ShirtLookLimits.clippingAllowanceOverTheOriginal, "\(shirtName): clipping")
            #expect(ShirtLookLimits.exposureRatioRange.contains(look.exposureRatio), "\(shirtName): exposure ratio \(look.exposureRatio)")
            if let whiteBalanceDeltaE = look.whiteBalanceDeltaE {
                #expect(whiteBalanceDeltaE <= ShirtLookLimits.whiteBalanceDeltaE, "\(shirtName): white balance")
            }
            #expect(look.shadingCorrelation >= ShirtLookLimits.shadingCorrelation, "\(shirtName): shading")
            #expect(look.haloOutsideExcessOverTheOriginal < ShirtLookLimits.haloOutsideExcessOverTheOriginal, "\(shirtName): halo outside")
            #expect(look.haloInsideWorstRimRatio <= ShirtLookLimits.haloInsideRimRatio, "\(shirtName): halo inside")
            #expect(look.oldShirtStillShowingShare < ShirtLookLimits.oldShirtStillShowingShare, "\(shirtName): old shirt")
            #expect(look.sleeveAxisErrorsDegrees.count == 2, "\(shirtName): both sleeves drawn apart")
            for armPastTheSleeve in look.sleeveAxisErrorsDegrees {
                #expect(armPastTheSleeve <= ShirtLookLimits.sleeveAxisErrorDegrees, "\(shirtName): the arm comes out of its sleeve")
            }
            #expect(look.oldShirtAtTheSleevesShare < ShirtLookLimits.oldShirtAtTheSleevesShare, "\(shirtName): old shirt at the sleeves")
            #expect(look.darkOutlinePixelsPerShoulderWidth < ShirtLookLimits.darkOutlinePixelsPerShoulderWidth, "\(shirtName): dark line along the outline")
            #expect(metrics.neckPixelCount > 0, "\(shirtName): the neck was measured")
            #expect(metrics.neckCoveredShare <= ShirtOnModelLookLimits.neckCoveredShare, "\(shirtName): garment on the learner's neck")
            #expect(metrics.shoulderSeamGapShares.count == 2, "\(shirtName): both seams measured")
            for seamGap in metrics.shoulderSeamGapShares {
                #expect(seamGap <= ShirtOnModelLookLimits.shoulderSeamGapShare, "\(shirtName): gap at the shoulder seam")
            }
            for angle in metrics.sleeveAngleOffTheArmDegrees {
                #expect(angle <= ShirtOnModelLookLimits.sleeveAngleOffTheArmDegrees, "\(shirtName): sleeve turned off its arm")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(everyShirtsMetrics).write(to: outputFolder.appendingPathComponent("on-model-metrics.json"))
    }
}
