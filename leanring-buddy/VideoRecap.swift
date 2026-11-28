//
//  VideoRecap.swift
//  leanring-buddy
//
//  The end-of-video recap: when a video ends, the agent discs gather at the cursor and unfold into the quiz summary Card,
//  which then also says what the learner learned and links the study guide. This file is the plain data and the pure rules:
//  what the recap holds and where each line comes from, when a video counts as ended, and when the recap shows. The Card is
//  `VideoQuizSummaryCardView`, the gather is `AgentTokenDockController.gatherTheDiscs`, and `CompanionManager` runs the watch.
//

import CoreGraphics
import Foundation

// MARK: - What the recap holds

/// What the Card shows besides the quiz's misses: the lines under "What you learned" and the study guide to open.
/// Everything here comes from data Clicky already has, so the recap makes no model call.
nonisolated struct VideoRecap: Equatable, Sendable {
    /// The most lines under "What you learned", so the Card stays small.
    static let mostLearnedLines = 3
    /// A line is cut to this many characters, at a word, so one long explanation never fills the Card.
    static let longestLearnedLine = 140

    /// The score and the questions to go back to, or nil for a video with no finished quiz question.
    let summary: VideoQuizSummary?
    /// The study guide's summary first, then the explanation of each question the learner got right, in video order.
    let learnedLines: [String]
    /// The study guide's Notion page, when the video has a guide.
    let studyGuideURL: URL?

    /// Nil when there is nothing to recap: no finished quiz question and no study guide.
    /// - `quizResults`: the results of the quiz to sum up, which the Card's misses jump back to.
    /// - `studyGuideRecord`: the guide saved for the video, whose `summary` is the first learned line.
    init?(quizResults: [StudyGuideQuizResult], studyGuideRecord: StudyGuideRecord?) {
        let quizSummary = VideoQuizSummary(quizResults: quizResults)
        guard quizSummary != nil || studyGuideRecord != nil else { return nil }
        summary = quizSummary
        studyGuideURL = studyGuideRecord.flatMap { pageURLIsOnNotion($0.pageURL) ? $0.pageURL : nil }

        var lines: [String] = []
        if let guideSummary = studyGuideRecord?.guide["summary"]?.stringValue {
            lines.append(guideSummary)
        }
        let questionsGotRight = quizResults.filter { $0.result == .gotIt }
        let questionsGotRightInVideoOrder = questionsGotRight.sorted { $0.askedAtSeconds < $1.askedAtSeconds }
        lines += questionsGotRightInVideoOrder.map(\.explanation)
        var learnedLinesWithoutRepeats: [String] = []
        for line in lines {
            let shownLine = recapLine(line)
            guard !shownLine.isEmpty, !learnedLinesWithoutRepeats.contains(shownLine) else { continue }
            learnedLinesWithoutRepeats.append(shownLine)
        }
        learnedLines = Array(learnedLinesWithoutRepeats.prefix(Self.mostLearnedLines))
    }

    /// The Card's title: "Quiz done" when it sums up a quiz that just ended, "Video done" when the video itself ended.
    func title(when moment: VideoRecapMoment) -> String {
        switch moment {
        case .quizEnded: return summary == nil ? "Video done" : "Quiz done"
        case .videoEnded: return "Video done"
        }
    }

    /// The small line above the title: "Quiz recap" when the title is "Quiz done", and "Video recap" otherwise.
    func kicker(when moment: VideoRecapMoment) -> String {
        title(when: moment) == "Quiz done" ? "Quiz recap" : "Video recap"
    }
}

/// The colophon at the foot of the recap's paper, such as "Nov 28 · 9:42 AM", from the moment the Card was made. It says no verb,
/// since the recap is saved nowhere. The day and the time follow `locale` and `timeZone`, the learner's own by default. A newer
/// macOS puts a narrow no-break space before "AM", which a monospaced line would show as a gap, so it is a plain space here.
func videoRecapColophonText(madeAt date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    func formatted(_ template: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.setLocalizedDateFormatFromTemplate(template)
        return dateFormatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }
    return "\(formatted("MMMd")) · \(formatted("jmm"))"
}

/// Why the Card shows, which sets its title and where it comes from.
nonisolated enum VideoRecapMoment: Equatable, Sendable {
    /// The learner finished or stopped a quiz. The Card Glides out of the video, as the quiz summary always has.
    case quizEnded
    /// The video ended. The discs gather at the cursor and the Card Glides out of it.
    case videoEnded
}

