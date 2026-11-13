//
//  LiveSceneNarration.swift
//  leanring-buddy
//
//  What Clicky says about a bundled page it put on screen, and the data it
//  trusts while saying it. A frame pop-out is narrated one part at a time.
//  The landmark page gets one line built from the /landmark reply. Generated
//  /live-scene pages are not covered.
//

import Foundation

/// The bundled page Clicky put on screen, with Clicky's own copy of its data.
/// Narration reads this, never what the page reports about itself.
enum LiveScenePageOnScreen {
    /// A page GPT wrote for /live-scene. It gets none of the bundled-page narration.
    case generatedPage
    case framePopout(VideoFramePopout)
    case landmark(FamousPlace)
}

/// Why Clicky is about to talk about a frame pop-out.
enum LiveSceneNarrationTrigger: Equatable {
    /// The camera tour of a pop-out with no quiz just ended.
    case afterTour
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

/// Kept apart from the companion prompt, which asks for [POINT:] tags that make no sense here.
let liveSceneNarrationSystemPrompt = """
you're clicky, a friendly guide talking out loud to a curious 11-year-old. something from the video they're watching just lifted out of the paused frame as a 3d model with labeled parts. the image is that paused frame. your words go to text to speech, so write the way you'd talk: short sentences, plain words, all lowercase, no lists, no markdown, no emojis, no abbreviations. make each sentence say one surprising or useful thing about that part. never tell them to click, scroll, or look anywhere else.
"""

func liveSceneNarrationUserPrompt(for narrationTrigger: LiveSceneNarrationTrigger, knownPartLabels: [String]) -> String {
    let partNamesLine = "the labeled parts are exactly: \(knownPartLabels.joined(separator: ", "))."
    switch narrationTrigger {
    case .afterTour:
        return """
        \(partNamesLine)
        say two or three short sentences, one per part, picking the parts an 11-year-old would find most interesting. start each sentence with [PART:name] using one of those exact names.
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
