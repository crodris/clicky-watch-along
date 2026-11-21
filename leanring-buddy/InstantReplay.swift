//
//  InstantReplay.swift
//  leanring-buddy
//
//  Instant replay of a narrated frame pop-out. As Clicky names each part, the narration records a stop: the part's
//  label, the sentence, and the camera pose. "Show me again" or the Replay button plays the stops again, silently:
//  the camera turns back to each recorded pose, the blue cursor flies to the part's label, and its bubble shows the
//  sentence. Next, Back, and End step through it by voice or click. One generation number cancels every pending
//  step, so Escape, a step, push-to-talk, or a new scene stops the camera and the cursor where they are.
//

import AppKit
import Combine
import Foundation

/// The camera pose a narration saw at one stop, in the pop-out page's own units: yaw and pitch in radians,
/// distance in world units. The page reports it with `cameraPose()` and restores it with `focusStop`.
nonisolated struct ReplayCameraPose: Equatable, Sendable {
    let yaw: Double
    let pitch: Double
    let distance: Double

    init(yaw: Double, pitch: Double, distance: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
    }

    /// Nil unless the page sent three finite numbers. WebKit types a page result as Any.
    init?(pageValue: Any?) {
        // A JavaScript true bridges to an NSNumber too, so a boolean is refused by its type.
        func number(_ fieldValue: Any?) -> Double? {
            guard let fieldNumber = fieldValue as? NSNumber, CFGetTypeID(fieldNumber) != CFBooleanGetTypeID() else { return nil }
            return fieldNumber.doubleValue
        }
        guard let poseFields = pageValue as? [String: Any],
              let yaw = number(poseFields["yaw"]),
              let pitch = number(poseFields["pitch"]),
              let distance = number(poseFields["distance"]),
              yaw.isFinite, pitch.isFinite, distance.isFinite, distance > 0 else {
            return nil
        }
        self.init(yaw: yaw, pitch: pitch, distance: distance)
    }

    var pageValue: [String: Double] {
        ["yaw": yaw, "pitch": pitch, "distance": distance]
    }
}

/// One pointing stop of a narration: the part Clicky named, from Clicky's own parts list, what it said there, and
/// the camera pose then. A pose the page could not report is nil, and the stop then only pans to the part.
nonisolated struct ReplayStop: Equatable, Sendable {
    let partLabel: String
    var sentence: String
    let cameraPose: ReplayCameraPose?
}

/// Adds a stop the narration just pointed at. A sentence about a part that already has a stop joins that stop, wherever
/// it is in the list, since two stops on one label would put two numbers on top of each other.
nonisolated func replayStops(_ recordedStops: [ReplayStop], adding newStop: ReplayStop) -> [ReplayStop] {
    var stops = recordedStops
    if let stopIndexOfThePart = stops.firstIndex(where: { stop in stop.partLabel == newStop.partLabel }) {
        stops[stopIndexOfThePart].sentence += " " + newStop.sentence
        return stops
    }
    stops.append(newStop)
    return stops
}

/// Where a replay is. A play-through moves on by itself after each stop's dwell, and a step stops it at its stop.
nonisolated enum InstantReplayPhase: Equatable, Sendable {
    case notOpen
    case playingThrough(stopIndex: Int)
    case stoppedAt(stopIndex: Int)

    var openStopIndex: Int? {
        switch self {
        case .notOpen: return nil
        case .playingThrough(let stopIndex), .stoppedAt(let stopIndex): return stopIndex
        }
    }

    var isOpen: Bool { openStopIndex != nil }

    /// Next and Back stop at the stop they reach, clamped to the first and last, and End closes the replay.
    /// With no replay open, Next and Back open it at the first stop.
    func afterStep(_ replayStep: InstantReplayStep, stopCount: Int) -> InstantReplayPhase {
        guard stopCount > 0 else { return .notOpen }
        let lastStopIndex = stopCount - 1
        switch replayStep {
        case .end:
            return .notOpen
        case .next:
            guard let openStopIndex else { return .stoppedAt(stopIndex: 0) }
            return .stoppedAt(stopIndex: min(lastStopIndex, openStopIndex + 1))
        case .back:
            guard let openStopIndex else { return .stoppedAt(stopIndex: 0) }
            return .stoppedAt(stopIndex: max(0, openStopIndex - 1))
        }
    }

    /// A play-through moves to the next stop, and ends after the last one, so "back" and "stop" mean the video and the
    /// scene again and the cursor goes back to the mouse.
    func afterTheStopDwelt(stopCount: Int) -> InstantReplayPhase {
        guard case .playingThrough(let stopIndex) = self else { return self }
        return stopIndex + 1 < stopCount ? .playingThrough(stopIndex: stopIndex + 1) : .notOpen
    }

    /// Push-to-talk keeps the replay open at the stop it reached, so "next" and "back" still work after it.
    var afterTheTravelStopped: InstantReplayPhase {
        guard let openStopIndex else { return .notOpen }
        return .stoppedAt(stopIndex: openStopIndex)
    }
}

