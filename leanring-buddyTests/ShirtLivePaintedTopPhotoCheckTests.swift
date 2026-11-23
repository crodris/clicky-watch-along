//
//  ShirtLivePaintedTopPhotoCheckTests.swift
//  leanring-buddyTests
//
//  Measures the live painted top on a real photo of a person and a painting an earlier ShirtPaintedStillPhotoCheck run saved,
//  so nothing is paid for. It runs only with SHIRT_TRYON_PHOTOS_DIR (a folder with standing.jpg, a personal photo that is never
//  committed), SHIRT_PAINT_OUTPUT_DIR (the folder that run wrote, holding painted-<name>.png), and SHIRT_PAINT_PRODUCTS (the
//  products' paths, joined with commas: only each file's name is used, to find its painting). The garment's cut is named by
//  SHIRT_PAINT_SLEEVES and SHIRT_PAINT_LENGTH, as in that check, and must be the cut the painting was made with:
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos SHIRT_PAINT_OUTPUT_DIR=/path/out SHIRT_PAINT_PRODUCTS=/path/whitetee.jpg \
//  tools/swift-check.sh --filter ShirtLivePaintedTopPhotoCheck
//
//  The live frame is made up from the standing photo: the photo, its person mask, and its torso are moved together by a known
//  transform (a 30 pixel shift, a scale of 0.9, a roll of 8 degrees), which the live top must follow, and an arm raised 40
//  degrees, which must put the top out of reach so the painted still shows. For each followed pose it measures the live
//  composite against the painted still moved by the same transform, inside the person, and writes the pictures to
//  SHIRT_PAINT_OUTPUT_DIR/live/:
//  - the mean absolute difference, in 8-bit levels, and the share of pixels off by more than 24 levels, inside the person and
//    inside the top;
//  - the same for the moved photo alone, which has no painted top, so the numbers above can be read against what the painting
//    changed;
//  - the old top left showing: the share of the old top's pixels that still look like it, as the painted still check counts it.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
import Vision
@testable import Clicky

private let liveCheckEnvironment = ProcessInfo.processInfo.environment

struct ShirtLivePaintedTopMetrics: Codable {
    var shirtName = ""
    var pose = ""
    var followed = false
    var meanDifferenceInThePerson = 0.0
    var shareOffByMoreThan24InThePerson = 0.0
    var meanDifferenceInTheTop = 0.0
    var shareOffByMoreThan24InTheTop = 0.0
    /// The moved photo alone, with no painted top, against the same reference, inside the top.
    var photoAloneMeanDifferenceInTheTop = 0.0
    var oldTopLeftShowingShare = 0.0
}

