//
//  RoomFurnitureRenderer.swift
//  leanring-buddy
//
//  Renders a 3D model of the furniture, a store's own or a generated one, as the keyframe camera sees it standing on the
//  measured floor. It renders once per placement with an offscreen SCNRenderer and hands back full-frame layers in keyframe
//  pixels, which the frame processor moves with the room's tracked warp like any keyframe content. Mapping the render
//  through the flat cutout's quad would apply perspective twice.
//
//  Each render: the model is fit to the page's size (`RoomFurnitureModelFit`) and stood on the floor
//  (`RoomFurniturePlacement`), the camera is Depth Pro's pinhole (its focal length and principal point), the light is a
//  soft image-based environment from the blurred keyframe plus a broad key light from the frame's brighter side, and the
//  render's whites are toned to the wall's lit white by rendering a white card in the same light. The shadow is a top-down
//  silhouette of the model, blurred and laid on the floor, plus a tighter contact shadow from the bottom few centimeters, as
//  model-viewer does, since an offscreen renderer's shadow maps are unreliable.
//

import AppKit
import CoreImage
import Metal
import SceneKit
import simd

// MARK: - What the renderer returns

/// Which of the furniture's looks a layer came from, best first. The flat cutout is never drawn, and is only what the
/// generation services work from.
nonisolated enum RoomFurnitureLook: String, Equatable, Sendable {
    case storeModel
    case generatedModel
    case paintedComposite
}

/// The furniture as layers over the keyframe, in keyframe pixels, ready for the frame processor to warp with the room.
nonisolated struct RoomFurnitureKeyframeLayers: @unchecked Sendable {
    // @unchecked because CGImage is immutable, so sharing one across queues is safe.
    /// The item, premultiplied RGBA at the keyframe's size, transparent where the item is not.
    let itemLayer: CGImage
    /// Black with the shadow's darkness as alpha, at the keyframe's size, drawn over the floor before the item. Nil for a
    /// painted composite, whose painting already holds its shadow.
    let shadowLayer: CGImage?
    /// The middle of the item's front bottom edge in the keyframe, at its lowest row, which decides whether it draws over
    /// the learner.
    let basePointInTheKeyframe: CGPoint
    /// The standard deviation of the camera's noise in the keyframe, 0 to 1, which the processor adds to the item each
    /// frame so it has the same grain as the room around it.
    let cameraNoiseStandardDeviation: Double
    let look: RoomFurnitureLook
    /// The room's light in the frame the item was made on, which the processor relights it from each frame. Nil for an item
    /// made on the keyframe, which takes the keyframe's light.
    var roomLightWhenMade: RoomArtLightReference? = nil
}

/// One render's numbers for the log and the checks.
nonisolated struct RoomFurnitureRenderReport: Equatable, Sendable {
    let fit: RoomFurnitureModelFit
    /// The per-channel gains, in linear light, that toned the render's white card to the wall's lit white.
    let whiteGains: SIMD3<Double>
    let wallWhite: SIMD3<Double>
    /// What the white card rendered as, in linear light, which the gains are measured against.
    let cardWhite: SIMD3<Double>
    let renderMilliseconds: Double

    var logLine: String {
        let turnedWords = fit.wasTurnedAQuarter ? ", turned a quarter" : ""
        return String(format: "Room furniture: rendered in %.0f ms, %.2f m per model unit, width and depth within %.0f%%%@, white gains %.2f %.2f %.2f, wall white %.2f, card white %.2f",
                      renderMilliseconds, fit.scale, fit.worstSideMismatch * 100, turnedWords, whiteGains.x, whiteGains.y, whiteGains.z,
                      simd_dot(wallWhite, RoomFurnitureRoomLight.luminanceWeights), simd_dot(cardWhite, RoomFurnitureRoomLight.luminanceWeights))
    }
}

/// What one render needs: the model in its own space, where it stands, the keyframe camera, and the keyframe itself for the
/// room's light.
nonisolated struct RoomFurnitureRenderRequest: @unchecked Sendable {
    // @unchecked: the model's node tree is only read here, on the renderer's queue, after the loader built it.
    let modelRootNode: SCNNode
    let placement: RoomFurniturePlacement
    let focalLengthPixels: Double
    let principalPoint: SIMD2<Double>
    let keyframeImage: CGImage
    let look: RoomFurnitureLook
}

// MARK: - The camera

/// SceneKit takes single precision matrices, and the geometry here is worked out in double precision.
nonisolated func roomFurnitureFloatMatrix(_ matrix: simd_double4x4) -> simd_float4x4 {
    func floatColumn(_ column: SIMD4<Double>) -> SIMD4<Float> { SIMD4<Float>(Float(column.x), Float(column.y), Float(column.z), Float(column.w)) }
    return simd_float4x4(columns: (floatColumn(matrix.columns.0), floatColumn(matrix.columns.1), floatColumn(matrix.columns.2), floatColumn(matrix.columns.3)))
}

/// Converts the keyframe camera's space (x right, y down, z forward) to SceneKit's (y up, z toward the viewer). It turns the
/// space 180 degrees about x, so it is a rotation and keeps a model's handedness.
nonisolated let roomFurnitureCameraToSceneKit = simd_double4x4(diagonal: SIMD4(1, -1, -1, 1))

