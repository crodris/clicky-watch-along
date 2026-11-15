//
//  LiveSceneNarration.swift
//  leanring-buddy
//
//  What Clicky says about a bundled page it put on screen, and the data it
//  trusts while saying it. A frame pop-out is narrated one part at a time, and
//  a tapped label is explained the same way, with the blue cursor pointing at
//  each part as Clicky names it. The landmark page gets one line built from
//  the /landmark reply. Generated /live-scene pages are not covered.
//

import CoreGraphics
import Foundation

/// The bundled page Clicky put on screen, with Clicky's own copy of its data.
/// Narration and label taps read this, never what the page reports about itself.
enum LiveScenePageOnScreen {
    /// A page GPT wrote for /live-scene. It gets none of the bundled-page narration or taps.
    case generatedPage
    /// A generated page with controls and a run. It gets no narration or taps either, only a line about each run's readouts.
    case simulation
    case framePopout(VideoFramePopout)
    case landmark(FamousPlace)
}

/// Why Clicky is about to talk about a frame pop-out.
enum LiveSceneNarrationTrigger: Equatable {
    /// The camera tour of a pop-out with no quiz just ended.
    case afterTour
    /// The learner clicked this part's label after the tour. The label is one from Clicky's own parts list.
    case partTapped(label: String)
}

/// A message the page posts to the liveSceneEvent handler, parsed at the page boundary.
enum LiveScenePageEvent: Equatable {
    case tourFinished
    /// A frame pop-out landed back in its video frame after a clear.
    case returnFinished
    /// The label text comes from the page, so it is untrusted until matched against Clicky's parts list.
    case partTapped(untrustedLabel: String)
    /// A simulation run ended. scene-tools.js posts the readouts, which are the page's text and values.
    case simulationRunFinished(readouts: [SimulationReadout])

    private static let partTappedPrefix = "partTapped:"
    private static let runFinishedPrefix = "runFinished:"

    init?(messageBody: Any) {
        guard let messageText = messageBody as? String else { return nil }
        if messageText == "tourFinished" {
            self = .tourFinished
            return
        }
        if messageText == "returnFinished" {
            self = .returnFinished
            return
        }
        if messageText.hasPrefix(Self.runFinishedPrefix) {
            let readouts = SimulationReadout.readouts(fromPageJSON: String(messageText.dropFirst(Self.runFinishedPrefix.count)))
            guard !readouts.isEmpty else { return nil }
            self = .simulationRunFinished(readouts: readouts)
            return
        }
        guard messageText.hasPrefix(Self.partTappedPrefix) else { return nil }
        self = .partTapped(untrustedLabel: String(messageText.dropFirst(Self.partTappedPrefix.count)))
    }
}

/// One number a simulation measured in its last run, such as the landing distance in meters.
/// The page wrote the label and unit, and Clicky says them aloud, so each is cut to a short length here.
struct SimulationReadout: Equatable {
    let label: String
    let value: Double
    let unit: String

    private static let mostReadouts = 3
    private static let longestLabel = 40
    private static let longestUnit = 16