@MainActor
struct ShirtLivePaintedTopPhotoCheckTests {
    @Test(.enabled(if: ["SHIRT_TRYON_PHOTOS_DIR", "SHIRT_PAINT_OUTPUT_DIR", "SHIRT_PAINT_PRODUCTS"].allSatisfy { liveCheckEnvironment[$0] != nil }, "Set SHIRT_TRYON_PHOTOS_DIR, SHIRT_PAINT_OUTPUT_DIR, and SHIRT_PAINT_PRODUCTS"))
    func thePaintedTopFollowsAMovedLearnerAndStepsAsideForARaisedArm() throws {
        let photosFolder = URL(fileURLWithPath: try #require(liveCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let paintingsFolder = URL(fileURLWithPath: try #require(liveCheckEnvironment["SHIRT_PAINT_OUTPUT_DIR"]))
        let outputFolder = paintingsFolder.appendingPathComponent("live")
        let productPaths = try #require(liveCheckEnvironment["SHIRT_PAINT_PRODUCTS"]).split(separator: ",").map(String.init)
        let sleeves = try #require(RoomArtSleeves(rawValue: liveCheckEnvironment["SHIRT_PAINT_SLEEVES"] ?? "short"), "SHIRT_PAINT_SLEEVES is none, short, or long")
        let length = try #require(RoomArtGarmentLength(rawValue: liveCheckEnvironment["SHIRT_PAINT_LENGTH"] ?? "hip"), "SHIRT_PAINT_LENGTH names no length")
        let coverage = ShirtCoverage(sleeves: sleeves, length: length)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

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
        let rawPersonMask = CIImage(cvPixelBuffer: try #require(segmentation.results?.first?.pixelBuffer), options: [.colorSpace: NSNull()])
        let personMask = rawPersonMask
            .transformed(by: CGAffineTransform(scaleX: frameExtent.width / rawPersonMask.extent.width, y: frameExtent.height / rawPersonMask.extent.height))
            .cropped(to: frameExtent)
        func redChannel(of image: CIImage) -> [UInt8] {
            var rgbaBytes = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image.cropped(to: frameExtent), toBitmap: &rgbaBytes, rowBytes: width * 4, bounds: frameExtent, format: .RGBA8, colorSpace: nil)
            return stride(from: 0, to: rgbaBytes.count, by: 4).map { rgbaBytes[$0] }
        }
        func renderedPixels(of image: CIImage) -> [UInt8] {
            var rgbaBytes = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image.cropped(to: frameExtent), toBitmap: &rgbaBytes, rowBytes: width * 4, bounds: frameExtent, format: .RGBA8, colorSpace: sRGB)
            return rgbaBytes
        }
        let personBytes = redChannel(of: personMask)
        let originalPixels = try #require(rgbaBytes(of: standingPhoto, width: width, height: height))
        let bodyParts = shirtPaintBodyParts(in: standingPhoto)
        print("Live painted top check: \(bodyParts.faceBoxes.count) faces, \(bodyParts.hands.count) hands, torso shoulders \(Int(torso.shoulderWidth)) px apart, hips \(torso.hipsWereEstimated ? "estimated" : "seen")")

        // The old top's color, from the frame alone, as the painted still check reads it.
        let analysisFrame = ShirtSmallFrame(width: width, height: height, rgba: originalPixels, personMask: personBytes, torso: torso)
        let oldShirtColor = try #require(analysisFrame.measureOldShirtColor())
        let oldShirtLab = ShirtColorMath.lab(red: ShirtColorMath.byte(oldShirtColor.x), green: ShirtColorMath.byte(oldShirtColor.y), blue: ShirtColorMath.byte(oldShirtColor.z))

        /// The pose changes made up by moving the photo, its mask, and its torso together, about the shoulders' middle.
        let shoulderMiddle = torso.shoulderMidpoint
        func aboutTheShoulders(degrees: Double = 0, scale: Double = 1, shift: CGPoint = .zero) -> CGAffineTransform {
            CGAffineTransform(translationX: -shoulderMiddle.x, y: -shoulderMiddle.y)
                .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: shoulderMiddle.x + shift.x, y: shoulderMiddle.y + shift.y))
        }
        let followedPoses: [(name: String, transform: CGAffineTransform)] = [
            ("shift30", aboutTheShoulders(shift: CGPoint(x: 30, y: 0))),
            ("scale0.9", aboutTheShoulders(scale: 0.9)),
            ("roll8", aboutTheShoulders(degrees: 8)),
        ]
        func movedTorso(by transform: CGAffineTransform) -> BodyTorso {
            BodyTorso(
                imageLeftShoulder: torso.imageLeftShoulder.applying(transform), imageRightShoulder: torso.imageRightShoulder.applying(transform),
                imageLeftHip: torso.imageLeftHip.applying(transform), imageRightHip: torso.imageRightHip.applying(transform),
                hipsWereEstimated: torso.hipsWereEstimated, shouldersAreSeen: true,
                imageLeftElbow: torso.imageLeftElbow?.applying(transform), imageRightElbow: torso.imageRightElbow?.applying(transform),
                imageLeftWrist: torso.imageLeftWrist?.applying(transform), imageRightWrist: torso.imageRightWrist?.applying(transform)
            )
        }
        /// An image moved by a y down `transform` the way the frame processor moves the layer, edge pixels carried outward.
        func movedImage(_ image: CIImage, by transform: CGAffineTransform, clampingToTheEdge: Bool) -> CIImage {
            let moved = image.transformed(by: ShirtTryOnRenderer.coreImageTransform(of: transform, frameExtent: frameExtent))
            return (clampingToTheEdge ? moved.clampedToExtent() : moved.composited(over: CIImage(color: .black).cropped(to: frameExtent))).cropped(to: frameExtent)
        }

        var everyMetric: [ShirtLivePaintedTopMetrics] = []
        for productPath in productPaths {
            let shirtName = URL(fileURLWithPath: productPath).deletingPathExtension().lastPathComponent
            let paintedURL = paintingsFolder.appendingPathComponent("painted-\(shirtName).png")
            guard FileManager.default.fileExists(atPath: paintedURL.path) else {
                Issue.record("No saved painting at \(paintedURL.path). Run ShirtPaintedStillPhotoCheck with SHIRT_PAINT_OUTPUT_DIR set to this folder first. This check never pays for one.")
                continue
            }
            let painted = try loadImage(at: paintedURL)
            guard painted.width == width, painted.height == height else {
                Issue.record("\(shirtName): the painting is \(painted.width)x\(painted.height) and the photo \(width)x\(height), so it is not from this photo")
                continue
            }
            // The masks the painting was made with, worked out again from the photo. The live preview's garment coverage is
            // not known here, so the area comes from the cut alone, as the ghost outline's does.
            let frozenFrame = ShirtFrozenFrame(
                cameraImage: standingPhoto, previewImage: standingPhoto, personMask: personBytes,
                previewGarmentCoverage: [UInt8](repeating: 0, count: width * height), torso: torso
            )
            let masks = try #require(ShirtPaintMask.make(frame: frozenFrame, bodyParts: bodyParts, coverage: coverage), "no masks for \(shirtName)")
            let madeAt = Date()
            let top = try #require(ShirtLivePaintedTop.make(painted: painted, masks: masks, frozenTorso: torso, coverage: coverage), "no live top for \(shirtName)")
            print(String(format: "Live painted top check: %@ top cut out in %.2f s, the mask covers %.1f%% of the frame", shirtName, Date().timeIntervalSince(madeAt), masks.paintableShare * 100))
            try savePNG(try #require(context.createCGImage(top.layer.composited(over: CIImage(color: CIColor(red: 0.2, green: 0.9, blue: 0.2)).cropped(to: frameExtent)), from: frameExtent, format: .RGBA8, colorSpace: sRGB)), to: outputFolder.appendingPathComponent("\(shirtName)-layer-over-green.png"))

            // The top is everywhere the painted still differs from the photo, read from the two images and not from the masks,
            // so a painting pasted with other masks (an older put-back of the neck) shows up as a difference instead of being
            // left out of the measure.
            let paintedPixels = try #require(rgbaBytes(of: painted, width: width, height: height))
            let stillChangedBytes = (0..<(width * height)).map { index -> UInt8 in
                (0..<3).contains { abs(Int(paintedPixels[index * 4 + $0]) - Int(originalPixels[index * 4 + $0])) > 6 } ? 255 : 0
            }
            let stillChangedImage = CIImage(cgImage: try #require(grayImage(bytes: stillChangedBytes, width: width, height: height)))
            let oldShirtImage = CIImage(cgImage: try #require(grayImage(bytes: masks.oldShirt, width: width, height: height)))
            var metricsForThisShirt: [ShirtLivePaintedTopMetrics] = []
            for pose in followedPoses {
                let movedTorsoNow = movedTorso(by: pose.transform)
                let reach = ShirtLivePaintedTopReach.decide(frozenTorso: torso, currentTorso: movedTorsoNow, followsTheForearms: top.followsTheForearms, wasFollowing: false)
                let liveFrame = movedImage(frame, by: pose.transform, clampingToTheEdge: true)
                let livePersonMask = movedImage(personMask, by: pose.transform, clampingToTheEdge: false)
                let composite = top.composite(frame: liveFrame, personMask: livePersonMask, transform: top.transform(to: movedTorsoNow), visibility: 1)
                // The painted still moved by the same transform is what the live top should look like.
                let reference = movedImage(top.still, by: pose.transform, clampingToTheEdge: true)
                let compositePixels = renderedPixels(of: composite), referencePixels = renderedPixels(of: reference), photoPixels = renderedPixels(of: liveFrame)
                let personNow = redChannel(of: livePersonMask)
                let topNow = redChannel(of: movedImage(stillChangedImage, by: pose.transform, clampingToTheEdge: false))
                let oldShirtNow = redChannel(of: movedImage(oldShirtImage, by: pose.transform, clampingToTheEdge: false))

                func difference(of pixels: [UInt8], from other: [UInt8], at index: Int) -> (mean: Double, largest: Int) {
                    let differences = (0..<3).map { abs(Int(pixels[index * 4 + $0]) - Int(other[index * 4 + $0])) }
                    return (Double(differences.reduce(0, +)) / 3, differences.max() ?? 0)
                }
                func measure(_ region: (Int) -> Bool, of pixels: [UInt8]) -> (mean: Double, shareOff: Double) {
                    var total = 0.0, count = 0, off = 0
                    for index in 0..<(width * height) where region(index) {
                        let step = difference(of: pixels, from: referencePixels, at: index)
                        total += step.mean
                        count += 1
                        if step.largest > 24 { off += 1 }
                    }
                    return count > 0 ? (total / Double(count), Double(off) / Double(count)) : (0, 0)
                }
                let inThePerson: (Int) -> Bool = { personNow[$0] > 127 }
                let inTheTop: (Int) -> Bool = { personNow[$0] > 127 && topNow[$0] > 127 }
                let inThePersonMeasure = measure(inThePerson, of: compositePixels), inTheTopMeasure = measure(inTheTop, of: compositePixels)
                let photoAlone = measure(inTheTop, of: photoPixels)

                // A pixel of the old top is left showing when it and its 7 by 7 neighborhood are as the photo had it and it
                // still reads as the old top's color.
                let unchanged = (0..<(width * height)).map { index in (0..<3).allSatisfy { abs(Int(compositePixels[index * 4 + $0]) - Int(photoPixels[index * 4 + $0])) < 6 } }
                let unchangedPatch = ShirtPaintMask.eroded(unchanged, width: width, height: height, radius: 3)
                var oldTopPixels = 0, oldTopStillShowing = 0
                for index in 0..<(width * height) where oldShirtNow[index] > 127 && personNow[index] > 127 {
                    oldTopPixels += 1
                    let lab = ShirtColorMath.quickLab(red: compositePixels[index * 4], green: compositePixels[index * 4 + 1], blue: compositePixels[index * 4 + 2])
                    if unchangedPatch[index] && ShirtColorMath.distance(from: lab, to: oldShirtLab) < ShirtColorMath.oldShirtDistanceLimit { oldTopStillShowing += 1 }
                }

                var metrics = ShirtLivePaintedTopMetrics()
                metrics.shirtName = shirtName
                metrics.pose = pose.name
                metrics.followed = reach == .follows
                metrics.meanDifferenceInThePerson = inThePersonMeasure.mean
                metrics.shareOffByMoreThan24InThePerson = inThePersonMeasure.shareOff
                metrics.meanDifferenceInTheTop = inTheTopMeasure.mean
                metrics.shareOffByMoreThan24InTheTop = inTheTopMeasure.shareOff
                metrics.photoAloneMeanDifferenceInTheTop = photoAlone.mean
                metrics.oldTopLeftShowingShare = Double(oldTopStillShowing) / Double(max(oldTopPixels, 1))
                metricsForThisShirt.append(metrics)
                print("Live painted top check: \(shirtName) \(String(data: try JSONEncoder().encode(metrics), encoding: .utf8) ?? "")")
                #expect(reach == .follows, "\(shirtName) \(pose.name): the live top should follow, and the reach is \(reach)")

                let compositeImage = try #require(rgbImage(bytes: compositePixels, width: width, height: height))
                let referenceImage = try #require(rgbImage(bytes: referencePixels, width: width, height: height))
                let differenceBytes = (0..<(width * height * 4)).map { byteIndex -> UInt8 in
                    byteIndex % 4 == 3 ? 255 : UInt8(min(255, abs(Int(compositePixels[byteIndex]) - Int(referencePixels[byteIndex])) * 4))
                }
                let differenceImage = try #require(rgbImage(bytes: differenceBytes, width: width, height: height))
                try savePNG(compositeImage, to: outputFolder.appendingPathComponent("\(shirtName)-\(pose.name)-live.png"))
                try savePNG(referenceImage, to: outputFolder.appendingPathComponent("\(shirtName)-\(pose.name)-reference.png"))
                try savePNG(differenceImage, to: outputFolder.appendingPathComponent("\(shirtName)-\(pose.name)-difference-x4.png"))
                try savePNG(try #require(rgbImage(bytes: photoPixels, width: width, height: height)), to: outputFolder.appendingPathComponent("\(shirtName)-\(pose.name)-photo.png"))
            }
            everyMetric += metricsForThisShirt

            // An arm raised 40 degrees outward: the upper arm leaves where it hung in the painting, so the top is out of reach,
            // fades to the painted still within a third of a second, and shows the hint after half a second.
            func turnedAboutTheShoulder(_ point: CGPoint, shoulder: CGPoint, degrees: Double) -> CGPoint {
                CGPoint(x: point.x - shoulder.x, y: point.y - shoulder.y).applying(CGAffineTransform(rotationAngle: degrees * .pi / 180)).applying(CGAffineTransform(translationX: shoulder.x, y: shoulder.y))
            }
            let raisedElbow = torso.imageLeftElbow.map { turnedAboutTheShoulder($0, shoulder: torso.imageLeftShoulder, degrees: 40) }
            let raisedWrist = torso.imageLeftWrist.map { turnedAboutTheShoulder($0, shoulder: torso.imageLeftShoulder, degrees: 40) }
            let raisedArmTorso = BodyTorso(
                imageLeftShoulder: torso.imageLeftShoulder, imageRightShoulder: torso.imageRightShoulder, imageLeftHip: torso.imageLeftHip, imageRightHip: torso.imageRightHip,
                hipsWereEstimated: torso.hipsWereEstimated, shouldersAreSeen: true,
                imageLeftElbow: raisedElbow, imageRightElbow: torso.imageRightElbow, imageLeftWrist: raisedWrist, imageRightWrist: torso.imageRightWrist
            )
            guard torso.imageLeftElbow != nil else {
                print("Live painted top check: \(shirtName) the pose saw no left elbow in the photo, so the raised arm case is skipped")
                continue
            }
            var follower = ShirtLivePaintedTopFollower(top: top)
            // First the learner stands as they did, so the live top is fully in, then raises the arm.
            for step in 0...4 { _ = follower.advance(currentTorso: torso, at: Double(step) * 0.1) }
            #expect(follower.reach == .follows && follower.visibility == 1, "\(shirtName): standing as in the painting should follow")
            var hintChanges: [Bool] = []
            for step in 5...14 {
                if let hint = follower.advance(currentTorso: raisedArmTorso, at: Double(step) * 0.1) { hintChanges.append(hint) }
            }
            #expect(follower.reach == .outOfReach(.upperArmMoved), "\(shirtName): a raised arm should be out of reach, and the reach is \(follower.reach)")
            #expect(follower.visibility == 0 && hintChanges == [true], "\(shirtName): the still should show with the hint once, visibility \(follower.visibility), hint changes \(hintChanges)")
            let shownImage = follower.image(frame: frame, personMask: personMask)
            let shownPixels = renderedPixels(of: shownImage), stillPixels = renderedPixels(of: top.still)
            #expect(shownPixels == stillPixels, "\(shirtName): a top out of reach should show the painted still exactly")
            try savePNG(try #require(rgbImage(bytes: shownPixels, width: width, height: height)), to: outputFolder.appendingPathComponent("\(shirtName)-raised-arm-shows-the-still.png"))
            print("Live painted top check: \(shirtName) raised arm: reach \(follower.reach), visibility \(follower.visibility), hint changes \(hintChanges), image equals the still: \(shownPixels == stillPixels)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(everyMetric).write(to: outputFolder.appendingPathComponent("live-metrics.json"))
    }
}
