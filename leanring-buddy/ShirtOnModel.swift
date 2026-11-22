//
//  ShirtOnModel.swift
//  leanring-buddy
//
//  The shirt try-on from a product photo of the shirt worn by a model, the way most store pages show a T-shirt. A photo on a
//  model never shows the inside of the collar, since the model's neck fills it, and its sleeves already hang along arms.
//
//  The garment is prepared once per shirt, off the main actor:
//  1. Vision's body pose finds the model's joints (`ShirtModelPose`), and its person segmentation finds the model.
//  2. The model is split into parts (`ShirtModelPartLabels`): the shirt, the head and neck, the forearms and hands, and what is
//     below the hem. Each part grows from seeds the joints place (`ShirtModelPartSeeds`), and a pixel goes to the part that
//     reaches it most cheaply, where a step costs more across a color edge and into a color the part's seeds rarely have. So
//     a skin-colored print stays shirt, since the skin would have to cross the shirt's own colors to reach it, and the model's
//     neck leaves a hole where the learner's own neck shows.
//  3. The shirt's geometry comes from the model's joints (`ShirtOnModelGeometry`): its torso corners by the same rule the
//     renderer lands them on the learner by, so the model's body maps onto the learner's, and each sleeve with its opening
//     where the sleeve's hem crosses the model's arm.
//  Each frame the renderer maps the torso by the same perspective map as a flat lay's, and each sleeve from the model's arm to
//  the learner's (`onModelSleeveLanding`), so a sleeve keeps the angle it hung at on the model.
//
//  Points are in working photo pixels, top left origin, y down, as in ShirtTryOn.swift.
//

import CoreGraphics
import CoreImage
import Foundation
import simd
import Vision

// MARK: - The model's joints

/// The joints of the model in a product photo as the pose request reports them, Vision's coordinates.
nonisolated struct ShirtModelJointReadings: Equatable, Sendable {
    let body: ShirtBodyJointReadings
    let nose: ShirtJointReading?
    let personLeftWrist: ShirtJointReading?
    let personRightWrist: ShirtJointReading?
}

/// The model's joints in the working photo's pixels. The torso's hips are estimated when the pose request is unsure of them,
/// which it usually is on a model, since the shirt hides them.
nonisolated struct ShirtModelPose: Equatable, Sendable {
    let torso: BodyTorso
    let nose: CGPoint?
    /// The wrist on the image left shoulder's arm and the one on the image right's, each nil when it is not seen.
    let imageLeftWrist: CGPoint?
    let imageRightWrist: CGPoint?

    /// Nil when a shoulder is missing, so the shirt cannot be placed, or a shoulder is not seen.
    init?(readings: ShirtModelJointReadings, photoSize: CGSize) {
        guard let torso = BodyTorso(readings: readings.body, frameSize: photoSize), torso.shouldersAreSeen else { return nil }
        self.torso = torso
        func seenPoint(_ reading: ShirtJointReading?) -> CGPoint? {
            guard let reading, reading.confidence >= BodyTorso.jointConfidenceFloor else { return nil }
            return CGPoint(x: reading.visionPoint.x * photoSize.width, y: (1 - reading.visionPoint.y) * photoSize.height)
        }
        nose = seenPoint(readings.nose)
        // Each wrist goes with the shoulder on its own side of the person, as the torso's elbows do.
        let personLeftShoulderX = readings.body.personLeftShoulder.map { $0.visionPoint.x } ?? 0
        let personRightShoulderX = readings.body.personRightShoulder.map { $0.visionPoint.x } ?? 1
        let personLeftIsImageLeft = personLeftShoulderX <= personRightShoulderX
        imageLeftWrist = seenPoint(personLeftIsImageLeft ? readings.personLeftWrist : readings.personRightWrist)
        imageRightWrist = seenPoint(personLeftIsImageLeft ? readings.personRightWrist : readings.personLeftWrist)
    }

    init(torso: BodyTorso, nose: CGPoint?, imageLeftWrist: CGPoint?, imageRightWrist: CGPoint?) {
        self.torso = torso
        self.nose = nose
        self.imageLeftWrist = imageLeftWrist
        self.imageRightWrist = imageRightWrist
    }

    /// The pose of the person in `photo` whose shoulders' middle lies nearest `itemCenter`, the middle of the shirt the page
    /// reader found, so a second person in the photo is never the model. Nil when no one's shoulders are seen.
    static func detect(in photo: CGImage, nearestTo itemCenter: CGPoint) -> ShirtModelPose? {
        let request = VNDetectHumanBodyPoseRequest()
        do { try VNImageRequestHandler(cgImage: photo).perform([request]) } catch { return nil }
        let photoSize = CGSize(width: photo.width, height: photo.height)
        let poses = (request.results ?? []).compactMap { observation -> ShirtModelPose? in
            func reading(_ jointName: VNHumanBodyPoseObservation.JointName) -> ShirtJointReading? {
                guard let point = try? observation.recognizedPoint(jointName) else { return nil }
                return ShirtJointReading(visionPoint: point.location, confidence: point.confidence)
            }
            return ShirtModelPose(readings: ShirtModelJointReadings(
                body: ShirtBodyJointReadings(
                    personLeftShoulder: reading(.leftShoulder), personRightShoulder: reading(.rightShoulder),
                    personLeftHip: reading(.leftHip), personRightHip: reading(.rightHip),
                    personLeftElbow: reading(.leftElbow), personRightElbow: reading(.rightElbow)
                ),
                nose: reading(.nose), personLeftWrist: reading(.leftWrist), personRightWrist: reading(.rightWrist)
            ), photoSize: photoSize)
        }
        return poses.min { first, second in
            hypot(first.torso.shoulderMidpoint.x - itemCenter.x, first.torso.shoulderMidpoint.y - itemCenter.y)
                < hypot(second.torso.shoulderMidpoint.x - itemCenter.x, second.torso.shoulderMidpoint.y - itemCenter.y)
        }
    }
}

/// The model's body as coordinates: the shoulders' middle is the origin, x runs along the shoulders toward image right, and
/// y runs down the body, both in shoulder widths.
nonisolated struct ShirtBodyFrame: Equatable, Sendable {
    let origin: SIMD2<Double>
    let across: SIMD2<Double>
    let down: SIMD2<Double>
    let shoulderWidth: Double

    init(torso: BodyTorso) {
        origin = SIMD2(Double(torso.shoulderMidpoint.x), Double(torso.shoulderMidpoint.y))
        let span = SIMD2(Double(torso.imageRightShoulder.x - torso.imageLeftShoulder.x), Double(torso.imageRightShoulder.y - torso.imageLeftShoulder.y))
        shoulderWidth = max(simd_length(span), 1)
        across = span / shoulderWidth
        // The shoulders are sorted by x, so this perpendicular points down the body.
        down = SIMD2(-across.y, across.x)
    }

    func bodyCoordinates(of point: SIMD2<Double>) -> SIMD2<Double> {
        let offset = point - origin
        return SIMD2(simd_dot(offset, across), simd_dot(offset, down)) / shoulderWidth
    }

    func photoPoint(atBodyCoordinates coordinates: SIMD2<Double>) -> SIMD2<Double> {
        origin + (across * coordinates.x + down * coordinates.y) * shoulderWidth
    }
}

// MARK: - The model's parts

