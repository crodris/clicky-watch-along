//
//  SeekToMomentTests.swift
//  leanring-buddyTests
//
//  seek_to_moment seeks to the caption line that videoCaptionMomentsMatching ranks first, with no second look by the
//  model, so these tests pin which line wins on realistic captions, and when it is offered and what its chip says.
//  Most captions are lines of bench/fixtures/video-quiz-plan-sharks.json.
//

import Testing
@testable import Clicky

struct SeekToMomentTests {
    private let sharkCaptionLines = [
        VideoQuizTranscriptLine(seconds: 0, text: "What if I told you there's an animal that has been around longer than trees? Stick around, because today we're diving into sharks."),
        VideoQuizTranscriptLine(seconds: 48, text: "Unlike most fish, a shark's skeleton is not made of bone. It is made of cartilage, the same bendy material in your nose and ears."),
        VideoQuizTranscriptLine(seconds: 60, text: "Cartilage is lighter than bone, which helps a shark stay up in the water and turn quickly."),
        VideoQuizTranscriptLine(seconds: 72, text: "Most fish have a gas-filled swim bladder that helps them float, but sharks do not have one."),
        VideoQuizTranscriptLine(seconds: 84, text: "Instead, a shark has a huge liver filled with oil. Oil is lighter than water, so the liver works like a built-in float."),
        VideoQuizTranscriptLine(seconds: 96, text: "In some sharks the liver makes up a quarter of the whole body weight."),
        VideoQuizTranscriptLine(seconds: 144, text: "Some sharks, like the great white, have to swim forward to push water over their gills. This is called ram ventilation."),
        VideoQuizTranscriptLine(seconds: 180, text: "That's because the skin is covered in tiny tooth-like scales called dermal denticles."),
        VideoQuizTranscriptLine(seconds: 192, text: "The denticles make little swirls in the water that cut drag, so the shark slips through the water more easily."),
        VideoQuizTranscriptLine(seconds: 252, text: "Shark teeth are not fixed in the jaw like ours. They sit in rows, like a conveyor belt."),
    ]

    @Test func aDistinctiveQueryLandsOnTheLineThatSaysIt() {
        #expect(videoCaptionMomentsMatching(query: "swim bladder", captionLines: sharkCaptionLines).first?.seconds == 72)
        #expect(videoCaptionMomentsMatching(query: "ram ventilation", captionLines: sharkCaptionLines).first?.seconds == 144)
        #expect(videoCaptionMomentsMatching(query: "dermal denticles", captionLines: sharkCaptionLines).first?.seconds == 180)
        #expect(videoCaptionMomentsMatching(query: "conveyor belt", captionLines: sharkCaptionLines).first?.seconds == 252)
        // Two lines say "liver". The first also has the liver as the next line's topic, so it outweighs the second.
        #expect(videoCaptionMomentsMatching(query: "the liver", captionLines: sharkCaptionLines).first?.seconds == 84)
    }

    @Test func aQueryThatSaysMoreOfTheExplanationBeatsATeaserThatOnlyNamesTheTopic() {
        let teaserLine = VideoQuizTranscriptLine(seconds: 17, text: "today we look at how sharks float without a swim bladder")
        let explanationLine = VideoQuizTranscriptLine(seconds: 98, text: "so the swim bladder is the gas filled organ bony fish use to float")
        let laterMentionLine = VideoQuizTranscriptLine(seconds: 301, text: "sharks have no swim bladder at all so they rely on their oily liver")
        let query = "swim bladder gas filled organ"
        #expect(videoCaptionMomentsMatching(query: query, captionLines: [teaserLine, explanationLine, laterMentionLine]).first?.seconds == 98)
        // The teaser is the later line here, so the result does not come from line order.
        let teaserLater = VideoQuizTranscriptLine(seconds: 400, text: teaserLine.text)
        #expect(videoCaptionMomentsMatching(query: query, captionLines: [explanationLine, laterMentionLine, teaserLater]).first?.seconds == 98)
    }

    @Test func aSentenceSplitAcrossTwoCaptionLinesLandsOnTheLineWhereItStarts() {
        let captionLines = [
            VideoQuizTranscriptLine(seconds: 98, text: "so the swim bladder"),
            VideoQuizTranscriptLine(seconds: 101, text: "is a gas filled organ that fish use to float"),
        ]
        #expect(videoCaptionMomentsMatching(query: "swim bladder gas organ", captionLines: captionLines).first?.seconds == 98)
    }