/// What the router's replay_step tool and the control's buttons ask for.
nonisolated enum InstantReplayStep: String, CaseIterable, Equatable, Sendable {
    case next
    case back
    case end
}

/// How long the bubble holds a stop's sentence before a play-through moves on: the larger of 1.5 seconds and
/// 0.3 seconds a word, so a 15 word sentence holds 4.5 seconds.
nonisolated func replayStopDwellSeconds(for sentence: String) -> Double {
    let wordCount = sentence.split(whereSeparator: \.isWhitespace).count
    return max(1.5, 0.3 * Double(wordCount))
}

/// The count the control shows: "3 stops" before a replay, "2 of 3" during one.
nonisolated func instantReplayCountText(phase: InstantReplayPhase, stopCount: Int) -> String {
    guard let openStopIndex = phase.openStopIndex else {
        return stopCount == 1 ? "1 stop" : "\(stopCount) stops"
    }
    return "\(openStopIndex + 1) of \(stopCount)"
}

/// "Show me again" and its close forms, as the whole utterance, so "show me again how the gears turn" stays a question
/// for the router. "Do that again" and "play it again" are left to the router, since they also mean repeat the last
/// command or play the video. It runs ahead of the router only while a narration recorded stops, so it never builds a paid scene.
nonisolated func asksToReplayTheExplanation(_ transcript: String) -> Bool {
    let words = transcript.lowercased()
        .replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
        .split(separator: " ")
        .map(String.init)
    let wordsBeforeTheRequest: Set<String> = ["hey", "clicky", "okay", "ok", "please", "can", "you", "could"]
    let wordsAfterTheRequest: Set<String> = ["please", "clicky"]
    var requestWords = Array(words.drop { word in wordsBeforeTheRequest.contains(word) })
    while let lastWord = requestWords.last, wordsAfterTheRequest.contains(lastWord) {
        requestWords.removeLast()
    }
    let replayRequests: Set<String> = [
        "show me again", "show me that again", "show it again", "show that again", "show me it again",
        "replay", "replay it", "replay that", "replay the explanation",
    ]
    return replayRequests.contains(requestWords.joined(separator: " "))
}

/// Where the replay control's window sits, in AppKit points. Its Card shows centered 14 points under the paused video, or
/// 14 points inside the video's bottom edge when the screen has no room below it, and stays 8 points inside the screen's
/// visible frame. The window is `shadowMargin` larger than the Card on every side, so the Card's shadow is not clipped.
nonisolated func instantReplayControlOrigin(windowSize: CGSize, shadowMargin: CGFloat, mediaRectOnScreen: CGRect, visibleFrame: CGRect) -> CGPoint {
    let gapFromTheMedia: CGFloat = 14
    let screenEdgeGap: CGFloat = 8
    var originX = mediaRectOnScreen.midX - windowSize.width / 2
    // AppKit's y grows up, so "under the media" is below its minY, and the Card's top is the window's top minus the margin.
    var originY = mediaRectOnScreen.minY - gapFromTheMedia - windowSize.height + shadowMargin
    if originY + shadowMargin < visibleFrame.minY + screenEdgeGap {
        originY = mediaRectOnScreen.minY + gapFromTheMedia - shadowMargin
    }
    let lowestOriginX = visibleFrame.minX + screenEdgeGap - shadowMargin
    let highestOriginX = visibleFrame.maxX - screenEdgeGap + shadowMargin - windowSize.width
    let lowestOriginY = visibleFrame.minY + screenEdgeGap - shadowMargin
    let highestOriginY = visibleFrame.maxY - screenEdgeGap + shadowMargin - windowSize.height
    originX = min(max(originX, lowestOriginX), highestOriginX)
    originY = min(max(originY, lowestOriginY), highestOriginY)
    return CGPoint(x: originX, y: originY)
}