/// The parts the model is split into. Only the shirt is kept.
nonisolated enum ShirtModelPart: Int, CaseIterable, Sendable {
    case shirt
    /// The face, the hair, and the neck.
    case head
    /// The forearms and the hands.
    case arms
    /// What is below the shirt's hem: trousers, a belt, the legs.
    case belowTheHem
}

/// Where each part surely is, from the joints alone, as one flag per pixel of an image `width` by `height`. A part with no
/// seed pixel takes no part in the split.
nonisolated struct ShirtModelPartSeeds: Equatable, Sendable {
    let width: Int
    let height: Int
    /// Indexed by `ShirtModelPart.rawValue`.
    let seedsOfEachPart: [[Bool]]
    /// Where each part may reach at all, indexed the same way. The head stays above the collar and the arms stay off the
    /// chest, so a beige shirt next to skin of nearly its color is never taken by them.
    let allowedOfEachPart: [[Bool]]

    // The places, in shoulder widths of the body frame (x across, y down from the shoulders' middle).
    /// The chest and the belly, which a T-shirt always covers: within this far of the middle...
    static let shirtSeedHalfWidth = 0.28
    /// ...from this far below the shoulder line, under the collar...
    static let shirtSeedTop = 0.35
    /// ...to this far down, above the shortest hem.
    static let shirtSeedBottom = 1.25
    /// Below the chest the seed widens to the waist's sides, inside the arms: within this far of the middle, from
    /// `shirtWaistSeedTop` down.
    static let shirtWaistSeedHalfWidth = 0.36
    static let shirtWaistSeedTop = 0.6
    /// The head reaches only above a line that falls from this far below the shoulders' middle by `headReachSlope` shoulder
    /// widths for every shoulder width out, so it takes the neck and never the tops of the shoulders.
    static let headReachAtTheMiddle = 0.15
    static let headReachSlope = 1.2
    /// The arms reach only this far, in shoulder widths, from their bones: the forearm from the elbow to the wrist and a hand
    /// beyond it, and the upper arm's lower part below a short sleeve's hem. A forearm is about 0.18 shoulder widths thick.
    static let armReachFromTheBone = 0.17
    static let upperArmReachStartShare = 0.4
    static let handReachPastTheWristShare = 0.35
    /// The tops of the shoulders, inside the collar's reach and outside the neck: always shirt.
    static let shoulderTopSeedAcross = 0.3
    static let shoulderTopSeedDown = 0.05
    /// The photo's bottom rows, this share of its height, are below the hem where their color is unlike the shirt's seeds
    /// (a color bin that holds under `mostShirtShareOfABottomEdgeColor` of them), for a photo cut off above the trousers' seed.
    static let bottomEdgeShare = 0.025
    static let mostShirtShareOfABottomEdgeColor = 0.002
    /// A short sleeve covers the upper arm this share of the way from the shoulder to the elbow.
    static let sleeveSeedShareDownTheUpperArm = 0.22
    static let seedDiscRadius = 0.045
    static let faceSeedRadius = 0.14
    /// The neck lies this share of the way from the nose down to the shoulders' middle.
    static let neckSeedShareFromTheNose = 0.45
    /// Above this the person is the head: the face and the hair.
    static let headRegionBottom = -0.55
    /// The forearm from this share of the way from the elbow to the wrist: past a short sleeve's hem, even a boxy one's.
    static let forearmSeedStartShare = 0.3
    /// What is below this, in torso lengths below the hips, is below the shirt's hem on any T-shirt, away from the hands.
    static let belowTheHemStartInTorsoLengths = 0.42
    static let distanceFromTheWristsForTheBelowTheHemSeed = 0.2

    /// `isPerson` is the person mask, one flag per pixel, and `rgba` the photo's tight RGBA rows. Every seed lies on the person.
    init(pose: ShirtModelPose, rgba: [UInt8], isPerson: [Bool], width: Int, height: Int) {
        precondition(isPerson.count == width * height && rgba.count == width * height * 4, "One flag and one color per pixel")
        self.width = width
        self.height = height
        let torso = pose.torso
        let frame = ShirtBodyFrame(torso: torso)
        let shoulderWidth = frame.shoulderWidth
        let hipMidpoint = frame.bodyCoordinates(of: SIMD2(Double(torso.hipMidpoint.x), Double(torso.hipMidpoint.y)))
        let torsoLengthInShoulderWidths = max(hipMidpoint.y, 0.8)
        let hipHalfWidth = abs(frame.bodyCoordinates(of: SIMD2(Double(torso.imageRightHip.x), Double(torso.imageRightHip.y))).x
            - frame.bodyCoordinates(of: SIMD2(Double(torso.imageLeftHip.x), Double(torso.imageLeftHip.y))).x) / 2

        func point(_ cgPoint: CGPoint) -> SIMD2<Double> { SIMD2(Double(cgPoint.x), Double(cgPoint.y)) }
        var discs: [[(center: SIMD2<Double>, radius: Double)]] = Array(repeating: [], count: ShirtModelPart.allCases.count)
        var armBones: [(start: SIMD2<Double>, end: SIMD2<Double>)] = []
        for side in [-1.0, 1.0] {
            let shoulderTop = frame.photoPoint(atBodyCoordinates: SIMD2(side * Self.shoulderTopSeedAcross, Self.shoulderTopSeedDown))
            discs[ShirtModelPart.shirt.rawValue].append((shoulderTop, Self.seedDiscRadius * shoulderWidth))
        }
        func distance(from pixel: SIMD2<Double>, toTheSegmentFrom start: SIMD2<Double>, to end: SIMD2<Double>) -> Double {
            let segment = end - start
            let share = simd_length_squared(segment) > 1e-9 ? min(max(simd_dot(pixel - start, segment) / simd_length_squared(segment), 0), 1) : 0
            return simd_distance(pixel, start + segment * share)
        }
        for (shoulder, elbow, wrist) in [
            (torso.imageLeftShoulder, torso.imageLeftElbow, pose.imageLeftWrist), (torso.imageRightShoulder, torso.imageRightElbow, pose.imageRightWrist),
        ] {
            guard let elbow else { continue }
            // Without a wrist the forearm is taken to hang on from the elbow as long as the upper arm.
            let forearmEnd = wrist.map(point) ?? point(elbow) + (point(elbow) - point(shoulder)) * 0.9
            armBones.append((point(shoulder) + (point(elbow) - point(shoulder)) * Self.upperArmReachStartShare, point(elbow)))
            armBones.append((point(elbow), forearmEnd + (forearmEnd - point(elbow)) * Self.handReachPastTheWristShare))
            let sleevePoint = point(shoulder) + (point(elbow) - point(shoulder)) * Self.sleeveSeedShareDownTheUpperArm
            discs[ShirtModelPart.shirt.rawValue].append((sleevePoint, Self.seedDiscRadius * shoulderWidth))
            // A forearm with no wrist seen (a hand in a pocket) is seeded only near its elbow, since its guessed end may lie
            // on the trousers.
            let lastSeedShare = wrist == nil ? Self.forearmSeedStartShare + 0.2 : 1.0
            for share in stride(from: Self.forearmSeedStartShare, through: lastSeedShare, by: 0.1) {
                discs[ShirtModelPart.arms.rawValue].append((point(elbow) + (forearmEnd - point(elbow)) * share, Self.seedDiscRadius * shoulderWidth))
            }
        }
        if let nose = pose.nose {
            discs[ShirtModelPart.head.rawValue].append((point(nose), Self.faceSeedRadius * shoulderWidth))
            let neckPoint = point(nose) + (frame.origin - point(nose)) * Self.neckSeedShareFromTheNose
            discs[ShirtModelPart.head.rawValue].append((neckPoint, Self.seedDiscRadius * shoulderWidth))
        }
        let wrists = [pose.imageLeftWrist, pose.imageRightWrist].compactMap { $0.map(point) }

        var seeds = Array(repeating: [Bool](repeating: false, count: width * height), count: ShirtModelPart.allCases.count)
        var allowed = Array(repeating: [Bool](repeating: true, count: width * height), count: ShirtModelPart.allCases.count)
        let shirtSeedBottom = min(Self.shirtSeedBottom, 0.85 * torsoLengthInShoulderWidths + 0.25)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                guard isPerson[index] else { continue }
                let pixel = SIMD2(Double(column) + 0.5, Double(row) + 0.5)
                let body = frame.bodyCoordinates(of: pixel)
                if body.y > Self.headReachAtTheMiddle - Self.headReachSlope * abs(body.x) { allowed[ShirtModelPart.head.rawValue][index] = false }
                if !armBones.contains(where: { distance(from: pixel, toTheSegmentFrom: $0.start, to: $0.end) <= Self.armReachFromTheBone * shoulderWidth }) {
                    allowed[ShirtModelPart.arms.rawValue][index] = false
                }
                let inTheChest = abs(body.x) <= Self.shirtSeedHalfWidth && body.y >= Self.shirtSeedTop
                let inTheWaist = abs(body.x) <= Self.shirtWaistSeedHalfWidth && body.y >= Self.shirtWaistSeedTop
                if (inTheChest || inTheWaist), body.y <= shirtSeedBottom {
                    seeds[ShirtModelPart.shirt.rawValue][index] = true
                }
                if pose.nose != nil, body.y < Self.headRegionBottom, abs(body.x) < 0.6 { seeds[ShirtModelPart.head.rawValue][index] = true }
                if body.y > torsoLengthInShoulderWidths * (1 + Self.belowTheHemStartInTorsoLengths), abs(body.x) <= max(hipHalfWidth, 0.3) * 1.1,
                   wrists.allSatisfy({ simd_distance($0, pixel) > Self.distanceFromTheWristsForTheBelowTheHemSeed * shoulderWidth }) {
                    seeds[ShirtModelPart.belowTheHem.rawValue][index] = true
                }
                for part in ShirtModelPart.allCases where discs[part.rawValue].contains(where: { simd_distance($0.center, pixel) <= $0.radius }) {
                    seeds[part.rawValue][index] = true
                }
            }
        }
        // The photo's bottom edge, where its color is unlike the shirt's: trousers the photo cut off above their own seed.
        let shirtShares = ShirtModelPartLabels.binShares(rgba: rgba, of: seeds[ShirtModelPart.shirt.rawValue])
        let bottomEdgeRows = max(1, Int((Double(height) * Self.bottomEdgeShare).rounded()))
        for row in (height - bottomEdgeRows)..<height {
            for column in 0..<width where isPerson[row * width + column] {
                let index = row * width + column
                let shirtShare = shirtShares[ShirtModelPartLabels.colorBin(of: rgba, at: index)]
                if shirtShare < Self.mostShirtShareOfABottomEdgeColor { seeds[ShirtModelPart.belowTheHem.rawValue][index] = true }
            }
        }
        // A pixel two parts claim belongs to neither, so no part's colors are learned from a mixed place, and a part never
        // seeds where it may not reach.
        for index in 0..<(width * height) {
            for part in ShirtModelPart.allCases where !allowed[part.rawValue][index] { seeds[part.rawValue][index] = false }
            let claims = ShirtModelPart.allCases.filter { seeds[$0.rawValue][index] }
            if claims.count > 1 { for part in claims { seeds[part.rawValue][index] = false } }
        }
        seedsOfEachPart = seeds
        allowedOfEachPart = allowed
    }
}

