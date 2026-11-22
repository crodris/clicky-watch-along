//
//  ShirtTryOnPhotoCheckTests.swift
//  leanring-buddyTests
//
//  Draws real product photos on a real photo of a person, with the real Vision requests, and saves the composites to look at.
//  It runs only when SHIRT_TRYON_PHOTOS_DIR names a folder that holds standing.jpg (a person standing in a camera frame) and
//  one or more uE*.jpg flat lay product photos, and SHIRT_TRYON_OUTPUT_DIR names where the PNGs go:
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos SHIRT_TRYON_OUTPUT_DIR=/path/out tools/swift-check.sh --filter ShirtTryOnPhotoCheck
//  standing.jpg is a personal photo, so it is never committed. It also prints the milliseconds one composite takes at 1280 by 720
//  (about 8 ms in a release build, a few hundred in the debug build tools/swift-check.sh makes).
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
@testable import Clicky

private let photoCheckEnvironment = ProcessInfo.processInfo.environment

private func loadImage(at url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func savePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func pixelBuffer(of image: CIImage, context: CIContext) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let created = try #require(buffer)
    context.render(image, to: created, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return created
}

struct ShirtTryOnPhotoCheckTests {
    @Test(.enabled(if: photoCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil && photoCheckEnvironment["SHIRT_TRYON_OUTPUT_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR and SHIRT_TRYON_OUTPUT_DIR"))
    func eachFlatLayIsDrawnOnTheStandingPhoto() throws {
        let photosFolder = URL(fileURLWithPath: try #require(photoCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let outputFolder = URL(fileURLWithPath: try #require(photoCheckEnvironment["SHIRT_TRYON_OUTPUT_DIR"]))
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let context = CIContext()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let standingPhoto = try loadImage(at: photosFolder.appendingPathComponent("standing.jpg"))
        let frame = CIImage(cgImage: standingPhoto)
        let frameBuffer = try pixelBuffer(of: frame, context: context)

        // The real pose and the real person mask, as the panel makes them.
        let poseStartedAt = Date()
        let detectedTorso = ShirtPoseTracker.detectTorso(in: frameBuffer)
        print("Shirt try-on photo check: body pose took \(Int(Date().timeIntervalSince(poseStartedAt) * 1000)) ms, torso \(String(describing: detectedTorso))")
        let framing = ShirtFraming.assess(torso: detectedTorso, frameSize: CGSize(width: standingPhoto.width, height: standingPhoto.height))
        print("Shirt try-on photo check: framing \(framing)")
        let torso = try #require(detectedTorso)
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: frameBuffer, orientation: .up).perform([segmentation])
        let personMaskBuffer = try #require(segmentation.results?.first?.pixelBuffer)
        let personMask = CIImage(cvPixelBuffer: personMaskBuffer, options: [.colorSpace: NSNull()])

        let flatLayNames = try FileManager.default.contentsOfDirectory(atPath: photosFolder.path).filter { $0.hasPrefix("uE") && $0.hasSuffix(".jpg") }.sorted()
        #expect(!flatLayNames.isEmpty)
        for flatLayName in flatLayNames {
            let productPhoto = try loadImage(at: photosFolder.appendingPathComponent(flatLayName))
            let wholePhoto = RoomArtCorners(
                topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: productPhoto.width, y: 0),
                bottomRight: CGPoint(x: productPhoto.width, y: productPhoto.height), bottomLeft: CGPoint(x: 0, y: productPhoto.height)
            )
            let garmentStartedAt = Date()
            let garment = try #require(ShirtGarment.make(productPhoto: productPhoto, itemCorners: wholePhoto), "no garment found in \(flatLayName)")
            print("Shirt try-on photo check: \(flatLayName) garment made in \(Int(Date().timeIntervalSince(garmentStartedAt) * 1000)) ms, neck found \(garment.frontNeckWasFound), base color \(garment.baseColor)")
            // The cutout over a magenta background shows what subject lifting kept, and where the neck hole is.
            let cutoutOverMagenta = garment.cutout.composited(over: CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: garment.cutout.extent))
            if let cutoutImage = context.createCGImage(cutoutOverMagenta, from: cutoutOverMagenta.extent, format: .RGBA8, colorSpace: sRGB) {
                try savePNG(cutoutImage, to: outputFolder.appendingPathComponent("cutout-\(flatLayName.replacingOccurrences(of: ".jpg", with: "")).png"))
            }
            print("Shirt try-on photo check: \(flatLayName) torso corners \(garment.torsoCorners), front neck \(garment.frontNeckPoint), size \(garment.size)")
            let renderer = ShirtTryOnRenderer(ciContext: context)
            let composite = renderer.composite(frame: frame, personMask: personMask, torso: torso, garment: garment)
            let rendered = try #require(context.createCGImage(composite, from: composite.extent, format: .RGBA8, colorSpace: sRGB))
            try savePNG(rendered, to: outputFolder.appendingPathComponent("stand-\(flatLayName.replacingOccurrences(of: ".jpg", with: "")).png"))
        }
    }

    @Test(.enabled(if: photoCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR"))
    func oneCompositeOfA1280By720FrameIsTimed() throws {
        let photosFolder = URL(fileURLWithPath: try #require(photoCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let context = CIContext()
        let standingPhoto = try loadImage(at: photosFolder.appendingPathComponent("standing.jpg"))
        // The top 1280 by 720 of the photo, which keeps the head and the chest.
        let cropped = try #require(standingPhoto.cropping(to: CGRect(x: 80, y: 0, width: 1280, height: 720)))
        let frame = CIImage(cgImage: cropped)
        let frameBuffer = try pixelBuffer(of: frame, context: context)
        let torso = try #require(ShirtPoseTracker.detectTorso(in: frameBuffer))
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: frameBuffer, orientation: .up).perform([segmentation])
        let personMask = CIImage(cvPixelBuffer: try #require(segmentation.results?.first?.pixelBuffer), options: [.colorSpace: NSNull()])
        let flatLayName = try #require(try FileManager.default.contentsOfDirectory(atPath: photosFolder.path).filter { $0.hasPrefix("uE") && $0.hasSuffix(".jpg") }.sorted().first)
        let productPhoto = try loadImage(at: photosFolder.appendingPathComponent(flatLayName))
        let garment = try #require(ShirtGarment.make(productPhoto: productPhoto, itemCorners: RoomArtCorners(
            topLeft: .zero, topRight: CGPoint(x: productPhoto.width, y: 0), bottomRight: CGPoint(x: productPhoto.width, y: productPhoto.height), bottomLeft: CGPoint(x: 0, y: productPhoto.height))))

        // Drawn into a pixel buffer, as the panel draws into a drawable, 5 frames to warm up and then 40 timed.
        let renderer = ShirtTryOnRenderer(ciContext: context)
        var drawnFrames = 0
        var timedSeconds = 0.0
        for frameNumber in 0..<45 {
            let startedAt = Date()
            let composite = renderer.composite(frame: frame, personMask: personMask, torso: torso, garment: garment)
            context.render(composite, to: frameBuffer, bounds: composite.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            if frameNumber >= 5 {
                timedSeconds += Date().timeIntervalSince(startedAt)
                drawnFrames += 1
            }
        }
        let averageMilliseconds = timedSeconds / Double(drawnFrames) * 1000
        print("Shirt try-on photo check: a 1280x720 composite takes \(String(format: "%.1f", averageMilliseconds)) ms on average over \(drawnFrames) frames")
        // No expectation: a debug build, which tools/swift-check.sh makes, is about 20 times slower than a release build, so
        // the number only means something from `swift test -c release -Xswiftc -enable-testing` in a package of these files.
        #expect(averageMilliseconds > 0)
    }
}