    // Captions every few seconds, as YouTube writes them. The teaser and the explanation's first line each say "swim
    // bladder" with no help from the next line, so they tie on score. The explanation's neighbors keep saying "bladder",
    // and the teaser's talk about other things, so the explanation wins even though the teaser comes first.
    @Test func aTieGoesToTheMentionWhoseNearbyCaptionsKeepSayingTheQuery() {
        let captionLines = [
            VideoQuizTranscriptLine(seconds: 12, text: "today we find out how sharks float without a swim bladder"),
            VideoQuizTranscriptLine(seconds: 15, text: "but first let's meet the great white"),
            VideoQuizTranscriptLine(seconds: 19, text: "it can grow longer than a car"),
            VideoQuizTranscriptLine(seconds: 95, text: "most bony fish have a swim bladder"),
            VideoQuizTranscriptLine(seconds: 98, text: "it is a little sack of gas inside the fish"),
            VideoQuizTranscriptLine(seconds: 102, text: "the fish lets gas into the bladder to rise"),
            VideoQuizTranscriptLine(seconds: 106, text: "and lets gas out of the bladder to sink"),
        ]
        #expect(videoCaptionMomentsMatching(query: "swim bladder", captionLines: captionLines).first?.seconds == 95)
        // The same captions with the explanation first: the result comes from the nearby captions, not from line order.
        let explanationFirst = captionLines.suffix(4).map { VideoQuizTranscriptLine(seconds: $0.seconds - 90, text: $0.text) }
            + [VideoQuizTranscriptLine(seconds: 40, text: "now let's look at their teeth")]
            + captionLines.prefix(3).map { VideoQuizTranscriptLine(seconds: $0.seconds + 300, text: $0.text) }
        #expect(videoCaptionMomentsMatching(query: "swim bladder", captionLines: explanationFirst).first?.seconds == 5)
    }

    // Known limit: when the nearby captions tie too, the earliest line wins, which in an explainer video can be the teaser,
    // so seek_to_moment's description sends "the last time", "the second time", and "that was the wrong spot" to
    // find_moment, where the model sees every candidate.
    @Test func whenEveryMentionSaysTheQueryEquallyTheEarliestLineWins() {
        let captionLines = [
            VideoQuizTranscriptLine(seconds: 17, text: "today we look at how sharks float without a swim bladder"),
            VideoQuizTranscriptLine(seconds: 98, text: "so the swim bladder is the gas filled organ bony fish use to float"),
            VideoQuizTranscriptLine(seconds: 301, text: "sharks have no swim bladder at all so they rely on their oily liver"),
        ]
        #expect(videoCaptionMomentsMatching(query: "swim bladder", captionLines: captionLines).map(\.seconds) == [17, 98, 301])
    }

    @Test func aQueryNoLineSaysFindsNothingSoTheSeekFailsInsteadOfMoving() {
        #expect(videoCaptionMomentsMatching(query: "volcano eruption", captionLines: sharkCaptionLines).isEmpty)
        #expect(videoCaptionMomentsMatching(query: "", captionLines: sharkCaptionLines).isEmpty)
    }

    @Test func seekToMomentIsOfferedOnlyWhereCaptionSearchIs() {
        let youTubeVideo = AppVoiceTool.Context(sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: true, videoIsOnYouTube: true, videoQuizIsRunning: false, quizQuestionIsOpen: false)
        let videoOnVimeo = AppVoiceTool.Context(sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: true, videoIsOnYouTube: false, videoQuizIsRunning: false, quizQuestionIsOpen: false)
        let noVideo = AppVoiceTool.Context(sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: false, videoIsOnYouTube: false, videoQuizIsRunning: false, quizQuestionIsOpen: false)

        #expect(AppVoiceTool.available(in: youTubeVideo).contains(.seekToMoment))
        #expect(AppVoiceTool.available(in: youTubeVideo).contains(.findMoment), "a lookup stays for the last mention and for questions")
        #expect(!AppVoiceTool.available(in: videoOnVimeo).contains(.seekToMoment))
        #expect(!AppVoiceTool.available(in: noVideo).contains(.seekToMoment))
        // It moves the video, so it is an action. A lookup would send the model back for a second turn.
        #expect(AppVoiceTool.seekToMoment.descriptor.readOnly == false)
    }

    @Test func seekToMomentChipShowsOnlyAfterTheSeekWorked() {
        let seek = VoiceToolCall(id: "1", name: "seek_to_moment", input: ["query": .string("swim bladder")])
        #expect(seek.chipPhrase == "Jumping to \u{201C}swim bladder\u{201D}")
        #expect(seek.chipPhraseToShow(at: .beforeTheCall) == nil)
        #expect(seek.chipPhraseToShow(at: .afterTheCall(.changed(state: nil))) == "Jumping to \u{201C}swim bladder\u{201D}")
        #expect(seek.chipPhraseToShow(at: .afterTheCall(.failed(error: "No caption line says that.", state: nil))) == nil)
        #expect(seek.chipPhraseToShow(at: .afterTheCall(.changed(state: nil)), offeredToolNames: ["pause_video"]) == nil)
        #expect(VoiceToolCall(id: "2", name: "seek_to_moment", input: [:]).chipPhrase == nil)
    }

    @Test func aSeekToMomentFollowedByAPopOutNeedsNoSecondModelTurn() {
        let seek = VoiceToolCall(id: "1", name: "seek_to_moment", input: ["query": .string("swim bladder"), "confirmation": .string("going there")])
        let popOut = VoiceToolCall(id: "2", name: "pop_out", input: [:])
        #expect(voiceCommandNextStep(toolCalls: [seek], outcomes: [.changed(state: nil)], replyText: "") == .speak("going there"))
        #expect(voiceCommandNextStep(toolCalls: [seek, popOut], outcomes: [.changed(state: nil), .handedOff], replyText: "") == .finishSilently)
    }
}