/// The model split into parts: each person pixel's part, or nil off the person.
nonisolated enum ShirtModelPartLabels {
    /// Each color channel is cut into this many bins for a part's color histogram.
    static let colorBinsPerChannel = 16
    /// A step across a color edge costs this much more per unit of color difference (8-bit RGB distance over 32).
    static let colorEdgeWeight = 3.0
    /// A step into a color that the part's seeds rarely have costs this much more per unit of its surprise (minus the log
    /// of the share of the part among all parts' seeds of that color).
    static let unfamiliarColorWeight = 1.5
    /// The raster sweeps over the image: each sweep runs down and then back up, and three reach around a bent arm.
    static let sweepCount = 3

    /// The part each pixel goes to: the part with the smallest cost of a path from its seeds to the pixel over the person.
    /// `rgba` is the photo's tight RGBA rows. Off the person, and where no part's seed reaches, the label is nil.
    static func labels(rgba: [UInt8], isPerson: [Bool], seeds: ShirtModelPartSeeds) -> [ShirtModelPart?] {
        let costs = pathCosts(rgba: rgba, isPerson: isPerson, seeds: seeds)
        return (0..<(seeds.width * seeds.height)).map { index in
            guard isPerson[index] else { return nil }
            var bestPart: ShirtModelPart?
            var bestCost = Double.infinity
            for part in ShirtModelPart.allCases where costs[part.rawValue][index] < bestCost {
                bestCost = costs[part.rawValue][index]
                bestPart = part
            }
            return bestPart
        }
    }

    /// The cheapest path cost from each part's seeds to every pixel, infinite where the part has no seed or cannot reach.
    static let binCount = colorBinsPerChannel * colorBinsPerChannel * colorBinsPerChannel

    /// The color histogram bin of the pixel at `index` of tight RGBA rows.
    static func colorBin(of rgba: [UInt8], at index: Int) -> Int {
        let scale = 256 / colorBinsPerChannel
        return (Int(rgba[index * 4]) / scale * colorBinsPerChannel + Int(rgba[index * 4 + 1]) / scale) * colorBinsPerChannel + Int(rgba[index * 4 + 2]) / scale
    }

    /// The share of the flagged pixels in each color bin, all 0 when none is flagged.
    static func binShares(rgba: [UInt8], of flagged: [Bool]) -> [Double] {
        var shares = [Double](repeating: 0, count: binCount)
        let flaggedCount = flagged.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard flaggedCount > 0 else { return shares }
        for index in flagged.indices where flagged[index] { shares[colorBin(of: rgba, at: index)] += 1 / Double(flaggedCount) }
        return shares
    }

    static func pathCosts(rgba: [UInt8], isPerson: [Bool], seeds: ShirtModelPartSeeds) -> [[Double]] {
        let width = seeds.width, height = seeds.height, pixelCount = width * height
        precondition(rgba.count == pixelCount * 4 && isPerson.count == pixelCount, "One color and one flag per pixel")
        let pixelBins = (0..<pixelCount).map { colorBin(of: rgba, at: $0) }
        // Each part's share of its seeds in each bin, then each bin's share of each part among the parts, as a surprise.
        let parts = ShirtModelPart.allCases
        let shares = parts.map { binShares(rgba: rgba, of: seeds.seedsOfEachPart[$0.rawValue]) }
        let presentParts = parts.filter { part in seeds.seedsOfEachPart[part.rawValue].contains(true) }
        let floorShare = 1e-4
        var surprise = Array(repeating: [Double](repeating: 0, count: binCount), count: parts.count)
        for binIndex in 0..<binCount {
            let total = presentParts.reduce(0.0) { $0 + shares[$1.rawValue][binIndex] + floorShare }
            for part in presentParts {
                surprise[part.rawValue][binIndex] = min(-log((shares[part.rawValue][binIndex] + floorShare) / total), 6)
            }
        }

        func colorDistance(_ first: Int, _ second: Int) -> Double {
            let red = Double(rgba[first * 4]) - Double(rgba[second * 4]), green = Double(rgba[first * 4 + 1]) - Double(rgba[second * 4 + 1])
            let blue = Double(rgba[first * 4 + 2]) - Double(rgba[second * 4 + 2])
            return (red * red + green * green + blue * blue).squareRoot() / 32
        }
        var costs = Array(repeating: [Double](repeating: .infinity, count: pixelCount), count: parts.count)
        for part in presentParts {
            var cost = [Double](repeating: .infinity, count: pixelCount)
            for index in 0..<pixelCount where seeds.seedsOfEachPart[part.rawValue][index] { cost[index] = 0 }
            let partSurprise = surprise[part.rawValue]
            // The part walks only over the person where it may reach.
            let walkable = zip(isPerson, seeds.allowedOfEachPart[part.rawValue]).map { $0 && $1 }
            func relax(_ index: Int, from neighbor: Int, length: Double) {
                guard cost[neighbor] < cost[index] else { return }
                let step = length * (1 + colorEdgeWeight * colorDistance(index, neighbor)) * (1 + unfamiliarColorWeight * partSurprise[pixelBins[index]])
                if cost[neighbor] + step < cost[index] { cost[index] = cost[neighbor] + step }
            }
            let diagonal = 2.0.squareRoot()
            for _ in 0..<sweepCount {
                for row in 0..<height {
                    for column in 0..<width {
                        let index = row * width + column
                        guard walkable[index] else { continue }
                        if column > 0, walkable[index - 1] { relax(index, from: index - 1, length: 1) }
                        if row > 0 {
                            if walkable[index - width] { relax(index, from: index - width, length: 1) }
                            if column > 0, walkable[index - width - 1] { relax(index, from: index - width - 1, length: diagonal) }
                            if column < width - 1, walkable[index - width + 1] { relax(index, from: index - width + 1, length: diagonal) }
                        }
                    }
                }
                for row in stride(from: height - 1, through: 0, by: -1) {
                    for column in stride(from: width - 1, through: 0, by: -1) {
                        let index = row * width + column
                        guard walkable[index] else { continue }
                        if column < width - 1, walkable[index + 1] { relax(index, from: index + 1, length: 1) }
                        if row < height - 1 {
                            if walkable[index + width] { relax(index, from: index + width, length: 1) }
                            if column < width - 1, walkable[index + width + 1] { relax(index, from: index + width + 1, length: diagonal) }
                            if column > 0, walkable[index + width - 1] { relax(index, from: index + width - 1, length: diagonal) }
                        }
                    }
                }
            }
            costs[part.rawValue] = cost
        }
        return costs
    }
}