/// The projection that makes SceneKit's camera, at the origin looking down -z, project exactly like Depth Pro's pinhole:
/// a point (x, y, z) in the keyframe camera's space lands at (f x / z + cx, f y / z + cy) in a frame `frameWidth` by
/// `frameHeight` with y down. Depth runs from `nearMeters` to `farMeters` in OpenGL's -1 to 1 clip range, which SceneKit's
/// `projectionTransform` takes.
nonisolated func roomFurnitureProjection(
    focalLengthPixels: Double,
    principalPoint: SIMD2<Double>,
    frameWidth: Double,
    frameHeight: Double,
    nearMeters: Double = 0.05,
    farMeters: Double = 60
) -> simd_double4x4 {
    let depthScale = -(farMeters + nearMeters) / (farMeters - nearMeters)
    let depthOffset = -2 * farMeters * nearMeters / (farMeters - nearMeters)
    // Rows as the clip equations read: x_clip = (2f/W) X - (2cx/W - 1) Z, y_clip = (2f/H) Y - (1 - 2cy/H) Z, w = -Z.
    return simd_double4x4(rows: [
        SIMD4(2 * focalLengthPixels / frameWidth, 0, -(2 * principalPoint.x / frameWidth - 1), 0),
        SIMD4(0, 2 * focalLengthPixels / frameHeight, -(1 - 2 * principalPoint.y / frameHeight), 0),
        SIMD4(0, 0, depthScale, depthOffset),
        SIMD4(0, 0, -1, 0),
    ])
}

/// Where SceneKit's camera with `roomFurnitureProjection` draws a keyframe camera space point, in pixels with y down, by
/// running the same matrices the GPU does. Nil behind the camera.
nonisolated func roomFurnitureSceneKitPixel(
    of cameraSpacePoint: SIMD3<Double>,
    projection: simd_double4x4,
    frameWidth: Double,
    frameHeight: Double
) -> CGPoint? {
    let clipPoint = projection * roomFurnitureCameraToSceneKit * SIMD4(cameraSpacePoint, 1)
    guard clipPoint.w > 1e-9 else { return nil }
    let normalizedX = clipPoint.x / clipPoint.w, normalizedY = clipPoint.y / clipPoint.w
    return CGPoint(x: (normalizedX + 1) / 2 * frameWidth, y: (1 - normalizedY) / 2 * frameHeight)
}

// MARK: - The renderer