/// Whether "show me again" runs ahead of the router: only while the narration recorded stops for the scene on screen, no
/// quiz question is open, and the Theme Studio card, which holds every spoken word, is closed.
func replayPhraseRunsAheadOfTheRouter(asksToReplay: Bool, stopsAreRecorded: Bool, quizQuestionIsOpen: Bool, themeStudioIsOpen: Bool) -> Bool {
    asksToReplay && stopsAreRecorded && !quizQuestionIsOpen && !themeStudioIsOpen
}

/// A replay stops or releases only the cursor it pointed itself, so a cursor pointing for an answer keeps its own fly-back.
func cursorPointsForTheReplay(pointingHold: BuddyPointingHold, replayPointingID: UUID) -> Bool {
    pointingHold == .untilReleased(byNarrationID: replayPointingID)
}

/// What the voice router's scene state says about the replay, so "next" and "back" read as steps while one is open.
nonisolated func voiceCommandReplayState(phase: InstantReplayPhase, stopCount: Int) -> JSONValue {
    var replayFields: [String: JSONValue] = ["stops": .number(Double(stopCount)), "open": .bool(phase.isOpen)]
    if let openStopIndex = phase.openStopIndex {
        replayFields["atStop"] = .number(Double(openStopIndex + 1))
    }
    return .object(replayFields)
}

/// What the replay does to the screen. CompanionManager fills it in with the pop-out page and the blue cursor, and tests
/// with fakes that record each call.
@MainActor
struct InstantReplayStage {
    /// Turns the camera back to the stop's part and recorded pose with the page's own ease.
    var focusStop: (ReplayStop) -> Void
    /// Stops the camera where it is on this frame.
    var endFocus: () -> Void
    /// Numbers each stop's label, and draws the dotted path up to the stop at `pathReachesStop` (from 0, -1 for none).
    var showStopNumbers: (_ partLabels: [String], _ pathReachesStop: Int) -> Void
    var hideStopNumbers: () -> Void
    /// Where the part's label sits once the camera has stopped turning, or nil when it is gone.
    var labelScreenPointOnceTheCameraSettles: (_ partLabel: String) async -> LiveScenePartScreenPoint?
    /// Flies the blue cursor to the label and shows the sentence in its bubble, until the replay lets it go.
    var pointTheCursor: (_ labelScreenPoint: LiveScenePartScreenPoint, _ sentence: String) -> Void
    /// Stops the cursor where it is, mid-flight included, and hides its bubble, only while it points for the replay.
    var freezeTheCursor: () -> Void
    /// Sends the cursor back to the mouse, only while it points for the replay.
    var releaseTheCursor: () -> Void
    /// Clears the focused part, as a narration does when it ends, so the other labels light up again.
    var clearTheFocus: () -> Void
    var reduceMotionIsOn: () -> Bool
    /// Throws when the replay's task is cancelled.
    var sleep: (_ seconds: Double) async throws -> Void
    /// Shows the control. Its number is `controlVersion` when the show was asked for, and a show that finishes after a later
    /// hide checks `controlShowIsStillWanted` and draws nothing.
    var showControl: (_ controlVersion: Int) -> Void
    var hideControl: () -> Void
}

/// Runs the replay. Every way a replay changes course (a step, End, Escape, push-to-talk, a new Replay, a narration
/// starting, a new scene) first bumps `travelGeneration` and cancels the travel task, so no pending step of the old
/// travel moves the camera or the cursor. Every show and hide of the control bumps `controlVersion` the same way, so a
/// show that waits on the page cannot draw the control after a later hide.
@MainActor
final class InstantReplayController: ObservableObject {
    /// The stops of the latest narration on the scene numbered `recordedSceneNumber`.
    @Published private(set) var stops: [ReplayStop] = []
    @Published private(set) var phase: InstantReplayPhase = .notOpen
    /// Read once when a replay opens, so the control's list form and the travel agree for the whole replay.
    @Published private(set) var showsTheReduceMotionList = false
    private(set) var recordedSceneNumber: Int?
    private var travelGeneration = 0
    /// Counts narrations, so only the newest one may offer its stops: a narration a tap cancelled can unwind after the
    /// next one started.
    private var narrationGeneration = 0
    private var controlVersion = 0
    private var travelTask: Task<Void, Never>?
    private let stage: InstantReplayStage