// MARK: - The shirt's geometry from the model's joints

nonisolated enum ShirtOnModelGeometry {
    /// The sleeve's cloth reaches this far below the armpit's line, in shoulder widths, under the torso.
    static let sleeveTuckBelowTheArmpitInShoulderWidths = 0.05
    /// The armpit lies on the shirt's side this far below the shoulder seams, in shoulder widths.
    static let armholeDepthInShoulderWidths = 0.5
    /// The shirt's sides are measured this far above the hem, in shoulder widths, clear of its curl, and this share of the
    /// way down to the hem, below the sleeves.
    static let hemSideRiseInShoulderWidths = 0.06
    static let upperSideShareOfTheHemDepth = 0.6
    /// The hem's width over the chest's that a T-shirt's cut can have.
    static let hemToChestWidthRatios = 0.75...1.33
    /// Below the armpit, cloth outside the seam's line is the sleeve only within this far of the upper arm's bone, so the
    /// shirt's own flared side at the waist stays torso.
    static let sleeveReachFromTheArmBoneInShoulderWidths = 0.24
    /// The sleeve's opening is read from the band of its cloth this far, in shoulder widths, from its end along the arm.
    static let openingBandInShoulderWidths = 0.07

    /// The shirt's geometry in the cutout, for the renderer. Nil when the cutout has no torso below the shoulders.
    /// - The torso's corners lie on the shirt's own sides, measured below the sleeves and carried up to the shoulder seams'
    ///   height and down to the hem, as a flat lay's lie on its torso's edges. The renderer lands them on the learner's
    ///   shoulders and hips and moves the bottom ones out over a looser old shirt, which assumes the garment's side runs
    ///   straight between them. The model's hip joints are not used: they sit well inside the hips, so a quad on them tapers
    ///   far more than the learner's, whose hips are usually estimated, and the perspective map between the two would squash
    ///   the chest toward the collar.
    /// - The front of the neck hole is the first shirt pixel below the model's neck on the body's center line.
    /// - Each sleeve, when its elbow is seen, is the cloth outside the line from the shoulder seam to the armpit.
    /// `isArm` flags the model's forearm and hand pixels (`ShirtModelPart.arms`), which end each sleeve along its arm.
    static func measurements(of mask: ShirtCutoutMask, isArm: [Bool], pose: ShirtModelPose) -> ShirtGarmentMeasurements? {
        let width = mask.width, height = mask.height
        let torso = pose.torso
        let frame = ShirtBodyFrame(torso: torso)
        let shoulderWidth = frame.shoulderWidth
        func isShirt(_ point: SIMD2<Double>) -> Bool {
            let column = Int(point.x), row = Int(point.y)
            return column >= 0 && column < width && row >= 0 && row < height && mask.pixels[row * width + column] != 0
        }
        let rowHasShirt = { (row: Int) in (0..<width).contains { mask.pixels[row * width + $0] != 0 } }
        guard let topRow = (0..<height).first(where: rowHasShirt), let bottomRow = (0..<height).last(where: rowHasShirt) else { return nil }

        // The hem: down the body from the chest, at each of a few places across the middle, the last shirt pixel before the
        // cloth ends, and their median.
        var hemDepths: [Double] = []
        for acrossShare in stride(from: -0.2, through: 0.2, by: 0.05) {
            var depth = 0.5
            var lastShirtDepth: Double?
            while depth < 3 {
                if isShirt(frame.photoPoint(atBodyCoordinates: SIMD2(acrossShare, depth))) { lastShirtDepth = depth } else if lastShirtDepth != nil { break }
                depth += 1 / shoulderWidth
            }
            if let lastShirtDepth { hemDepths.append(lastShirtDepth) }
        }
        guard hemDepths.count >= 3 else { return nil }
        let hemDepth = hemDepths.sorted()[hemDepths.count / 2]

        let bodyCorners = ShirtTryOnRenderer.bodyTorsoCorners(of: torso).map { SIMD2(Double($0.x), Double($0.y)) }
        // The shirt's sides: across the body at two depths below the sleeves, the run of shirt around the middle, and the line
        // through each side's two ends, from the shoulder line down to the hem.
        func sideEnds(atDepth depth: Double) -> (left: Double, right: Double)? {
            var leftmost = 0.0, rightmost = 0.0
            guard isShirt(frame.photoPoint(atBodyCoordinates: SIMD2(0, depth))) else { return nil }
            while leftmost > -1.5, isShirt(frame.photoPoint(atBodyCoordinates: SIMD2(leftmost - 1 / shoulderWidth, depth))) { leftmost -= 1 / shoulderWidth }
            while rightmost < 1.5, isShirt(frame.photoPoint(atBodyCoordinates: SIMD2(rightmost + 1 / shoulderWidth, depth))) { rightmost += 1 / shoulderWidth }
            return rightmost - leftmost > 0.2 ? (leftmost, rightmost) : nil
        }
        let upperSideDepth = Self.upperSideShareOfTheHemDepth * hemDepth, lowerSideDepth = hemDepth - hemSideRiseInShoulderWidths
        guard let upperSides = sideEnds(atDepth: upperSideDepth), let measuredLowerSides = sideEnds(atDepth: lowerSideDepth), lowerSideDepth - upperSideDepth > 0.1 else { return nil }
        // A hem much narrower or wider than the chest is a hand over it or a hem pulled aside, not the shirt's cut, and a quad
        // on it would taper so far that the perspective map tears the shirt; the sides then run straight down.
        let upperWidth = upperSides.right - upperSides.left, lowerWidth = measuredLowerSides.right - measuredLowerSides.left
        let lowerSides = Self.hemToChestWidthRatios.contains(lowerWidth / upperWidth) ? measuredLowerSides : upperSides
        let topDepth = frame.bodyCoordinates(of: (bodyCorners[0] + bodyCorners[1]) / 2).y
        func onTheSide(_ upper: Double, _ lower: Double, atDepth depth: Double) -> SIMD2<Double> {
            let across = upper + (lower - upper) * (depth - upperSideDepth) / (lowerSideDepth - upperSideDepth)
            return frame.photoPoint(atBodyCoordinates: SIMD2(across, depth))
        }
        let topLeft = onTheSide(upperSides.left, lowerSides.left, atDepth: topDepth), topRight = onTheSide(upperSides.right, lowerSides.right, atDepth: topDepth)
        let bottomLeft = onTheSide(upperSides.left, lowerSides.left, atDepth: hemDepth), bottomRight = onTheSide(upperSides.right, lowerSides.right, atDepth: hemDepth)
        func cgPoint(_ point: SIMD2<Double>) -> CGPoint { CGPoint(x: point.x, y: point.y) }
        let torsoCorners = RoomArtCorners(topLeft: cgPoint(topLeft), topRight: cgPoint(topRight), bottomRight: cgPoint(bottomRight), bottomLeft: cgPoint(bottomLeft))

        // The torso's columns 60 percent of the way down, for the hem band the base color is read from: the run of shirt
        // around the center line.
        let bandPoint = frame.photoPoint(atBodyCoordinates: SIMD2(0, 0.6 * hemDepth))
        let bandRow = min(max(Int(bandPoint.y), 0), height - 1), centerColumn = min(max(Int(bandPoint.x), 0), width - 1)
        var torsoLeftColumn = centerColumn, torsoRightColumn = centerColumn
        while torsoLeftColumn > 0, mask.pixels[bandRow * width + torsoLeftColumn - 1] != 0 { torsoLeftColumn -= 1 }
        while torsoRightColumn < width - 1, mask.pixels[bandRow * width + torsoRightColumn + 1] != 0 { torsoRightColumn += 1 }
        guard torsoRightColumn - torsoLeftColumn >= 8 else { return nil }

        // The front of the neck: down the center line from above the shoulders, the first shirt pixel.
        var frontNeckPoint = cgPoint(frame.origin)
        var frontNeckWasFound = false
        var depth = -0.5
        while depth < 0.4 {
            let point = frame.photoPoint(atBodyCoordinates: SIMD2(0, depth))
            if isShirt(point) {
                // A shirt pixel at the very top of the search is cloth above the neck, not a neck hole.
                if depth > -0.3 { frontNeckPoint = cgPoint(point); frontNeckWasFound = true }
                break
            }
            depth += 1 / shoulderWidth
        }

        let sleeves = [ShirtSleeveSide.imageLeft, .imageRight].map { side in
            sleeve(
                side: side, mask: mask, isArm: isArm, pose: pose, seamTop: side == .imageLeft ? bodyCorners[0] : bodyCorners[1],
                armpit: side == .imageLeft ? onTheSide(upperSides.left, lowerSides.left, atDepth: topDepth + armholeDepthInShoulderWidths)
                    : onTheSide(upperSides.right, lowerSides.right, atDepth: topDepth + armholeDepthInShoulderWidths)
            )
        }
        return ShirtGarmentMeasurements(
            torsoCorners: torsoCorners, frontNeckPoint: frontNeckPoint, frontNeckWasFound: frontNeckWasFound, topRow: topRow, bottomRow: bottomRow,
            torsoLeftColumn: torsoLeftColumn, torsoRightColumn: torsoRightColumn, imageLeftSleeve: sleeves[0], imageRightSleeve: sleeves[1]
        )
    }

    /// One sleeve, or nil when its elbow is not seen or it has too little cloth. Its seam runs from `seamTop`, the shoulder
    /// seam, down to `armpit`, on the shirt's side. It ends along the upper arm where the model's skin starts on it
    /// (`sleeveEnd`), and its opening is across the arm there. Below the armpit, the cloth outside the seam's line and above
    /// that end hangs in front of the shirt's side, so it is sleeve; below the end it is the side seen past the arm.
    static func sleeve(side: ShirtSleeveSide, mask: ShirtCutoutMask, isArm: [Bool], pose: ShirtModelPose, seamTop: SIMD2<Double>, armpit: SIMD2<Double>) -> ShirtSleeveGeometry? {
        let torso = pose.torso
        let isImageLeft = side == .imageLeft
        guard let elbowPoint = isImageLeft ? torso.imageLeftElbow : torso.imageRightElbow else { return nil }
        let width = mask.width, height = mask.height
        let shoulderWidth = torso.shoulderWidth
        let shoulder = isImageLeft ? SIMD2(Double(torso.imageLeftShoulder.x), Double(torso.imageLeftShoulder.y)) : SIMD2(Double(torso.imageRightShoulder.x), Double(torso.imageRightShoulder.y))
        let elbow = SIMD2(Double(elbowPoint.x), Double(elbowPoint.y))
        let armVector = elbow - shoulder
        guard simd_length(armVector) > 1, simd_length(armpit - seamTop) > 1 else { return nil }
        let armDirection = simd_normalize(armVector)
        let seamDirection = simd_normalize(armpit - seamTop)
        let seamBottom = armpit
        // Outward from the seam's line is toward the image edge on this side.
        var outward = SIMD2(-seamDirection.y, seamDirection.x)
        if (isImageLeft && outward.x > 0) || (!isImageLeft && outward.x < 0) { outward = -outward }
        let armLength = simd_length(armVector)
        guard let sleeveEnd = sleeveEnd(isArm: isArm, width: width, height: height, shoulder: shoulder, elbow: elbow, shoulderWidth: shoulderWidth) else { return nil }

        var isSleevePixel = [Bool](repeating: false, count: width * height)
        var alongTheArm: [Double] = []
        var sleeveIndices: [Int] = []
        for row in 0..<height {
            for column in 0..<width where mask.pixels[row * width + column] != 0 {
                let pixel = SIMD2(Double(column) + 0.5, Double(row) + 0.5)
                guard simd_dot(pixel - seamTop, outward) > 0 else { continue }
                let along = simd_dot(pixel - shoulder, armDirection)
                guard along <= sleeveEnd else { continue }
                let fromTheBone = simd_length(pixel - shoulder - armDirection * min(max(along, 0), armLength))
                // The sleeve reaches a little below the armpit's line, under the torso, which keeps that cloth too, so the two
                // overlap there and no gap opens between them when their maps differ.
                let aboveTheArmpit = simd_dot(pixel - seamBottom, seamDirection) <= sleeveTuckBelowTheArmpitInShoulderWidths * shoulderWidth
                guard aboveTheArmpit || fromTheBone <= sleeveReachFromTheArmBoneInShoulderWidths * shoulderWidth else { continue }
                isSleevePixel[row * width + column] = true
                sleeveIndices.append(row * width + column)
                alongTheArm.append(along)
            }
        }
        guard sleeveIndices.count >= 50 else { return nil }
        // The opening: where the cloth ends along the arm (its 98th percentile, so a stray pixel does not move it), across
        // the band just before that end.
        let sortedAlong = alongTheArm.sorted()
        let farthest = sortedAlong[min(sortedAlong.count - 1, Int(0.98 * Double(sortedAlong.count)))]
        let acrossDirection = isImageLeft == (SIMD2(-armDirection.y, armDirection.x).x < 0) ? SIMD2(-armDirection.y, armDirection.x) : SIMD2(armDirection.y, -armDirection.x)
        var acrossValues: [Double] = []
        for (position, index) in sleeveIndices.enumerated() where alongTheArm[position] >= farthest - openingBandInShoulderWidths * shoulderWidth && alongTheArm[position] <= farthest {
            let pixel = SIMD2(Double(index % width) + 0.5, Double(index / width) + 0.5)
            let across = simd_dot(pixel - shoulder, acrossDirection)
            // The opening wraps the arm, so the side of the shirt between the arm and the seam's line is not part of it.
            guard abs(across) <= sleeveReachFromTheArmBoneInShoulderWidths * shoulderWidth else { continue }
            acrossValues.append(across)
        }
        guard acrossValues.count >= 5 else { return nil }
        let sortedAcross = acrossValues.sorted()
        let innermost = sortedAcross[Int(0.03 * Double(sortedAcross.count))], outermost = sortedAcross[min(sortedAcross.count - 1, Int(0.97 * Double(sortedAcross.count)))]
        // `acrossDirection` points away from the body, so the larger value is the outer end.
        let openingOuter = shoulder + armDirection * farthest + acrossDirection * outermost
        let openingInner = shoulder + armDirection * farthest + acrossDirection * innermost
        guard outermost - innermost > 2, farthest > simd_dot(seamTop - shoulder, armDirection) + 2 else { return nil }
        func cgPoint(_ point: SIMD2<Double>) -> CGPoint { CGPoint(x: point.x, y: point.y) }
        return ShirtSleeveGeometry(
            side: side, seamTop: cgPoint(seamTop), seamBottom: cgPoint(seamBottom), openingOuter: cgPoint(openingOuter), openingInner: cgPoint(openingInner),
            isSleevePixel: isSleevePixel, splitsFromTheArmpit: true
        )
    }
}