    /// Up to 3 readouts with a non-empty label and a finite value. Anything else in the JSON is dropped.
    static func readouts(fromPageJSON pageJSON: String) -> [SimulationReadout] {
        guard let jsonData = pageJSON.data(using: .utf8),
              let jsonEntries = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            return []
        }
        let readouts: [SimulationReadout] = jsonEntries.compactMap { jsonEntry in
            guard let label = (jsonEntry["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty,
                  let value = jsonEntry["value"] as? Double,
                  value.isFinite else {
                return nil
            }
            let unit = (jsonEntry["unit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SimulationReadout(label: String(label.prefix(longestLabel)), value: value, unit: String(unit.prefix(longestUnit)))
        }
        return Array(readouts.prefix(mostReadouts))
    }
}

/// The one short line Clicky says after a simulation run, built from the readouts with no model call so it never lags
/// or misreads a number. "That run gave a landing distance of 40.84 meters, and a peak height of 10.2 meters."
/// Only the first two readouts are said, and nil means there is nothing to say.
func simulationReadoutSpokenLine(for readouts: [SimulationReadout]) -> String? {
    let sentenceParts = readouts.prefix(2).map { readout in
        let lowercaseLabel = readout.label.prefix(1).lowercased() + readout.label.dropFirst()
        let valueText = readout.value.formatted(
            .number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))
        )
        let spokenUnit = spokenSimulationUnit(readout.unit)
        let article = lowercaseLabel.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        return "\(article) \(lowercaseLabel) of \(valueText)\(spokenUnit.isEmpty ? "" : " " + spokenUnit)"
    }
    guard !sentenceParts.isEmpty else { return nil }
    return "That run gave " + sentenceParts.joined(separator: ", and ") + "."
}

/// Text to speech reads "m" as a letter, so a short unit becomes its word. A unit the table does not know is said as written.
private func spokenSimulationUnit(_ unit: String) -> String {
    let spokenUnitsByWrittenUnit = [
        "m": "meters", "cm": "centimeters", "s": "seconds", "m/s": "meters per second", "m/s2": "meters per second squared",
        "m/s^2": "meters per second squared", "kg": "kilograms", "N": "newtons", "N·m": "newton meters", "Nm": "newton meters",
        "J": "joules", "W": "watts", "Hz": "hertz", "deg": "degrees", "°": "degrees", "rad": "radians",
    ]
    return spokenUnitsByWrittenUnit[unit] ?? unit
}

/// The part label a tap asks about, taken from Clicky's own parts list, or nil when the tap is ignored.
/// Only the bundled frame pop-out takes taps, and only once its tour is over and every label shows.
func partLabelToExplain(
    untrustedTappedLabel: String,
    pageOnScreen: LiveScenePageOnScreen?,
    liveScenePhase: LiveScenePhase
) -> String? {
    guard case .allLabelsShowing = liveScenePhase,
          case .framePopout(let framePopout) = pageOnScreen else {
        return nil
    }
    return framePopout.parts.first { part in
        part.label == untrustedTappedLabel
    }?.label
}

/// Claude may change the case of a part name in a [PART:name] tag, so it is matched
/// back to the exact label in Clicky's parts list. Nil when it names no known part.
func knownPartLabel(matching spokenPartLabel: String?, knownPartLabels: [String]) -> String? {
    guard let spokenPartLabel else { return nil }
    let wantedLabel = spokenPartLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return knownPartLabels.first { knownLabel in
        knownLabel.lowercased() == wantedLabel
    }
}

// MARK: - Prompts

/// Where a frame pop-out was lifted from, so Clicky never calls an image on a web page a video.
enum FramePopoutSource {
    case pausedYouTubeFrame
    case pageImage

    /// The prompt's sentence about what lifted out, and what the attached image is.
    func narrationSourceSentence(hasPartLabels: Bool) -> String {
        let model = hasPartLabels ? "a 3d model with labeled parts" : "a 3d model"
        switch self {
        case .pausedYouTubeFrame:
            return "something from the video they're watching just lifted out of the paused frame as \(model). the image is that paused frame."
        case .pageImage:
            return "something from a picture on the web page they're reading just lifted out of the page as \(model). the image is that picture."
        }
    }