/// One line of a recap: the text on one line, with runs of whitespace as single spaces, and cut at a word with an ellipsis
/// when it is over `VideoRecap.longestLearnedLine` characters.
nonisolated func recapLine(_ text: String) -> String {
    let words = text.split(whereSeparator: \.isWhitespace)
    let oneLine = words.joined(separator: " ")
    guard oneLine.count > VideoRecap.longestLearnedLine else { return oneLine }
    var cutLine = ""
    for word in words {
        let lineWithTheWord = cutLine.isEmpty ? String(word) : cutLine + " " + word
        // One character is kept for the ellipsis.
        if lineWithTheWord.count > VideoRecap.longestLearnedLine - 1 { break }
        cutLine = lineWithTheWord
    }
    if cutLine.isEmpty { cutLine = String(oneLine.prefix(VideoRecap.longestLearnedLine - 1)) }
    return cutLine + "…"
}

// MARK: - When a video has ended

/// What one read of Chrome's front tab says about its video.
nonisolated struct FrontVideoEndReading: Equatable, Sendable {
    /// The tab's page address, which names the video (`studyGuideVideoKey`).
    let pageURL: String
    /// The video element's own `ended` state: it played to its last moment and is not looping.
    let hasEnded: Bool

    /// The page script's reply, `"1|<url>"` for an ended video and `"0|<url>"` otherwise. Nil for a page with no video
    /// (`no-video`), no window, or anything else the script should not return, so a failed read counts as no reading.
    init?(scriptReply: String) {
        let parts = scriptReply.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "1" || parts[0] == "0", !parts[1].isEmpty else { return nil }
        hasEnded = parts[0] == "1"
        pageURL = String(parts[1])
    }

    /// The page's largest video, so a preview or a second player is never the one read.
    static let pageScript = "(function () { \(LearnerVideoCommand.mainVideoJavaScript) if (!video) { return 'no-video'; } return (video.ended ? '1' : '0') + '|' + location.href; })()"
}

/// How often the watch reads the front tab. A video ends once, so a few seconds late is fine.
let videoEndWatchSecondsBetweenReads: TimeInterval = 3

/// What the watch remembers between reads.
nonisolated struct VideoEndWatchState: Equatable, Sendable {
    /// The video whose ending already got its recap, until it plays again, so one ending shows one Card.
    var videoKeyOfTheHandledEnding: String?
}

nonisolated enum VideoEndWatchDecision: Equatable, Sendable {
    case wait
    /// The video named by this key (`studyGuideVideoKey`) has ended, and this ending has not had its recap yet.
    case showTheRecap(videoKey: String)
}

/// Decides, after one read of the front tab, whether a recap shows now.
/// - `reading`: nil when there is no video or the read failed.
/// - `videoKeysWithSomethingToRecap`: the videos the learner took a quiz on, or wrote a guide for, since launch.
nonisolated func videoEndWatchStep(
    reading: FrontVideoEndReading?,
    videoKeysWithSomethingToRecap: Set<String>,
    state: VideoEndWatchState
) -> (state: VideoEndWatchState, decision: VideoEndWatchDecision) {
    guard let reading else { return (state, .wait) }
    guard reading.hasEnded else {
        // A video that plays again, or seeks back, is watched for its next ending. Whether that ending shows a Card is
        // `videoRecapToShowAtTheEnd`'s rule: a recap the learner already saw shows nothing new.
        return (VideoEndWatchState(videoKeyOfTheHandledEnding: nil), .wait)
    }
    let videoKey = studyGuideVideoKey(forVideoURL: reading.pageURL)
    guard videoKeysWithSomethingToRecap.contains(videoKey), state.videoKeyOfTheHandledEnding != videoKey else {
        return (state, .wait)
    }
    return (VideoEndWatchState(videoKeyOfTheHandledEnding: videoKey), .showTheRecap(videoKey: videoKey))
}

/// How long the watch leaves Chrome alone after a read failed, such as a page with an alert, a `chrome://` page, or Chrome
/// refusing scripts, so a failing page costs one Apple Event every 30 seconds and not one every 3.
let videoEndWatchSecondsToWaitAfterAFailedRead: TimeInterval = 30

/// Whether the recap Card may unfold once the discs have gathered. The learner may have pressed push-to-talk, pressed Escape,
/// or started a scene during the half second the discs flew, or Clicky may be busy with something the Card would cover.
nonisolated func videoRecapCardMayShowAfterTheGather(gatherWasCancelled: Bool, clickyIsBusy: Bool) -> Bool {
    !gatherWasCancelled && !clickyIsBusy
}