extension ShirtOnModelGeometry {
    /// Skin within this far of the upper arm's bone, in shoulder widths, is the arm below the sleeve.
    static let armSkinReachFromTheBoneInShoulderWidths = 0.15
    /// A sleeve with no skin found on its upper arm, such as an arm the split missed, ends this share of the way to the
    /// elbow, a short sleeve's usual end. A long sleeve on a model never gets here, since `roomArtReadingPlan` refuses it.
    static let sleeveEndShareWithNoSkin = 0.55

    /// How far along the upper arm from the shoulder, in pixels, the sleeve ends: where the model's arm skin starts near the
    /// bone (the 3rd percentile of its pixels along the arm, so a stray pixel does not move it). Nil when the arm is too short
    /// to measure.
    static func sleeveEnd(isArm: [Bool], width: Int, height: Int, shoulder: SIMD2<Double>, elbow: SIMD2<Double>, shoulderWidth: Double) -> Double? {
        let armVector = elbow - shoulder, armLength = simd_length(armVector)
        guard armLength > 1, isArm.count == width * height else { return nil }
        let armDirection = armVector / armLength
        var skinAlong: [Double] = []
        // Only the box around the upper arm can hold its skin.
        let reach = armSkinReachFromTheBoneInShoulderWidths * shoulderWidth
        let left = max(0, Int(min(shoulder.x, elbow.x) - reach)), right = min(width - 1, Int(max(shoulder.x, elbow.x) + reach))
        let top = max(0, Int(min(shoulder.y, elbow.y) - reach)), bottom = min(height - 1, Int(max(shoulder.y, elbow.y) + reach))
        guard left <= right, top <= bottom else { return nil }
        for row in top...bottom {
            for column in left...right where isArm[row * width + column] {
                let pixel = SIMD2(Double(column) + 0.5, Double(row) + 0.5)
                let along = simd_dot(pixel - shoulder, armDirection)
                guard along > 0, along <= armLength else { continue }
                if simd_length(pixel - shoulder - armDirection * along) <= reach { skinAlong.append(along) }
            }
        }
        guard skinAlong.count >= 20 else { return sleeveEndShareWithNoSkin * armLength }
        return skinAlong.sorted()[Int(0.03 * Double(skinAlong.count))]
    }
}