/// Renders furniture models off the main actor. One instance per panel; each call builds its own scenes and renderer, so
/// the work is safe on any one queue at a time.
nonisolated final class RoomFurnitureRenderer: @unchecked Sendable {
    // @unchecked: the Metal device and the Core Image context are thread safe, and every other value is made per call.
    private let metalDevice: MTLDevice?
    private let ciContext: CIContext
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Colors are measured and toned in linear light, Core Image's working space, so a gain means the same thing where it is
    /// measured and where it is applied.
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// The shadow is rendered at this size, which is plenty once it is blurred.
    private static let shadowRenderSide = 256
    /// The top-down shadow covers the footprint's larger side times this, so the blur fades out inside it.
    private static let shadowCoverageFactor = 1.9
    /// The contact shadow comes from the model's lowest centimeters: the feet or the base touching the floor.
    private static let contactSliceMeters = 0.035
    /// The camera's own softness, in camera pixels, which wall art also gets.
    static let cameraBlurPixels = 0.7
    /// The brightest part of the render (its 95th percentile) is held to this share of the wall's lit white, in linear light.
    static let brightestShareOfTheWallWhite = 0.92
    /// The share of the frame's lit white (its 95th percentile luminance) that the highlight hold never goes under.
    static let shareOfTheFramesLitWhite = 0.75
    /// How much of the wall's color tint the item takes, as a power of each channel's gain relative to their average.
    static let shareOfTheWallsTint = 0.5
    /// The model renders at this many times the keyframe's size and is scaled down, for antialiased edges.
    private static let supersamplingFactor = 2

    init() {
        metalDevice = MTLCreateSystemDefaultDevice()
        ciContext = metalDevice.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }

    /// The model's bounding box in its own space, over every geometry in the tree, each moved by its node's transform. A
    /// node's own `boundingBox` reads differently across SceneKit versions for a tree, so this walks it.
    static func boundingBox(of rootNode: SCNNode) -> (minimum: SIMD3<Double>, maximum: SIMD3<Double>)? {
        var minimum = SIMD3<Double>(repeating: .infinity), maximum = SIMD3<Double>(repeating: -.infinity)
        rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let (localMinimum, localMaximum) = geometry.boundingBox
            guard localMinimum.x <= localMaximum.x else { return }
            let toRoot = node == rootNode ? matrix_identity_float4x4 : rootNode.simdConvertTransform(matrix_identity_float4x4, from: node)
            for cornerX in [localMinimum.x, localMaximum.x] {
                for cornerY in [localMinimum.y, localMaximum.y] {
                    for cornerZ in [localMinimum.z, localMaximum.z] {
                        let corner = toRoot * SIMD4<Float>(Float(cornerX), Float(cornerY), Float(cornerZ), 1)
                        let cornerInDouble = SIMD3<Double>(Double(corner.x), Double(corner.y), Double(corner.z))
                        minimum = simd_min(minimum, cornerInDouble)
                        maximum = simd_max(maximum, cornerInDouble)
                    }
                }
            }
        }
        guard minimum.x.isFinite, maximum.x.isFinite, simd_reduce_min(maximum - minimum) >= 0 else { return nil }
        return (minimum, maximum)
    }

    /// The model standing on the floor as the keyframe camera sees it, with its shadow, or nil when the model has no size,
    /// the renderer cannot run (no Metal device), or a render comes back empty.
    func render(_ request: RoomFurnitureRenderRequest) -> (layers: RoomFurnitureKeyframeLayers, report: RoomFurnitureRenderReport)? {
        let startedAt = Date()
        guard let metalDevice,
              let modelBox = Self.boundingBox(of: request.modelRootNode),
              let fit = RoomFurnitureModelFit.fit(
                  modelExtent: modelBox.maximum - modelBox.minimum,
                  widthMeters: request.placement.widthMeters,
                  heightMeters: request.placement.heightMeters,
                  depthMeters: request.placement.depthMeters
              ) else { return nil }
        if fit.worstSideMismatch > RoomFurnitureModelFit.swapMismatch {
            print(String(format: "Room furniture: the model's width and depth differ from the page's by %.0f%% at the page's height", fit.worstSideMismatch * 100))
        }
        let frameWidth = request.keyframeImage.width, frameHeight = request.keyframeImage.height
        let placement = request.placement
        let modelToCamera = placement.modelToCameraTransform * fit.modelToFurnitureTransform(boundingBoxMinimum: modelBox.minimum, boundingBoxMaximum: modelBox.maximum)
        let projection = roomFurnitureProjection(
            focalLengthPixels: request.focalLengthPixels,
            principalPoint: request.principalPoint,
            frameWidth: Double(frameWidth),
            frameHeight: Double(frameHeight)
        )
        let keyframe = CIImage(cgImage: request.keyframeImage)
        let roomLight = RoomFurnitureRoomLight(keyframe: keyframe, ciContext: ciContext, imageColorSpace: sRGBColorSpace, measuringColorSpace: linearColorSpace)

        // The model.
        let modelScene = makeLitScene(roomLight: roomLight, placement: placement, projection: projection)
        let modelHolder = SCNNode()
        modelHolder.simdTransform = roomFurnitureFloatMatrix(roomFurnitureCameraToSceneKit * modelToCamera)
        modelHolder.addChildNode(request.modelRootNode.clone())
        modelScene.rootNode.addChildNode(modelHolder)
        // The snapshot's own multisampling left stair steps on the edges, so the model renders at twice the size and is scaled
        // down. The projection works in normalized coordinates, so the larger render is the same picture at more pixels.
        guard let largeModelRender = snapshot(of: modelScene, width: frameWidth * Self.supersamplingFactor, height: frameHeight * Self.supersamplingFactor, device: metalDevice),
              let modelRender = scaledDown(largeModelRender, toWidth: frameWidth, height: frameHeight) else { return nil }

        // A white card where the item's front is, in the same light, says what a white surface renders as here.
        let cardScene = makeLitScene(roomLight: roomLight, placement: placement, projection: projection)
        cardScene.rootNode.addChildNode(whiteCardNode(placement: placement))
        let projectedBox = placement.boxCorners.compactMap {
            pinholeProjection(of: $0, focalLengthPixels: request.focalLengthPixels, principalPoint: request.principalPoint)
        }
        let wallWhite = roomLight.wallLitWhite(aboveTheBox: projectedBox, frameWidth: frameWidth, frameHeight: frameHeight)
        let cardWhite = snapshot(of: cardScene, width: frameWidth, height: frameHeight, device: metalDevice)
            .flatMap { averageOpaqueColor(of: CIImage(cgImage: $0)) } ?? SIMD3(repeating: 0.8)
        // The card sets the tint and a first level. Its clamp is wide, since a card facing the camera under light from above
        // renders dim, and the highlight hold below sets the final level.
        let fullGains = simd_clamp(wallWhite / simd_max(cardWhite, SIMD3(repeating: 0.02)), SIMD3(repeating: 0.2), SIMD3(repeating: 8))
        // Half the wall's tint: a wall is often painted a warm or cool white, so its full color would tint a warm gray sofa
        // purple under a cool wall, while none of it would leave the piece looking lit by another room.
        let averageGain = (fullGains.x + fullGains.y + fullGains.z) / 3
        let relativeGains = fullGains / averageGain
        var whiteGains = averageGain * SIMD3(
            pow(relativeGains.x, Self.shareOfTheWallsTint), pow(relativeGains.y, Self.shareOfTheWallsTint), pow(relativeGains.z, Self.shareOfTheWallsTint)
        )
        // A white top facing the sky catches more light than the card, and a camera never records furniture brighter than
        // the lit wall behind it, so the brightest part of the toned render is held just under the wall's white.
        if let brightestLuminance = brightLuminance(of: CIImage(cgImage: modelRender), gains: whiteGains, within: projectedBox, frameHeight: Double(frameHeight)) {
            // The wall near a spot at the frame's edge can be in shade or in the lens's vignette, and a white top holds more
            // light than a wall in shade, so the hold is the brighter of the near wall and a share of the frame's lit white.
            let wallLuminance = max(simd_dot(wallWhite, RoomFurnitureRoomLight.luminanceWeights), roomLight.frameLitWhiteLuminance * Self.shareOfTheFramesLitWhite)
            let highestAllowedLuminance = wallLuminance * Self.brightestShareOfTheWallWhite
            if brightestLuminance > highestAllowedLuminance { whiteGains *= highestAllowedLuminance / brightestLuminance }
        }

        let tonedItem = CIImage(cgImage: modelRender)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: whiteGains.x, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: whiteGains.y, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: whiteGains.z, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .applyingGaussianBlur(sigma: Self.cameraBlurPixels)
            .cropped(to: keyframe.extent)
        guard let itemLayer = ciContext.createCGImage(tonedItem, from: keyframe.extent, format: .RGBA8, colorSpace: sRGBColorSpace) else { return nil }

        let shadowLayer = renderTheShadow(
            modelRootNode: request.modelRootNode,
            modelToCamera: modelToCamera,
            placement: placement,
            request: request,
            keyframeExtent: keyframe.extent,
            device: metalDevice
        )
        let basePoint = projectedBox.count == 8
            ? CGPoint(x: (projectedBox[2].x + projectedBox[3].x) / 2, y: max(projectedBox[2].y, projectedBox[3].y))
            : CGPoint(x: Double(frameWidth) / 2, y: Double(frameHeight))
        let layers = RoomFurnitureKeyframeLayers(
            itemLayer: itemLayer,
            shadowLayer: shadowLayer,
            basePointInTheKeyframe: basePoint,
            cameraNoiseStandardDeviation: roomLight.cameraNoiseStandardDeviation,
            look: request.look
        )
        let report = RoomFurnitureRenderReport(
            fit: fit,
            whiteGains: whiteGains,
            wallWhite: wallWhite,
            cardWhite: cardWhite,
            renderMilliseconds: Date().timeIntervalSince(startedAt) * 1000
        )
        return (layers, report)
    }

    // MARK: The scene and its light

    /// An empty scene with the keyframe camera, the room's image-based light, and the key light.
    private func makeLitScene(roomLight: RoomFurnitureRoomLight, placement: RoomFurniturePlacement, projection: simd_double4x4) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        if let environmentImage = roomLight.environmentImage {
            scene.lightingEnvironment.contents = environmentImage
            scene.lightingEnvironment.intensity = 1.1
        }

        let camera = SCNCamera()
        camera.wantsHDR = false
        camera.projectionTransform = SCNMatrix4(roomFurnitureFloatMatrix(projection))
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.name = "keyframe camera"
        scene.rootNode.addChildNode(cameraNode)

        // A broad key light from above and to the frame's brighter side. A room's light comes mostly from its ceiling and
        // windows, so the top catches the most and the faces toward the camera less, which is what reads as a solid object.
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 750
        keyLight.color = NSColor.white
        keyLight.castsShadow = false
        let sideways = placement.rightDirection * (roomLight.brighterSideIsRight ? -0.55 : 0.55)
        let travelDirection = simd_normalize(-placement.upDirection * 0.9 - placement.towardTheFrontDirection * 0.15 + sideways)
        let keyLightNode = SCNNode()
        keyLightNode.light = keyLight
        let travelInSceneKit = (roomFurnitureCameraToSceneKit * SIMD4(travelDirection, 0))
        let upInSceneKit = (roomFurnitureCameraToSceneKit * SIMD4(placement.upDirection, 0))
        keyLightNode.simdLook(
            at: SIMD3<Float>(Float(travelInSceneKit.x), Float(travelInSceneKit.y), Float(travelInSceneKit.z)),
            up: SIMD3<Float>(Float(upInSceneKit.x), Float(upInSceneKit.y), Float(upInSceneKit.z)),
            localFront: SIMD3<Float>(0, 0, -1)
        )
        scene.rootNode.addChildNode(keyLightNode)
        return scene
    }

    /// A matte white card the size of the item's front, standing where the front is.
    private func whiteCardNode(placement: RoomFurniturePlacement) -> SCNNode {
        let card = SCNPlane(width: CGFloat(placement.widthMeters), height: CGFloat(placement.heightMeters))
        let whiteMaterial = SCNMaterial()
        whiteMaterial.lightingModel = .physicallyBased
        whiteMaterial.diffuse.contents = NSColor.white
        whiteMaterial.metalness.contents = 0.0
        whiteMaterial.roughness.contents = 1.0
        card.materials = [whiteMaterial]
        let cardNode = SCNNode(geometry: card)
        // The plane faces +z in its own space, which the placement takes out of the item's front.
        let cardInTheItemsSpace = simd_double4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(0, placement.heightMeters / 2, placement.depthMeters / 2, 1)
        ))
        cardNode.simdTransform = roomFurnitureFloatMatrix(roomFurnitureCameraToSceneKit * placement.modelToCameraTransform * cardInTheItemsSpace)
        return cardNode
    }

    /// A render scaled down to the keyframe's size with Lanczos resampling, which averages the extra samples into smooth edges.
    private func scaledDown(_ largeRender: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        let scale = Double(width) / Double(largeRender.width)
        let smallRender = CIImage(cgImage: largeRender)
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return ciContext.createCGImage(smallRender, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: sRGBColorSpace)
    }

    private func snapshot(of scene: SCNScene, width: Int, height: Int, device: MTLDevice) -> CGImage? {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
        renderer.autoenablesDefaultLighting = false
        let renderedImage = renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
        var proposedRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let snapshotImage = renderedImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
        // Inside the app, on a display with extended range, the snapshot came back as a float image with values over 1,
        // while the test process got 8 bits. The white card then read about four times brighter than the clamped model
        // render, and the table rendered gray. Every snapshot is drawn into the same 8-bit sRGB bitmap at the asked
        // pixel size, so the card and the model are measured and toned alike in every process.
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(snapshotImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The 95th percentile luminance, in linear light, of the render's opaque pixels after `gains`, over the box around the
    /// projected item. Nil when no pixel there is opaque.
    private func brightLuminance(of render: CIImage, gains: SIMD3<Double>, within projectedBox: [CGPoint], frameHeight: Double) -> Double? {
        guard let left = projectedBox.map(\.x).min(), let right = projectedBox.map(\.x).max(),
              let top = projectedBox.map(\.y).min(), let bottom = projectedBox.map(\.y).max() else { return nil }
        let boxInCoreImage = CGRect(x: left, y: frameHeight - bottom, width: right - left, height: bottom - top).integral.intersection(render.extent)
        guard !boxInCoreImage.isNull, boxInCoreImage.width >= 1, boxInCoreImage.height >= 1 else { return nil }
        let width = Int(boxInCoreImage.width), height = Int(boxInCoreImage.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        ciContext.render(render, toBitmap: &pixels, rowBytes: width * 16, bounds: boxInCoreImage, format: .RGBAf, colorSpace: linearColorSpace)
        var luminances: [Double] = []
        for pixelIndex in 0..<(width * height) where pixels[pixelIndex * 4 + 3] > 0.98 {
            let alpha = Double(pixels[pixelIndex * 4 + 3])
            let color = SIMD3(Double(pixels[pixelIndex * 4]), Double(pixels[pixelIndex * 4 + 1]), Double(pixels[pixelIndex * 4 + 2])) / alpha * gains
            luminances.append(simd_dot(color, RoomFurnitureRoomLight.luminanceWeights))
        }
        guard !luminances.isEmpty else { return nil }
        return luminances.sorted()[Int(Double(luminances.count - 1) * 0.95)]
    }

    private func averageOpaqueColor(of image: CIImage) -> SIMD3<Double>? {
        // The average of premultiplied pixels divided by the average alpha is the average color of the opaque part.
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var averageRGBA = [Float](repeating: 0, count: 4)
        ciContext.render(average, toBitmap: &averageRGBA, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linearColorSpace)
        guard averageRGBA[3] > 1e-4 else { return nil }
        return SIMD3(Double(averageRGBA[0]), Double(averageRGBA[1]), Double(averageRGBA[2])) / Double(averageRGBA[3])
    }

    // MARK: The shadow

    /// The shadow over the floor in keyframe pixels: a top-down silhouette of the whole model, blurred wide and faint, and of
    /// its lowest few centimeters, blurred tight and darker, laid on the floor plane under the footprint.
    private func renderTheShadow(
        modelRootNode: SCNNode,
        modelToCamera: simd_double4x4,
        placement: RoomFurniturePlacement,
        request: RoomFurnitureRenderRequest,
        keyframeExtent: CGRect,
        device: MTLDevice
    ) -> CGImage? {
        let coveredSide = max(placement.widthMeters, placement.depthMeters) * Self.shadowCoverageFactor
        let cameraHeightAboveTheFloor = placement.heightMeters + 1
        guard let wholeSilhouette = topDownSilhouette(modelRootNode: modelRootNode, modelToCamera: modelToCamera, placement: placement, coveredSide: coveredSide, cameraHeight: cameraHeightAboveTheFloor, nearestHeight: nil, device: device),
              let contactSilhouette = topDownSilhouette(modelRootNode: modelRootNode, modelToCamera: modelToCamera, placement: placement, coveredSide: coveredSide, cameraHeight: cameraHeightAboveTheFloor, nearestHeight: Self.contactSliceMeters, device: device) else { return nil }

        let side = Double(Self.shadowRenderSide)
        let shadowSquare = CGRect(x: 0, y: 0, width: side, height: side)
        // Each silhouette's alpha, blurred and dimmed. Black stays black, so only the alpha carries the shadow.
        func blurredAlpha(_ silhouette: CGImage, blurShareOfTheSide: Double, darkness: Double) -> CIImage {
            CIImage(cgImage: silhouette)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: side * blurShareOfTheSide)
                .cropped(to: shadowSquare)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: darkness),
                ])
        }
        // Black over black multiplies the light left: 1 - (1 - a)(1 - b), which source-over gives for premultiplied black.
        let shadowInTheSquare = blurredAlpha(contactSilhouette, blurShareOfTheSide: 0.01, darkness: 0.7)
            .composited(over: blurredAlpha(wholeSilhouette, blurShareOfTheSide: 0.045, darkness: 0.42))
            // The edge of the square must be clear, or the perspective warp would show its border.
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: Self.vignetteMask(side: side),
            ])

        // The square's corners on the floor: the top of the silhouette is the far side, and its right is the item's right.
        let center = placement.footprintCenter
        let halfSide = coveredSide / 2
        let farLeft = center - placement.rightDirection * halfSide - placement.towardTheFrontDirection * halfSide
        let farRight = center + placement.rightDirection * halfSide - placement.towardTheFrontDirection * halfSide
        let nearRight = center + placement.rightDirection * halfSide + placement.towardTheFrontDirection * halfSide
        let nearLeft = center - placement.rightDirection * halfSide + placement.towardTheFrontDirection * halfSide
        let projectedSquare = [farLeft, farRight, nearRight, nearLeft].compactMap {
            pinholeProjection(of: $0, focalLengthPixels: request.focalLengthPixels, principalPoint: request.principalPoint)
        }
        guard projectedSquare.count == 4 else { return nil }
        // Core Image's y grows up from the bottom.
        let frameHeight = keyframeExtent.height
        let cornersFromTheBottom = projectedSquare.map { CIVector(x: $0.x, y: frameHeight - $0.y) }
        let shadowOnTheFloor = shadowInTheSquare
            .applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": cornersFromTheBottom[0],
                "inputTopRight": cornersFromTheBottom[1],
                "inputBottomRight": cornersFromTheBottom[2],
                "inputBottomLeft": cornersFromTheBottom[3],
            ])
            .cropped(to: keyframeExtent)
        return ciContext.createCGImage(shadowOnTheFloor, from: keyframeExtent, format: .RGBA8, colorSpace: sRGBColorSpace)
    }

    /// A white square that fades to clear over its outer eighth, so the shadow ends inside the rendered square.
    private static func vignetteMask(side: Double) -> CIImage {
        let radial = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: side / 2, y: side / 2),
            "inputRadius0": side * 0.38,
            "inputRadius1": side * 0.5,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ])?.outputImage ?? CIImage(color: .white)
        return radial.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// The model seen from straight above, black on clear, covering `coveredSide` meters around the footprint's center:
    /// the image's top is the far side and its right is the item's right. With `nearestHeight`, only the model within that
    /// many meters of the floor is seen.
    private func topDownSilhouette(
        modelRootNode: SCNNode,
        modelToCamera: simd_double4x4,
        placement: RoomFurniturePlacement,
        coveredSide: Double,
        cameraHeight: Double,
        nearestHeight: Double?,
        device: MTLDevice
    ) -> CGImage? {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let silhouetteModel = modelRootNode.clone()
        let blackMaterial = SCNMaterial()
        blackMaterial.lightingModel = .constant
        blackMaterial.diffuse.contents = NSColor.black
        blackMaterial.isDoubleSided = true
        silhouetteModel.enumerateHierarchy { node, _ in
            // The clone shares its geometry with the model, so it gets its own copy before its materials change.
            guard let geometryCopy = node.geometry?.copy() as? SCNGeometry else { return }
            geometryCopy.materials = [blackMaterial]
            node.geometry = geometryCopy
        }
        let modelHolder = SCNNode()
        modelHolder.simdTransform = roomFurnitureFloatMatrix(roomFurnitureCameraToSceneKit * modelToCamera)
        modelHolder.addChildNode(silhouetteModel)
        scene.rootNode.addChildNode(modelHolder)

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = coveredSide / 2
        camera.automaticallyAdjustsZRange = false
        camera.zNear = nearestHeight.map { cameraHeight - $0 } ?? 0.01
        camera.zFar = cameraHeight + 0.05
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let position = placement.footprintCenter + placement.upDirection * cameraHeight
        let positionInSceneKit = roomFurnitureCameraToSceneKit * SIMD4(position, 1)
        let downInSceneKit = roomFurnitureCameraToSceneKit * SIMD4(-placement.upDirection, 0)
        let farInSceneKit = roomFurnitureCameraToSceneKit * SIMD4(-placement.towardTheFrontDirection, 0)
        cameraNode.simdPosition = SIMD3<Float>(Float(positionInSceneKit.x), Float(positionInSceneKit.y), Float(positionInSceneKit.z))
        cameraNode.simdLook(
            at: cameraNode.simdPosition + SIMD3<Float>(Float(downInSceneKit.x), Float(downInSceneKit.y), Float(downInSceneKit.z)),
            up: SIMD3<Float>(Float(farInSceneKit.x), Float(farInSceneKit.y), Float(farInSceneKit.z)),
            localFront: SIMD3<Float>(0, 0, -1)
        )
        scene.rootNode.addChildNode(cameraNode)
        return snapshot(of: scene, width: Self.shadowRenderSide, height: Self.shadowRenderSide, device: device)
    }
}

