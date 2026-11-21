//
//  VoiceCommandScreenRead.swift
//  leanring-buddy
//
//  What a voice command reads from the screen before it asks the model: the video in Chrome's front tab, the page's tools
//  and state, and whether the front video has a study guide. None of it needs the learner's words, so it is read when
//  push-to-talk is released, during the microphone's tail and the transcript's finalization, and the transcript of that
//  same press uses it.
//

import Foundation

/// What the page and the study guide check answered, and when the last of them finished.
struct VoiceCommandPageRead {
    let pageTools: [VoiceToolDescriptor]
    let pageState: JSONValue?
    let studyGuideExistsForTheFrontVideo: Bool
    let finishedAt: Date
}

/// The read of one push-to-talk press, started at its release. The front video state is in hand when this exists, since it
/// is read in one step on the main actor, and the page reads may still run.
struct VoiceCommandScreenRead {
    /// The press this read was started for. Only the transcript of that press may use it.
    let pressCount: Int
    let frontVideoState: JSONValue?
    let pageRead: Task<VoiceCommandPageRead, Never>
}

/// The read a transcript may use: the one started at the release of its own press. A read from an older press, or none, is nil,
/// so a command never acts on a screen read before its own press was released.
func screenReadForTheTranscript(of pressCount: Int, from screenRead: VoiceCommandScreenRead?) -> VoiceCommandScreenRead? {
    guard let screenRead, screenRead.pressCount == pressCount else { return nil }
    return screenRead
}