// MARK: - The garment

extension ShirtGarment {
    /// The split runs on a copy this many times smaller than the working photo, and its costs are scaled back up, so it takes
    /// a fraction of the time and its edges are still smooth.
    nonisolated static let onModelLabelDownscale = 2
    /// The cutout's borders with the skin and the trousers come from the split's half-size grid, so they step. A pixel is
    /// shirt when most of the square of this radius around it is, which rounds the steps off.
    nonisolated static let onModelBorderRoundingRadius = 2

    /// `flags` with each pixel set when more than half of the square of `radius` around it is set, through a summed area
    /// table. Pixels past the image's edge count as unset.
    nonisolated static func roundedCorners(of flags: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        precondition(flags.count == width * height, "One flag per pixel")
        let tableWidth = width + 1
        var sums = [Int](repeating: 0, count: tableWidth * (height + 1))
        for row in 0..<height {
            var rowSum = 0
            for column in 0..<width {
                if flags[row * width + column] { rowSum += 1 }
                sums[(row + 1) * tableWidth + column + 1] = sums[row * tableWidth + column + 1] + rowSum
            }
        }
        let side = 2 * radius + 1
        return (0..<(width * height)).map { index in
            let row = index / width, column = index % width
            let top = max(0, row - radius), bottom = min(height, row + radius + 1), left = max(0, column - radius), right = min(width, column + radius + 1)
            let setCount = sums[bottom * tableWidth + right] - sums[top * tableWidth + right] - sums[bottom * tableWidth + left] + sums[top * tableWidth + left]
            return 2 * setCount > side * side
        }
    }