    init(stage: InstantReplayStage) {
        self.stage = stage
    }

    var isOpen: Bool { phase.isOpen }

    func stopsAreRecorded(forSceneNumber sceneNumber: Int) -> Bool {
        !stops.isEmpty && recordedSceneNumber == sceneNumber
    }

    /// A narration is about to move the camera and point the cursor, so an open replay ends and the control hides. The
    /// stops stay, so a narration that records none, such as a failed or cut-off one, leaves the last explanation to replay.
    /// Returns the narration's number, which `narrationEnded` checks.
    func narrationStarted() -> Int {
        narrationGeneration += 1
        if isOpen { endTheReplay(freezing: false) }
        hideTheControl()
        return narrationGeneration
    }

    /// Only the newest narration offers its stops, and only while its scene is still on screen. One that recorded none
    /// shows the control again for the stops before it.
    func narrationEnded(narrationNumber: Int, recordedStops: [ReplayStop], sceneNumber: Int, sceneIsStillOnScreen: Bool) {
        guard narrationNumber == narrationGeneration, sceneIsStillOnScreen else { return }
        if !recordedStops.isEmpty {
            offer(recordedStops, sceneNumber: sceneNumber)
        } else if stopsAreRecorded(forSceneNumber: sceneNumber) {
            showTheControl()
        }
    }

    /// A narration's stops replace the stops before them, so "show me again" plays the latest explanation.
    func offer(_ recordedStops: [ReplayStop], sceneNumber: Int) {
        guard !recordedStops.isEmpty else { return }
        if isOpen { endTheReplay(freezing: false) }
        stops = recordedStops
        recordedSceneNumber = sceneNumber
        showTheControl()
        print("Instant replay: recorded \(recordedStops.count) stops")
    }

    /// The Replay button and "show me again". A replay already open starts over from the first stop.
    func playFromTheStart() {
        guard !stops.isEmpty else { return }
        cancelTheTravel()
        showsTheReduceMotionList = stage.reduceMotionIsOn()
        if showsTheReduceMotionList {
            // Reduce Motion shows every stop at once, with the list of sentences under the media, and nothing plays on by itself.
            phase = .stoppedAt(stopIndex: 0)
            stage.showStopNumbers(stops.map(\.partLabel), stops.count - 1)
        } else {
            phase = .playingThrough(stopIndex: 0)
        }
        print("Instant replay: playing \(stops.count) stops\(showsTheReduceMotionList ? " as a list" : "")")
        travelToTheOpenStop()
    }

    /// Next, Back, and End, from the router's replay_step or the control's buttons.
    func step(_ replayStep: InstantReplayStep) {
        guard !stops.isEmpty else { return }
        if replayStep == .end {
            endIfOpen()
            return
        }
        if !isOpen { showsTheReduceMotionList = stage.reduceMotionIsOn() }
        let nextPhase = phase.afterStep(replayStep, stopCount: stops.count)
        // Back at the first stop or Next at the last changes nothing, so a cursor at rest stays at rest.
        guard nextPhase != phase else { return }
        cancelTheTravel()
        phase = nextPhase
        travelToTheOpenStop()
    }

    /// A click on a stop's number, or on a stop's label during a replay. False when the label is no stop's.
    @discardableResult
    func goToStop(index stopIndex: Int) -> Bool {
        guard stops.indices.contains(stopIndex) else { return false }
        if !isOpen { showsTheReduceMotionList = stage.reduceMotionIsOn() }
        cancelTheTravel()
        phase = .stoppedAt(stopIndex: stopIndex)
        travelToTheOpenStop()
        return true
    }

    @discardableResult
    func goToStop(partLabel: String) -> Bool {
        guard isOpen, let stopIndex = stops.firstIndex(where: { stop in stop.partLabel == partLabel }) else { return false }
        return goToStop(index: stopIndex)
    }