    var narrationImageLabel: String {
        switch self {
        case .pausedYouTubeFrame:
            return "the paused video frame the 3d model was lifted from"
        case .pageImage:
            return "the picture on the web page the 3d model was lifted from"
        }
    }
}

/// Kept apart from the companion prompt, which asks for [POINT:] tags that make no sense here.
/// An artwork gets facts about the art, since saying what a painting shows tells them nothing they can't see.
/// An animated picture lifts out with no labels, so its sentences name no part.
func liveSceneNarrationSystemPrompt(for framePopoutSource: FramePopoutSource, isArtwork: Bool, hasPartLabels: Bool = true) -> String {
    let whatEachSentenceSays: String
    switch (isArtwork, hasPartLabels) {
    case (true, true):
        whatEachSentenceSays = "it's a work of art. make each sentence one true fact about the artwork itself that ties to the part it names: who made it, when, how it was made, the story behind it, or why it became famous. never just say what the part shows, since they can see that. say only facts you're sure of, and if you don't recognize this exact artwork, talk about the technique and materials you can see instead of guessing its name or its artist."
    case (true, false):
        whatEachSentenceSays = "it's a work of art. make each sentence one true fact about the artwork itself: who made it, when, how it was made, the story behind it, or why it became famous. say only facts you're sure of, and if you don't recognize this exact artwork, talk about the technique and materials you can see instead of guessing its name or its artist."
    case (false, true):
        whatEachSentenceSays = "make each sentence say one surprising or useful thing about that part."
    case (false, false):
        whatEachSentenceSays = "make each sentence say one surprising or useful thing about what the picture shows."
    }
    return """
    you're clicky, a friendly guide talking out loud to a curious 11-year-old. \(framePopoutSource.narrationSourceSentence(hasPartLabels: hasPartLabels)) your words go to text to speech, so write the way you'd talk: short sentences, plain words, no lists, no markdown, no emojis, no abbreviations. the words also show as captions, so use normal sentence case and capitalize every name, such as people, places, languages, and nationalities (Hokusai, Japan, Japanese). \(whatEachSentenceSays) never tell them to click, scroll, or look anywhere else.
    """
}

func liveSceneNarrationUserPrompt(for narrationTrigger: LiveSceneNarrationTrigger, knownPartLabels: [String], isArtwork: Bool) -> String {
    // An animated picture lifts out with no labels, and no label can be tapped, so the narration names no parts.
    // The attached image is only its first frame, so the narration talks about the motion, not what that frame shows.
    if knownPartLabels.isEmpty {
        let whatToTalkAbout = isArtwork
            ? "say two or three short true facts about the artwork"
            : "talk about what the animation shows happening: the motion itself, how it works, and why it matters. don't describe the places or things that happen to be in this one frame, since they move away. say two or three short sentences"
        return """
        this picture is an animation, and the image is only its first frame, so it keeps moving while you talk. \(whatToTalkAbout), without any [PART:] tags.
        """
    }
    let partNamesLine = "the labeled parts are exactly: \(knownPartLabels.joined(separator: ", "))."
    switch (narrationTrigger, isArtwork) {
    case (.afterTour, false):
        return """
        \(partNamesLine)
        say two or three short sentences, one per part, picking the parts an 11-year-old would find most interesting. start each sentence with [PART:name] using one of those exact names.
        """
    case (.afterTour, true):
        return """
        \(partNamesLine)
        say two or three short sentences, one per part, picking the parts with the most interesting facts about the artwork behind them. start each sentence with [PART:name] using one of those exact names.
        """
    case (.partTapped(let label), false):
        return """
        \(partNamesLine)
        the learner tapped the \(label) label and asks: what does the \(label) do? answer in one or two short sentences. start the first sentence with [PART:\(label)].
        """
    case (.partTapped(let label), true):
        return """
        \(partNamesLine)
        the learner tapped the \(label) label and wants to know about it. answer with one or two short facts about the \(label) in this artwork. start the first sentence with [PART:\(label)].
        """
    }
}

/// One spoken line for the landmark page, naming the place with its height from the /landmark reply.
func landmarkNarrationLine(for famousPlace: FamousPlace) -> String {
    let nameInASentence = famousPlace.nameTakesThe ? "the \(famousPlace.name)" : famousPlace.name
    let roundedHeightMeters = Int(famousPlace.heightMeters.rounded())
    // About 3 meters a floor, so a kid can picture the height as a building.
    let buildingFloorCount = Int((famousPlace.heightMeters / 3).rounded())
    guard buildingFloorCount >= 2 else {
        return "This is \(nameInASentence), in real 3D. It stands about \(roundedHeightMeters) meters tall."
    }
    return "This is \(nameInASentence), in real 3D. It stands about \(roundedHeightMeters) meters tall, as high as a \(buildingFloorCount)-story building."
}

// MARK: - Pointing the blue cursor at a part

/// A part label's box as the page measures it with getBoundingClientRect, in CSS pixels
/// from the top left of the overlay page. The overlay page is not zoomed, so a CSS pixel is a point.
struct LiveScenePartLabelRectInPage: Equatable {
    let label: String
    let left: Double
    let top: Double
    let width: Double
    let height: Double

    init(label: String, left: Double, top: Double, width: Double, height: Double) {
        self.label = label
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    /// Nil when the page sent something other than a label and four numbers.
    init?(pageValue: Any) {
        guard let rectFields = pageValue as? [String: Any],
              let label = rectFields["label"] as? String,
              let left = rectFields["left"] as? Double,
              let top = rectFields["top"] as? Double,
              let width = rectFields["width"] as? Double,
              let height = rectFields["height"] as? Double else {
            return nil
        }
        self.init(label: label, left: left, top: top, width: width, height: height)
    }
}

/// Where the blue cursor points for one part label, in global AppKit points
/// (origin at the bottom left of the main display), the space OverlayWindow animates in.
struct LiveScenePartScreenPoint: Equatable {
    let label: String
    let globalPoint: CGPoint
}

/// The quiz's "?" label, found by the part the frame parts call marked as the answer, since that part's label and the
/// planner's answer label can name it differently, such as "Ampullae of Lorenzini" and "Ampullae". A page with no
/// marked part falls back to the answer label.
func quizQuestionLabelScreenPoint(in labelScreenPoints: [LiveScenePartScreenPoint], quizAnswerPartLabel: String?, answerLabel: String) -> LiveScenePartScreenPoint? {
    let labelToFind = quizAnswerPartLabel ?? answerLabel
    return labelScreenPoints.first { labelScreenPoint in labelScreenPoint.label == labelToFind }
}

/// The middle of the label's bottom edge. The cursor lands just below and right of its target
/// and points up and left, so it sits under the label pointing at it.
/// The overlay page fills `overlayScreenFrame`, and the page's y grows down while AppKit's grows up.
func partScreenPoint(of labelRect: LiveScenePartLabelRectInPage, overlayScreenFrame: CGRect) -> LiveScenePartScreenPoint {
    let pointXInPage = labelRect.left + labelRect.width / 2
    let pointYInPage = labelRect.top + labelRect.height
    return LiveScenePartScreenPoint(
        label: labelRect.label,
        globalPoint: CGPoint(
            x: overlayScreenFrame.minX + pointXInPage,
            y: overlayScreenFrame.maxY - pointYInPage
        )
    )
}