    /// The garment from a photo of the shirt worn by a model, nil when no model is found or the shirt cannot be cut out of
    /// them. `itemCorners` say where the shirt is, so the model wearing it is picked. The whole photo is used, since the
    /// joints the cut relies on (the nose, the wrists) lie outside the shirt's corners. Slow (Vision and the split, about 0.3
    /// to 1 second in a release build), so call it off the main actor.
    nonisolated static func make(onModelPhoto productPhoto: CGImage, itemCorners: RoomArtCorners) -> ShirtGarment? {
        let wholePhoto = RoomArtCorners(
            topLeft: .zero, topRight: CGPoint(x: productPhoto.width, y: 0),
            bottomRight: CGPoint(x: productPhoto.width, y: productPhoto.height), bottomLeft: CGPoint(x: 0, y: productPhoto.height)
        )
        guard let workingPhoto = workingPhoto(productPhoto: productPhoto, itemCorners: wholePhoto), let photoPixels = rgbaPixels(of: workingPhoto) else { return nil }
        let scale = Double(workingPhoto.width) / Double(productPhoto.width)
        let corners = itemCorners.clockwiseFromTopLeft
        let itemCenter = CGPoint(x: corners.map(\.x).reduce(0, +) / 4 * scale, y: corners.map(\.y).reduce(0, +) / 4 * scale)
        guard let pose = ShirtModelPose.detect(in: workingPhoto, nearestTo: itemCenter), let personMask = personMask(of: workingPhoto) else { return nil }
        return make(onModelPhotoPixels: photoPixels, width: workingPhoto.width, height: workingPhoto.height, personMask: personMask, pose: pose)
    }

    /// The person mask of `photo` at its own size, from Vision's person segmentation at its accurate level, one value from 0
    /// to 255 per pixel.
    nonisolated static func personMask(of photo: CGImage) -> [UInt8]? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do { try VNImageRequestHandler(cgImage: photo).perform([request]) } catch { return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: Double(photo.width) / mask.extent.width, y: Double(photo.height) / mask.extent.height))
        var bytes = [UInt8](repeating: 0, count: photo.width * photo.height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            // Core Image writes the top row first, as the photo's pixels are.
            CIContext().render(scaled, toBitmap: baseAddress, rowBytes: photo.width, bounds: CGRect(x: 0, y: 0, width: photo.width, height: photo.height), format: .R8, colorSpace: nil)
        }
        return bytes
    }

    /// The garment from the working photo's pixels, its person mask (0 to 255 per pixel), and the model's pose. Pure apart
    /// from making the images, so a test can pass a drawn model.
    nonisolated static func make(onModelPhotoPixels photoPixels: [UInt8], width: Int, height: Int, personMask: [UInt8], pose: ShirtModelPose) -> ShirtGarment? {
        // The part split reads whole blocks of `onModelLabelDownscale` pixels, so a side shorter than one block has none.
        guard photoPixels.count == width * height * 4, personMask.count == width * height,
              width >= onModelLabelDownscale, height >= onModelLabelDownscale else { return nil }
        let isPerson = personMask.map { $0 >= 128 }
        guard let labels = onModelPartLabels(photoPixels: photoPixels, isPerson: isPerson, width: width, height: height, pose: pose) else { return nil }
        let shirtPixels = zip(labels, isPerson).map { label, person in person && label == .shirt }
        let shirtMask = ShirtCutoutMask(
            width: width, height: height,
            pixels: roundedCorners(of: shirtPixels, width: width, height: height, radius: onModelBorderRoundingRadius).map { $0 ? 255 : 0 }
        ).keepingTheLargestPiece()
        let isArm = labels.map { $0 == .arms }
        guard let measurements = ShirtOnModelGeometry.measurements(of: shirtMask, isArm: isArm, pose: pose) else { return nil }
        // The photo's own white is read from its backdrop, off the person well clear of their outline.
        let backgroundMask = personMask.map { $0 < 26 }
        return make(photoPixels: photoPixels, cutoutMask: shirtMask, outlineMask: shirtMask, measurements: measurements, backgroundMask: backgroundMask, modelPose: pose)
    }

    /// Each pixel's part at the working photo's size: the split runs on a smaller copy, and each part's path costs are
    /// scaled back up and compared at every pixel, so the parts' borders are smooth curves. Nil when the shirt has no seed.
    nonisolated static func onModelPartLabels(photoPixels: [UInt8], isPerson: [Bool], width: Int, height: Int, pose: ShirtModelPose) -> [ShirtModelPart?]? {
        let downscale = onModelLabelDownscale
        let smallWidth = max(1, width / downscale), smallHeight = max(1, height / downscale)
        var smallPixels = [UInt8](repeating: 0, count: smallWidth * smallHeight * 4)
        var smallIsPerson = [Bool](repeating: false, count: smallWidth * smallHeight)
        for row in 0..<smallHeight {
            for column in 0..<smallWidth {
                // The mean of the block's colors, and the block counts as the person when most of it is.
                var sums = [0, 0, 0], personCount = 0
                for blockRow in 0..<downscale {
                    for blockColumn in 0..<downscale {
                        let index = (row * downscale + blockRow) * width + column * downscale + blockColumn
                        for channel in 0..<3 { sums[channel] += Int(photoPixels[index * 4 + channel]) }
                        if isPerson[index] { personCount += 1 }
                    }
                }
                let blockSize = downscale * downscale
                for channel in 0..<3 { smallPixels[(row * smallWidth + column) * 4 + channel] = UInt8(sums[channel] / blockSize) }
                smallIsPerson[row * smallWidth + column] = personCount * 2 > blockSize
            }
        }
        let smallTorso = pose.torso.scaled(by: 1 / Double(downscale))
        func scaledPoint(_ point: CGPoint?) -> CGPoint? { point.map { CGPoint(x: $0.x / Double(downscale), y: $0.y / Double(downscale)) } }
        let smallPose = ShirtModelPose(torso: smallTorso, nose: scaledPoint(pose.nose), imageLeftWrist: scaledPoint(pose.imageLeftWrist), imageRightWrist: scaledPoint(pose.imageRightWrist))
        let seeds = ShirtModelPartSeeds(pose: smallPose, rgba: smallPixels, isPerson: smallIsPerson, width: smallWidth, height: smallHeight)
        guard seeds.seedsOfEachPart[ShirtModelPart.shirt.rawValue].contains(true) else { return nil }
        let costs = ShirtModelPartLabels.pathCosts(rgba: smallPixels, isPerson: smallIsPerson, seeds: seeds)

        // Each part's cost at a full size pixel is the bilinear blend of the four small pixels around it, skipping any the
        // part cannot reach, so the person's outline does not pull an infinite cost in.
        var labels = [ShirtModelPart?](repeating: nil, count: width * height)
        for row in 0..<height {
            let smallY = min(max((Double(row) + 0.5) / Double(downscale) - 0.5, 0), Double(smallHeight - 1))
            let top = Int(smallY), bottom = min(top + 1, smallHeight - 1), rowShare = smallY - Double(top)
            for column in 0..<width where isPerson[row * width + column] {
                let smallX = min(max((Double(column) + 0.5) / Double(downscale) - 0.5, 0), Double(smallWidth - 1))
                let left = Int(smallX), right = min(left + 1, smallWidth - 1), columnShare = smallX - Double(left)
                let corners = [
                    (top * smallWidth + left, (1 - rowShare) * (1 - columnShare)), (top * smallWidth + right, (1 - rowShare) * columnShare),
                    (bottom * smallWidth + left, rowShare * (1 - columnShare)), (bottom * smallWidth + right, rowShare * columnShare),
                ]
                var bestPart: ShirtModelPart?, bestCost = Double.infinity
                for part in ShirtModelPart.allCases {
                    var weightedCost = 0.0, weightSum = 0.0
                    for (index, weight) in corners where costs[part.rawValue][index].isFinite {
                        weightedCost += costs[part.rawValue][index] * weight
                        weightSum += weight
                    }
                    guard weightSum > 1e-9 else { continue }
                    let cost = weightedCost / weightSum
                    if cost < bestCost { bestCost = cost; bestPart = part }
                }
                labels[row * width + column] = bestPart
            }
        }
        return labels
    }
}