// MARK: - The room's light

/// What the keyframe says about the room's light: a blurred copy for image-based light, which side is brighter, the wall's
/// lit white near the item, and the camera's noise.
nonisolated struct RoomFurnitureRoomLight: @unchecked Sendable {
    // @unchecked: the images are immutable.
    let environmentImage: CGImage?
    let brighterSideIsRight: Bool
    let cameraNoiseStandardDeviation: Double
    /// The frame's lit white: the 95th percentile luminance of the whole keyframe, in linear light.
    let frameLitWhiteLuminance: Double
    private let keyframe: CIImage
    private let ciContext: CIContext
    /// Linear light, where every color here is measured.
    private let colorSpace: CGColorSpace

    init(keyframe: CIImage, ciContext: CIContext, imageColorSpace: CGColorSpace, measuringColorSpace: CGColorSpace) {
        self.keyframe = keyframe
        self.ciContext = ciContext
        self.colorSpace = measuringColorSpace
        let extent = keyframe.extent
        // A small, heavily blurred room is a neutral environment: it carries the room's color and where the light is
        // without any sharp reflection a viewer would read as a mirror image of the wrong room.
        let environment = keyframe
            .transformed(by: CGAffineTransform(scaleX: 256 / extent.width, y: 128 / extent.height))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 10)
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 128))
        environmentImage = ciContext.createCGImage(environment, from: environment.extent, format: .RGBA8, colorSpace: imageColorSpace)

        // The brighter half of the frame's upper part is where the light comes from.
        func averageLuminance(of rectangle: CGRect) -> Double {
            let average = Self.averageColor(of: keyframe, in: rectangle, ciContext: ciContext, colorSpace: measuringColorSpace)
            return 0.2126 * average.x + 0.7152 * average.y + 0.0722 * average.z
        }
        let upperHeight = extent.height * 0.6
        let leftHalf = CGRect(x: extent.minX, y: extent.maxY - upperHeight, width: extent.width / 2, height: upperHeight)
        let rightHalf = leftHalf.offsetBy(dx: extent.width / 2, dy: 0)
        brighterSideIsRight = averageLuminance(of: rightHalf) > averageLuminance(of: leftHalf)

        cameraNoiseStandardDeviation = Self.measuredNoise(in: keyframe, ciContext: ciContext, colorSpace: measuringColorSpace)
        frameLitWhiteLuminance = Self.percentileLuminance(of: keyframe, percentile: 0.95, ciContext: ciContext, colorSpace: measuringColorSpace)
    }

    /// The wall's lit white above the box: the average of the brighter half of the pixels in a band just above the box's
    /// top, as wide as the box, so a dark floor or a shadowed corner never tints a white piece. Falls back to the band
    /// beside the box when the box reaches the frame's top. In linear light, 0 to 1.
    func wallLitWhite(aboveTheBox projectedBox: [CGPoint], frameWidth: Int, frameHeight: Int) -> SIMD3<Double> {
        guard let left = projectedBox.map(\.x).min(), let right = projectedBox.map(\.x).max(),
              let top = projectedBox.map(\.y).min(), let bottom = projectedBox.map(\.y).max() else { return SIMD3(repeating: 0.85) }
        let boxHeight = max(bottom - top, 1)
        let frameRectangle = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        var band = CGRect(x: left, y: top - boxHeight * 0.6, width: right - left, height: boxHeight * 0.55).intersection(frameRectangle)
        if band.isNull || band.height < boxHeight * 0.15 {
            // The band beside the box, on whichever side has more room, at the box's upper half.
            let besideWidth = max(right - left, 40) * 0.6
            let beside = left > Double(frameWidth) - right
                ? CGRect(x: left - besideWidth - 8, y: top, width: besideWidth, height: boxHeight * 0.5)
                : CGRect(x: right + 8, y: top, width: besideWidth, height: boxHeight * 0.5)
            band = beside.intersection(frameRectangle)
        }
        guard !band.isNull, band.width >= 2, band.height >= 2 else { return SIMD3(repeating: 0.85) }
        // Keyframe pixels have y down, and Core Image's y grows up.
        let bandInCoreImage = CGRect(x: band.minX, y: Double(frameHeight) - band.maxY, width: band.width, height: band.height)
        return brighterHalfAverage(in: bandInCoreImage)
    }

    private func brighterHalfAverage(in rectangle: CGRect) -> SIMD3<Double> {
        let sampleWidth = 48, sampleHeight = 24
        let sample = keyframe.cropped(to: rectangle)
            .transformed(by: CGAffineTransform(translationX: -rectangle.minX, y: -rectangle.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(sampleWidth) / rectangle.width, y: Double(sampleHeight) / rectangle.height))
        var pixels = [Float](repeating: 0, count: sampleWidth * sampleHeight * 4)
        ciContext.render(sample, toBitmap: &pixels, rowBytes: sampleWidth * 16, bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight), format: .RGBAf, colorSpace: colorSpace)
        var colors: [SIMD3<Double>] = []
        for pixelIndex in 0..<(sampleWidth * sampleHeight) {
            colors.append(SIMD3(Double(pixels[pixelIndex * 4]), Double(pixels[pixelIndex * 4 + 1]), Double(pixels[pixelIndex * 4 + 2])))
        }
        let byLuminance = colors.sorted { simd_dot($0, Self.luminanceWeights) < simd_dot($1, Self.luminanceWeights) }
        let brighterHalf = byLuminance.suffix(max(byLuminance.count / 2, 1))
        return brighterHalf.reduce(SIMD3(repeating: 0), +) / Double(brighterHalf.count)
    }

    static let luminanceWeights = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// A luminance percentile of the image, read from a 64 by 36 copy, which is plenty for the frame's overall light.
    static func percentileLuminance(of image: CIImage, percentile: Double, ciContext: CIContext, colorSpace: CGColorSpace) -> Double {
        let sampleWidth = 64, sampleHeight = 36
        let extent = image.extent
        let sample = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(sampleWidth) / extent.width, y: Double(sampleHeight) / extent.height))
        var pixels = [Float](repeating: 0, count: sampleWidth * sampleHeight * 4)
        ciContext.render(sample, toBitmap: &pixels, rowBytes: sampleWidth * 16, bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight), format: .RGBAf, colorSpace: colorSpace)
        var luminances: [Double] = []
        for pixelIndex in 0..<(sampleWidth * sampleHeight) {
            let color = SIMD3(Double(pixels[pixelIndex * 4]), Double(pixels[pixelIndex * 4 + 1]), Double(pixels[pixelIndex * 4 + 2]))
            luminances.append(simd_dot(color, luminanceWeights))
        }
        let sortedLuminances = luminances.sorted()
        return sortedLuminances[min(sortedLuminances.count - 1, Int(Double(sortedLuminances.count) * percentile))]
    }

    static func averageColor(of image: CIImage, in rectangle: CGRect, ciContext: CIContext, colorSpace: CGColorSpace) -> SIMD3<Double> {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rectangle)])
        var averageRGBA = [Float](repeating: 0, count: 4)
        ciContext.render(average, toBitmap: &averageRGBA, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: colorSpace)
        return SIMD3(Double(averageRGBA[0]), Double(averageRGBA[1]), Double(averageRGBA[2]))
    }

    /// The camera's grain: the standard deviation of the gray image minus a blurred copy, in the flattest quarter of a 4 by
    /// 4 grid, so edges and texture do not count as noise.
    private static func measuredNoise(in keyframe: CIImage, ciContext: CIContext, colorSpace: CGColorSpace) -> Double {
        let extent = keyframe.extent
        let gray = keyframe.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let highPass = gray.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: gray.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: extent),
        ])
        let squared = highPass.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: highPass])
        var cellDeviations: [Double] = []
        for row in 0..<4 {
            for column in 0..<4 {
                let cell = CGRect(x: extent.minX + extent.width * Double(column) / 4, y: extent.minY + extent.height * Double(row) / 4, width: extent.width / 4, height: extent.height / 4)
                let meanSquare = averageColor(of: squared, in: cell, ciContext: ciContext, colorSpace: colorSpace).x
                cellDeviations.append(sqrt(max(meanSquare, 0)))
            }
        }
        let flattest = cellDeviations.sorted().prefix(4)
        return flattest.reduce(0, +) / Double(flattest.count)
    }
}