    /// Escape, and a new explanation, end an open replay first, and leave the pop-out on screen with the camera and the
    /// cursor where they stopped. False when no replay was open, so Escape goes on to the scene.
    @discardableResult
    func endIfOpen() -> Bool {
        guard isOpen else { return false }
        endTheReplay(freezing: true)
        return true
    }

    /// A push-to-talk press stops the travel and the camera where they are and keeps the replay open at its stop, so the
    /// learner can say "next" or "back". The press itself sends the cursor back to the mouse, where the ring listens.
    func stopTheTravelForAPress() {
        guard isOpen else { return }
        cancelTheTravel()
        stage.endFocus()
        phase = phase.afterTheTravelStopped
        print("Instant replay: push-to-talk stopped the travel at stop \((phase.openStopIndex ?? 0) + 1)")
    }

    /// The scene left the screen, so its stops mean nothing anymore.
    func forget() {
        if isOpen { stage.hideStopNumbers() }
        cancelTheTravel()
        phase = .notOpen
        stops = []
        recordedSceneNumber = nil
        hideTheControl()
    }

    /// False once the control was hidden or shown again after the show with this number was asked for.
    func controlShowIsStillWanted(controlVersion versionOfTheShow: Int) -> Bool {
        versionOfTheShow == controlVersion
    }

    private func showTheControl() {
        controlVersion += 1
        stage.showControl(controlVersion)
    }

    private func hideTheControl() {
        controlVersion += 1
        stage.hideControl()
    }

    private func endTheReplay(freezing: Bool) {
        cancelTheTravel(freezingTheCursor: false)
        if freezing {
            stage.endFocus()
            stage.freezeTheCursor()
        }
        stage.hideStopNumbers()
        phase = .notOpen
        showsTheReduceMotionList = false
        print("Instant replay: ended")
    }

    private func cancelTheTravel(freezingTheCursor: Bool = true) {
        travelGeneration += 1
        travelTask?.cancel()
        travelTask = nil
        // A cursor still flying to the old stop stops where it is, before the camera turns to the new one.
        // With no replay open there is no travel, and the cursor is not the replay's.
        if freezingTheCursor && isOpen { stage.freezeTheCursor() }
    }

    /// Turns the camera to the open stop, waits for it to settle, flies the cursor to the label, and in a play-through
    /// holds the sentence for its dwell and moves on. Every wait checks the generation it started with.
    private func travelToTheOpenStop() {
        guard let stopIndex = phase.openStopIndex, stops.indices.contains(stopIndex) else { return }
        let generationOfThisTravel = travelGeneration
        let stop = stops[stopIndex]
        if !showsTheReduceMotionList {
            stage.showStopNumbers(stops.map(\.partLabel), stopIndex)
        }
        stage.focusStop(stop)
        travelTask = Task { [weak self] in
            guard let self else { return }
            let labelScreenPoint = await self.stage.labelScreenPointOnceTheCameraSettles(stop.partLabel)
            guard !Task.isCancelled, generationOfThisTravel == self.travelGeneration else { return }
            if let labelScreenPoint {
                self.stage.pointTheCursor(labelScreenPoint, stop.sentence)
            }
            guard case .playingThrough = self.phase else { return }
            // About 0.9 seconds of flight, then the dwell that lets the sentence be read.
            do {
                try await self.stage.sleep(0.9 + replayStopDwellSeconds(for: stop.sentence))
            } catch {
                return
            }
            guard !Task.isCancelled, generationOfThisTravel == self.travelGeneration else { return }
            let phaseAfterTheDwell = self.phase.afterTheStopDwelt(stopCount: self.stops.count)
            guard phaseAfterTheDwell != self.phase else { return }
            if case .playingThrough = phaseAfterTheDwell {
                self.phase = phaseAfterTheDwell
                self.travelToTheOpenStop()
            } else {
                // The camera has settled on the last stop, so the replay ends there and the cursor goes back to the mouse.
                self.endTheReplay(freezing: false)
                self.stage.releaseTheCursor()
                self.stage.clearTheFocus()
                print("Instant replay: played every stop")
            }
        }
    }
}