// MARK: - The sleeves on the learner

nonisolated enum ShirtOnModelSleeveLanding {
    /// Where an on-model sleeve's quadrilateral (`ShirtSleeveGeometry.quadrilateral`) lands on the learner, or nil when either
    /// of its triangles would land mirrored. The seam lands where the torso's map puts it, so the sleeve meets the torso. The
    /// opening's two ends keep where they lay on the model's arm, measured from the shoulder along and across the arm in
    /// shoulder widths, so the sleeve hangs off the learner's arm at the angle it hung off the model's. With `oldSleeve`
    /// (camera pixels, already grown by its margin), the opening moves down the arm and widens until it covers the learner's
    /// own sleeve, so it never shows under the new one. Covering the old sleeve's inner side can push the opening's inner end
    /// under the torso and turn the inner triangle over, so the landing tries the whole cover, then the cover without its
    /// inner side, then the sleeve as the model wore it, as a flat lay's sleeve does.
    static func landing(
        of sleeve: ShirtSleeveGeometry, modelPose: ShirtModelPose, torso: BodyTorso, torsoHomography: simd_double3x3, oldSleeve: ShirtOldSleeveExtent?
    ) -> [CGPoint]? {
        let oldSleeveWithoutItsInnerSide = oldSleeve.map { ShirtOldSleeveExtent(reachAlongTheArm: $0.reachAlongTheArm, outward: $0.outward, inward: -Double.infinity) }
        return [oldSleeve, oldSleeveWithoutItsInnerSide, nil].lazy.compactMap { cover in
            landingCovering(cover, of: sleeve, modelPose: modelPose, torso: torso, torsoHomography: torsoHomography)
        }.first
    }

    /// One try of `landing`, covering `oldSleeve` when it is given.
    static func landingCovering(
        _ oldSleeve: ShirtOldSleeveExtent?, of sleeve: ShirtSleeveGeometry, modelPose: ShirtModelPose, torso: BodyTorso, torsoHomography: simd_double3x3
    ) -> [CGPoint]? {
        let isImageLeft = sleeve.side == .imageLeft
        guard let modelElbow = isImageLeft ? modelPose.torso.imageLeftElbow : modelPose.torso.imageRightElbow,
              let learnerElbow = isImageLeft ? torso.imageLeftElbow : torso.imageRightElbow else { return nil }
        let modelShoulder = isImageLeft ? modelPose.torso.imageLeftShoulder : modelPose.torso.imageRightShoulder
        let learnerShoulder = isImageLeft ? torso.imageLeftShoulder : torso.imageRightShoulder
        guard let modelArm = ArmFrame(shoulder: modelShoulder, elbow: modelElbow, torso: modelPose.torso),
              let learnerArm = ArmFrame(shoulder: learnerShoulder, elbow: learnerElbow, torso: torso) else { return nil }

        let seamTop = applyingPerspective(torsoHomography, to: sleeve.seamTop), seamBottom = applyingPerspective(torsoHomography, to: sleeve.seamBottom)
        var openingOuter = learnerArm.point(at: modelArm.coordinates(of: sleeve.openingOuter))
        var openingInner = learnerArm.point(at: modelArm.coordinates(of: sleeve.openingInner))
        if let oldSleeve {
            // Down the arm to the old sleeve's reach, short of the elbow, then wide enough for its two sides.
            let openingCenter = (openingOuter + openingInner) / 2
            let downTheArm = simd_dot(openingCenter - learnerArm.shoulder, learnerArm.down)
            let wantedDownTheArm = min(max(downTheArm, oldSleeve.reachAlongTheArm), ShirtTryOnRenderer.mostSleeveReachShareOfTheArm * learnerArm.length)
            let shift = learnerArm.down * (wantedDownTheArm - downTheArm)
            openingOuter += shift
            openingInner += shift
            let outerOut = simd_dot(openingOuter - learnerArm.shoulder, learnerArm.out), innerOut = simd_dot(openingInner - learnerArm.shoulder, learnerArm.out)
            openingOuter += learnerArm.out * (max(outerOut, oldSleeve.outward) - outerOut)
            openingInner += learnerArm.out * (min(innerOut, -oldSleeve.inward) - innerOut)
        }
        let landing = [seamTop, CGPoint(x: openingOuter.x, y: openingOuter.y), CGPoint(x: openingInner.x, y: openingInner.y), seamBottom]
        // Each triangle must turn the same way on the body as in the photo, or its map would mirror the cloth.
        func turn(_ first: CGPoint, _ second: CGPoint, _ third: CGPoint) -> Double {
            (second.x - first.x) * (third.y - first.y) - (second.y - first.y) * (third.x - first.x)
        }
        let source = sleeve.quadrilateral
        for triangle in [sleeve.triangleIndices.first, sleeve.triangleIndices.second] {
            let sourceTurn = turn(source[triangle[0]], source[triangle[1]], source[triangle[2]]), landingTurn = turn(landing[triangle[0]], landing[triangle[1]], landing[triangle[2]])
            guard abs(landingTurn) > 1e-6, (sourceTurn > 0) == (landingTurn > 0) else { return nil }
        }
        return landing
    }

    /// An upper arm as axes: `down` from the shoulder toward the elbow, `out` across it away from the body, in pixels, with
    /// the shoulder width as the unit of its coordinates.
    struct ArmFrame {
        let shoulder: SIMD2<Double>
        let down: SIMD2<Double>
        let out: SIMD2<Double>
        let length: Double
        let shoulderWidth: Double

        init?(shoulder shoulderPoint: CGPoint, elbow elbowPoint: CGPoint, torso: BodyTorso) {
            shoulder = SIMD2(Double(shoulderPoint.x), Double(shoulderPoint.y))
            let arm = SIMD2(Double(elbowPoint.x), Double(elbowPoint.y)) - shoulder
            length = simd_length(arm)
            shoulderWidth = torso.shoulderWidth
            guard length > 1, shoulderWidth > 1 else { return nil }
            down = arm / length
            var across = SIMD2(-down.y, down.x)
            let bodyCenter = SIMD2(Double(torso.shoulderMidpoint.x), Double(torso.shoulderMidpoint.y))
            if simd_dot(across, shoulder - bodyCenter) < 0 { across = -across }
            out = across
        }

        func coordinates(of point: CGPoint) -> SIMD2<Double> {
            let offset = SIMD2(Double(point.x), Double(point.y)) - shoulder
            return SIMD2(simd_dot(offset, down), simd_dot(offset, out)) / shoulderWidth
        }

        func point(at coordinates: SIMD2<Double>) -> SIMD2<Double> {
            shoulder + (down * coordinates.x + out * coordinates.y) * shoulderWidth
        }
    }
}