// MARK: - Drawing the layers on a frame

/// How the frame processor draws furniture layers on each camera frame, kept apart so the room checks draw exactly what the
/// panel draws.
nonisolated enum RoomFurnitureComposition {
    /// The affine transform that moves keyframe content to where the room is in the current frame, in Core Image's
    /// coordinates (y up), from three keyframe points and where the tracker put them now (camera pixels, y down). The
    /// tracker's warp is a turn and a shift, which an affine transform holds exactly. Nil when the points are in a line.
    static func keyframeToCurrentFrame(keyframePoints: [CGPoint], currentPoints: [CGPoint], frameHeight: Double) -> CGAffineTransform? {
        guard keyframePoints.count >= 3, currentPoints.count >= 3 else { return nil }
        let from = keyframePoints.prefix(3).map { SIMD2<Double>($0.x, frameHeight - $0.y) }
        let to = currentPoints.prefix(3).map { SIMD2<Double>($0.x, frameHeight - $0.y) }
        // Solve to = M from + t with the first point as the origin: M (from_i - from_0) = to_i - to_0 for i = 1, 2.
        let fromEdges = simd_double2x2(columns: (from[1] - from[0], from[2] - from[0]))
        let toEdges = simd_double2x2(columns: (to[1] - to[0], to[2] - to[0]))
        guard abs(fromEdges.determinant) > 1e-9 else { return nil }
        let linearPart = toEdges * fromEdges.inverse
        let translation = to[0] - linearPart * from[0]
        return CGAffineTransform(
            a: linearPart.columns.0.x, b: linearPart.columns.0.y,
            c: linearPart.columns.1.x, d: linearPart.columns.1.y,
            tx: translation.x, ty: translation.y
        )
    }

    /// The frame with the furniture: the shadow over the floor first, then the item with the camera's grain, both moved from
    /// the keyframe by `keyframeToCurrent`. Black at the shadow's alpha over the floor multiplies the floor's light by one
    /// minus that alpha. `grainOffset` moves the noise each frame, so the grain flickers like the camera's own.
    /// `lightGains` scales the item in linear light by how the room's light changed since the frame it was made on
    /// (`RoomArtLightReference.gains(from:to:)`), so it follows a light turned on or the camera's exposure moving.
    static func frameWithTheFurniture(
        frame: CIImage,
        itemLayer: CIImage,
        shadowLayer: CIImage?,
        keyframeToCurrent: CGAffineTransform,
        grainStandardDeviation: Double,
        grainOffset: CGPoint,
        lightGains: SIMD3<Double> = RoomArtLightReference.unchangedGains
    ) -> CIImage {
        // Core Image works in linear light, so scaling each channel here is the exposure change it measured. A pure scale
        // gives the same result on premultiplied and straight colors, and the alpha stays as it is.
        let relitItem = lightGains == RoomArtLightReference.unchangedGains ? itemLayer : itemLayer.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: lightGains.x, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: lightGains.y, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: lightGains.z, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let movedItem = relitItem.transformed(by: keyframeToCurrent)
        var composed = frame
        if let shadowLayer {
            composed = shadowLayer.transformed(by: keyframeToCurrent).composited(over: composed)
        }
        var itemWithGrain = movedItem
        if grainStandardDeviation > 0.001, let randomNoise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            // Uniform noise from 0 to 1 has a standard deviation of 1 over the square root of 12.
            let noiseScale = grainStandardDeviation * 12.0.squareRoot()
            let grayZeroMeanNoise = randomNoise
                .transformed(by: CGAffineTransform(translationX: grainOffset.x, y: grainOffset.y))
                .cropped(to: frame.extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: noiseScale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: noiseScale, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: noiseScale, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -noiseScale / 2, y: -noiseScale / 2, z: -noiseScale / 2, w: 0),
                ])
            // The grain is weighted by the item's own alpha and has no alpha of its own, so adding it changes only the
            // item's color and never its coverage.
            let grainOnTheItem = grayZeroMeanNoise.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: movedItem,
            ])
            itemWithGrain = grainOnTheItem.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: movedItem])
        }
        return itemWithGrain.composited(over: composed).cropped(to: frame.extent)
    }
}
