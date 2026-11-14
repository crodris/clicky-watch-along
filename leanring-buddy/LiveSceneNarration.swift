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

    private static let partTappedPrefix = "partTapped:"

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
        guard messageText.hasPrefix(Self.partTappedPrefix) else { return nil }
        self = .partTapped(untrustedLabel: String(messageText.dropFirst(Self.partTappedPrefix.count)))
    }
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
    var narrationSourceSentence: String {
        switch self {
        case .pausedYouTubeFrame:
            return "something from the video they're watching just lifted out of the paused frame as a 3d model with labeled parts. the image is that paused frame."
        case .pageImage:
            return "something from a picture on the web page they're reading just lifted out of the page as a 3d model with labeled parts. the image is that picture."
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
func liveSceneNarrationSystemPrompt(for framePopoutSource: FramePopoutSource, isArtwork: Bool) -> String {
    let whatEachSentenceSays = isArtwork
        ? "it's a work of art. make each sentence one true fact about the artwork itself that ties to the part it names: who made it, when, how it was made, the story behind it, or why it became famous. never just say what the part shows, since they can see that. say only facts you're sure of, and if you don't recognize this exact artwork, talk about the technique and materials you can see instead of guessing its name or its artist."
        : "make each sentence say one surprising or useful thing about that part."
    return """
    you're clicky, a friendly guide talking out loud to a curious 11-year-old. \(framePopoutSource.narrationSourceSentence) your words go to text to speech, so write the way you'd talk: short sentences, plain words, all lowercase, no lists, no markdown, no emojis, no abbreviations. \(whatEachSentenceSays) never tell them to click, scroll, or look anywhere else.
    """
}

func liveSceneNarrationUserPrompt(for narrationTrigger: LiveSceneNarrationTrigger, knownPartLabels: [String], isArtwork: Bool) -> String {
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
    let roundedHeightMeters = Int(famousPlace.heightMeters.rounded())
    // About 3 meters a floor, so a kid can picture the height as a building.
    let buildingFloorCount = Int((famousPlace.heightMeters / 3).rounded())
    guard buildingFloorCount >= 2 else {
        return "This is \(famousPlace.name), in real 3D. It stands about \(roundedHeightMeters) meters tall."
    }
    return "This is \(famousPlace.name), in real 3D. It stands about \(roundedHeightMeters) meters tall, as high as a \(buildingFloorCount)-story building."
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