/// What keeps the end-of-video recap Card back: anything Clicky is doing or showing that the Card would cover or interrupt.
/// Each fact is named, so a test can turn each one on alone and see the Card wait.
struct VideoRecapBusyFacts: Equatable {
    var aSceneIsUp = false
    /// Listening, thinking, or speaking.
    var clickyIsNotIdle = false
    var speechIsPlaying = false
    var aQuizQuestionIsOpen = false
    var aQuizIsRunning = false
    var aCardIsShowing = false
    var theThemeStudioIsOpen = false
    var theSettingsDialIsOpen = false
    var theAgentListIsOpen = false
    /// The menu bar panel holds the keyboard, and the Card would unfold over the learner's reading or typing.
    var theMenuBarPanelIsOpen = false
    var theRoomArtPanelIsOpen = false
    var anAddThemeCardIsOpen = false
    var anApprovalWaits = false

    var clickyIsBusy: Bool {
        aSceneIsUp || clickyIsNotIdle || speechIsPlaying || aQuizQuestionIsOpen || aQuizIsRunning || aCardIsShowing
            || theThemeStudioIsOpen || theSettingsDialIsOpen || theAgentListIsOpen || theMenuBarPanelIsOpen
            || theRoomArtPanelIsOpen || anAddThemeCardIsOpen || anApprovalWaits
    }
}

/// The discs a recap's gather hid, so they go back to the same places, and the display they were on. The dock asks it before
/// it shows a disc for any other reason, such as a "go ahead" flight that lands or the paused disc fading in after "hold on",
/// since a recap that starts within half a second of either would otherwise leave that disc showing beside the Card.
struct AgentTokenRecapGather: Equatable {
    struct GatheredDisc: Equatable {
        let discID: AgentTokenDiscID
        let overflowCount: Int
        /// The disc's center when it was gathered, where it goes back to when it has left its place since.
        let center: CGPoint
    }

    private(set) var gatheredDiscs: [GatheredDisc] = []
    private(set) var gatheredDisplayID: CGDirectDisplayID?

    mutating func gathered(_ discs: [GatheredDisc], onDisplay displayID: CGDirectDisplayID) {
        gatheredDiscs = discs
        gatheredDisplayID = discs.isEmpty ? nil : displayID
    }

    /// Whether the gather hides this disc, so nothing else may show it until the recap ends.
    func hides(_ discID: AgentTokenDiscID) -> Bool {
        gatheredDiscs.contains { $0.discID == discID }
    }

    /// Ends the gather and returns the discs to show again, once: a second call returns none. The dock ends it before any of
    /// the gather's flights lands, since a landing runs the recap's `onGathered`, and the send back that a cancelled gather
    /// then asks for must find nothing left to fly.
    mutating func end() -> (discs: [GatheredDisc], displayID: CGDirectDisplayID?) {
        let ended = (discs: gatheredDiscs, displayID: gatheredDisplayID)
        gatheredDiscs = []
        gatheredDisplayID = nil
        return ended
    }
}

/// Whether the discs a recap gathered must show again while its Card is open. They must when an agent waits for the learner's
/// OK, since the "!" badge on a hidden disc would hide the request, and when a disc appeared on the gathered display since, since
/// it would sit beside empty slots. A disc on another display, or one that was gathered, changes nothing.
func gatheredDiscsMustShowAgain(
    gatheredDiscIDs: Set<AgentTokenDiscID>,
    gatheredDisplayID: CGDirectDisplayID?,
    discIDsOnScreen: Set<AgentTokenDiscID>,
    anAgentWaitsForApproval: Bool
) -> Bool {
    guard !gatheredDiscIDs.isEmpty else { return false }
    if anAgentWaitsForApproval { return true }
    return discIDsOnScreen.contains { $0.displayID == gatheredDisplayID && !gatheredDiscIDs.contains($0) }
}

/// The recap to show at a video's end, or nil when there is none or the learner already saw this very one, such as the
/// Card the end of its quiz showed. A recap that changed since, by a guide written or another quiz taken, shows again.
nonisolated func videoRecapToShowAtTheEnd(recap: VideoRecap?, lastShownRecap: VideoRecap?) -> VideoRecap? {
    guard let recap, recap != lastShownRecap else { return nil }
    return recap
}
