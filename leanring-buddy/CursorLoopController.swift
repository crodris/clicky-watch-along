//
//  CursorLoopController.swift
//  leanring-buddy
//
//  Runs the loop around the media Clicky is looking at. It reads the front tab's media rect when
//  push-to-talk is released, feeds `CursorLoopState` the events that draw and clear the loop, and while a
//  loop shows it samples the front tab as the loop starts and once a second after, and clears the loop when anything differs.
//  It also hears when background agents start and end, so the agents that work on the video in front lap sparks around the
//  same media, and the same poll watches the agents' line when no request's loop around the media shows.
//

import AppKit
import Combine
import Foundation

@MainActor
final class CursorLoopController: ObservableObject {
    @Published private(set) var state = CursorLoopState()

    private var mediaRectReadTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?
    private var agentLineFadeOutTask: Task<Void, Never>?
    /// One task for each finished agent whose spark is completing its last lap, which removes the agent when the lap is over.
    private var finishingLapTasks: [UUID: Task<Void, Never>] = [:]
    private var appActivationObserver: NSObjectProtocol?
    private var idleMustHoldTask: Task<Void, Never>?
    private var latestVoiceState = CompanionVoiceState.idle
    /// Read Chrome's front tab: the full media read at release, and the cheap sample the poll takes. Tests pass
    /// their own, since the real ones drive Chrome. The release's front tab read is shared with the voice command's screen
    /// read, so the media read asks it for the tab instead of reading the tab itself.
    private let readTheMediaInTheFrontTab: (FrontTabReadAtRelease) -> MediaOnTheFrontTab?
    private let readTheFrontTabSample: () -> FrontTabSample?
    /// The wait between front tab samples. Tests pass one that counts its calls, or one that suspends until the poll is
    /// cancelled, so no test reads the clock of a busy machine.
    private let waitBetweenFrontTabPolls: () async -> Void
    /// The wait for a finished agent's spark to complete its last lap. Tests pass one that returns at once.
    private let waitForAFinishingSparkLap: () async -> Void
    /// The wait an idle must outlast to end a loop. Tests pass one that returns at once, so the voice state it reads afterwards
    /// is the one the test set, with no clock of a busy machine in between.
    private let waitForAnIdleToHold: () async -> Void
    /// Whether an agent's spark may join the line and draw now: false while a scene covers the media, a quiz question is open, or
    /// Show Clicky is off (`agentSparksMayDraw(clickyCursorIsEnabled:aSceneIsOnScreen:aQuizQuestionIsOpen:theRoomArtPanelIsOpen:)`). `CompanionManager`
    /// sets it, since the controller does not know those states. It is read when an agent starts, when a release reads the
    /// media, and each time the line is drawn, so a line that is already showing hides at the next redraw of the overlay after
    /// it turns false, and an agent held back joins at the first release that allows it. Until it is set, no spark draws.
    var agentSparksMayDraw: () -> Bool = { false }
    /// Where the front app changing is heard. A test passes its own center, since a real app switch on a busy machine would
    /// otherwise end the loop a test is checking.
    private let appActivationNotificationCenter: NotificationCenter

    static let secondsBetweenFrontTabPolls: TimeInterval = 1
    /// The real wait between front tab polls. A cancelled poll ends its sleep early and then sees that it was cancelled.
    static func sleepBetweenFrontTabPolls() async {
        try? await Task.sleep(for: .seconds(secondsBetweenFrontTabPolls))
    }
    /// The voice state goes idle for a moment after a request is submitted, when the dictation session finishes
    /// and before the request sets its own processing state, so an idle ends a loop only after it holds this long.
    static let secondsAnIdleMustHoldToEndTheLoop: TimeInterval = 0.3
    /// The real wait an idle must outlast. A newer voice state cancels it early.
    static func sleepForAnIdleToHold() async {
        try? await Task.sleep(for: .seconds(secondsAnIdleMustHoldToEndTheLoop))
    }
    private static let chromeBundleIdentifier = "com.google.Chrome"
    /// The real wait for a finishing lap, as long as the spark takes to run it.
    static func sleepForAFinishingSparkLap() async {
        try? await Task.sleep(for: .seconds(AgentSparkTimeline.secondsAFinishingLapTakes))
    }

    init(
        readTheMediaInTheFrontTab: @escaping (FrontTabReadAtRelease) -> MediaOnTheFrontTab? = CursorLoopController.readTheMediaInTheFrontTab,
        readTheFrontTabSample: @escaping () -> FrontTabSample? = CursorLoopController.readTheFrontTabSample,
        waitBetweenFrontTabPolls: @escaping () async -> Void = CursorLoopController.sleepBetweenFrontTabPolls,
        waitForAFinishingSparkLap: @escaping () async -> Void = CursorLoopController.sleepForAFinishingSparkLap,
        waitForAnIdleToHold: @escaping () async -> Void = CursorLoopController.sleepForAnIdleToHold,
        appActivationNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.readTheMediaInTheFrontTab = readTheMediaInTheFrontTab
        self.readTheFrontTabSample = readTheFrontTabSample
        self.waitBetweenFrontTabPolls = waitBetweenFrontTabPolls
        self.waitForAFinishingSparkLap = waitForAFinishingSparkLap
        self.waitForAnIdleToHold = waitForAnIdleToHold
        self.appActivationNotificationCenter = appActivationNotificationCenter
        // The front app changing is a system event, so a notification is the only way to hear it.
        appActivationObserver = appActivationNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activatedApplication?.bundleIdentifier != Self.chromeBundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, self.state.loopIsShowing || self.state.agentLineIsShowing || self.state.turn != .notWaitingForALoop else { return }
                print("Cursor loop: the front app became \(activatedApplication?.bundleIdentifier ?? "unknown")")
                self.end(because: .appSwitched)
            }
        }
    }

    deinit {
        if let appActivationObserver {
            appActivationNotificationCenter.removeObserver(appActivationObserver)
        }
    }

    var isShowingTheLoop: Bool { state.loopIsShowing }

    /// The buddy that is away drawing the loop, from its flight to the line's start until it is back at the mouse: its screen,
    /// and the token its draw was given. The loop draws only on the screen that holds the media, and the mouse may be on another,
    /// so every other screen hides its buddy meanwhile, the way a pointing on another display hides it.
    struct BuddyAwayForTheLoop: Equatable {
        let screenFrame: CGRect
        let token: UUID
    }
    @Published private(set) var buddyAwayForTheLoop: BuddyAwayForTheLoop?

    var screenFrameWhereTheBuddyDrawsTheLoop: CGRect? { buddyAwayForTheLoop?.screenFrame }

    /// Returns the token that ends this draw. A newer draw replaces an older one.
    func theBuddyStartedDrawingTheLoop(onScreenWithFrame screenFrame: CGRect) -> UUID {
        let token = UUID()
        buddyAwayForTheLoop = BuddyAwayForTheLoop(screenFrame: screenFrame, token: token)
        return token
    }

    /// Only the draw with this token ends, so an old overlay's late close never ends a newer draw, and a display whose frame
    /// changed mid-draw still ends its own.
    func theBuddyFinishedDrawingTheLoop(token: UUID) {
        guard buddyAwayForTheLoop?.token == token else { return }
        buddyAwayForTheLoop = nil
    }

    /// Whether the loop shows on the screen with this frame. The cursor's cue asks per screen, since the loop's shimmer
    /// lights the thinking only where the loop is, and the screen under the cursor needs the dots when it has none.
    func isShowingTheLoop(onScreenWithFrame screenFrame: CGRect) -> Bool {
        state.loopIsShowing && loopToDraw(onScreenWithFrame: screenFrame) != nil
    }

    // MARK: - Events

    func pushToTalkWasPressed() {
        mediaRectReadTask?.cancel()
        end(because: .newPushToTalk)
    }

    /// Starts the rect read beside the router call. It is wasted unless the request becomes a look at the media. The front
    /// tab comes from `frontTabRead`, which the voice command's screen read of the same release shares.
    func pushToTalkWasReleased(frontTabRead sharedFrontTabRead: FrontTabReadAtRelease? = nil) {
        // A release with no one to share with reads the tab for the loop alone.
        let frontTabRead = sharedFrontTabRead ?? FrontTabReadAtRelease()
        change { $0.pushToTalkWasReleased() }
        mediaRectReadTask?.cancel()
        mediaRectReadTask = Task {
            let readStartedAt = Self.now
            let media = readTheMediaInTheFrontTab(frontTabRead)
            print("Cursor loop: read the front tab's media in \(Int((Self.now - readStartedAt) * 1000)) ms, \(media == nil ? "none to frame" : "found")")
            guard !Task.isCancelled else { return }
            change { $0.mediaRectArrived(media, at: Self.now, agentsMayJoinTheLine: agentSparksMayDraw()) }
        }
    }

    /// The request became a look at the media on screen. The caller skips this while a scene already covers it.
    func requestBecameALookAtTheMedia() {
        print("Cursor loop: the request became a look at the media, turn is \(state.turn == .notWaitingForALoop ? "not waiting for a loop" : "waiting")")
        change { $0.requestBecameALookAtTheMedia(at: Self.now) }
    }

    /// The request became a look at a region the learner circled while holding push-to-talk, which the Theme Studio reads
    /// as its picture. The loop goes around the learner's own line, at once, since the region was in hand at the release.
    func requestBecameALookAtTheCircledRegion(_ circledRegion: CircledRegion) {
        mediaRectReadTask?.cancel()
        print("Cursor loop: the request became a look at the region the learner circled")
        change { $0.requestBecameALookAtTheCircledRegion(circledRegion, at: Self.now) }
    }

    func aStatusLabelStartedShowing() {
        change { $0.aStatusLabelStartedShowing(at: Self.now) }
    }

    /// Clicky's voice state or its status label changed, which can end the loop. Going idle covers a cancel and a
    /// failure, but only an idle that holds counts.
    func voiceStateChanged(to voiceState: CompanionVoiceState, aStatusLabelIsShowing: Bool) {
        latestVoiceState = voiceState
        if aStatusLabelIsShowing {
            aStatusLabelStartedShowing()
        }
        guard let endReason = cursorLoopEndReason(forVoiceState: voiceState, aStatusLabelIsShowing: aStatusLabelIsShowing) else { return }
        guard endReason == .thinkingStopped else {
            end(because: endReason)
            return
        }
        idleMustHoldTask?.cancel()
        idleMustHoldTask = Task {
            await waitForAnIdleToHold()
            // A request that has not handed off yet may sit idle for its whole router call, so only a loop that
            // is showing ends here. A cancelled request never hands off, and the next press ends its turn.
            guard !Task.isCancelled, latestVoiceState == .idle, state.loopIsShowing else { return }
            end(because: .thinkingStopped)
        }
    }

    // MARK: - Agent sparks

    /// A background agent started. Its spark laps the media in front when it works on that video (`agentWorksOnTheVideoInFront`)
    /// and `agentSparksMayDraw` allows it, and otherwise waits to join at a later release.
    func agentStarted(id agentID: UUID, sourceTab: AgentSourceTab) {
        change { $0.agentStarted(id: agentID, sourceTab: sourceTab, mayJoinTheLine: agentSparksMayDraw()) }
    }

    /// The agents changed, as a snapshot of the whole store. Each agent the loop remembers is checked against its status: a
    /// finished agent's spark runs its last lap and then goes, and an agent that failed, was cancelled, or is missing from the
    /// snapshot goes at once. The store publishes a new agent before `agentStarted` hears of it, so a missing agent has left.
    func agentStatusesChanged(_ statusesByAgentID: [UUID: LoopSparkAgentStatus]) {
        for runningAgent in state.runningAgents {
            let agentID = runningAgent.id
            switch statusesByAgentID[agentID] ?? .endedWithoutFinishing {
            case .working:
                break
            case .endedWithoutFinishing:
                finishingLapTasks[agentID]?.cancel()
                finishingLapTasks[agentID] = nil
                change { $0.agentEnded(id: agentID) }
            case .finished:
                change { $0.agentFinished(id: agentID) }
                // A finished agent whose spark is off the line has no lap to run.
                guard state.agentLineHolds(agentID: agentID) else {
                    change { $0.agentEnded(id: agentID) }
                    continue
                }
                guard finishingLapTasks[agentID] == nil else { continue }
                finishingLapTasks[agentID] = Task {
                    await waitForAFinishingSparkLap()
                    guard !Task.isCancelled else { return }
                    finishingLapTasks[agentID] = nil
                    change { $0.agentEnded(id: agentID) }
                }
            }
        }
    }

    // MARK: - Waiting for background work

    /// Each returns once a task the controller started has finished, so a test reads the result when the work is done instead of
    /// sleeping for a guessed time, which a loaded runner can outlast. A task that has not started yet is not waited for.
    func waitForTheMediaReadToFinish() async { await mediaRectReadTask?.value }
    func waitForTheIdleHoldToFinish() async { await idleMustHoldTask?.value }
    /// Only returns when the poll ends the loop or the agent line, since a poll whose samples match keeps sampling for as long as one shows.
    func waitForThePollToEndTheLoop() async { await pollTask?.value }
    func waitForTheFinishingLapsToEnd() async {
        for finishingLapTask in Array(finishingLapTasks.values) { await finishingLapTask.value }
    }

    func end(because reason: CursorLoopEndReason) {
        guard state.loopIsShowing || state.turn != .notWaitingForALoop || (reason.endsTheAgentSparks && state.agentLineIsShowing) else { return }
        let whatWasShowing = state.loopIsShowing ? "with the loop showing" : (state.agentLineIsShowing ? "with only the agent line showing" : "before any loop drew")
        change { $0.end(because: reason) }
        let theLoopStays = state.loopIsShowing ? ", and the loop around the circled region stays" : ""
        print("Cursor loop: ended because \(reason), \(whatWasShowing)\(theLoopStays)")
    }

    /// The media a request's own loop is around now, in AppKit screen coordinates, or nil. An agent's spark line does not
    /// count, so a Theme Studio card opens on the picture the learner asked about and never on a video an agent works on.
    var mediaTheRequestLoopIsAroundInAppKitCoordinates: CGRect? {
        state.loopOnTheMedia.map { appKitRect(of: $0.target.screenRect, mainDisplayHeight: NSScreen.screens.first?.frame.height ?? 0) }
    }

    /// The media a loop or an agent line is around now, in AppKit screen coordinates, or nil when none is. Bring back's drop
    /// keeps clear of it, and reading it costs no Apple Event, which an agent's end would otherwise spend on the main actor.
    var mediaScreenRectInAppKitCoordinates: CGRect? {
        state.mediaThePollWatches.map { appKitRect(of: $0.screenRect, mainDisplayHeight: NSScreen.screens.first?.frame.height ?? 0) }
    }

    // MARK: - Drawing

    /// The loop to draw on the screen with this frame, or nil when the media is on another screen or no loop shows.
    func loopToDraw(onScreenWithFrame screenFrame: CGRect) -> CursorLoopOnScreen? {
        guard let loopOnTheMedia = state.loopOnTheMedia else { return nil }
        let target = loopOnTheMedia.target
        let screens = NSScreen.screens
        guard let screenIndex = indexOfTheScreenFrameHolding(target.screenRect, screenFramesInAppKitCoordinates: screens.map(\.frame)),
              screens[screenIndex].frame == screenFrame else {
            return nil
        }
        let mediaRect = rectInOverlayCoordinates(of: target.screenRect, overlayScreen: screens[screenIndex])
        let lineRect = CursorLoopOutline.rectTheLineRunsAlong(
            around: mediaRect,
            insideScreenBounds: CGRect(origin: .zero, size: screenFrame.size)
        )
        var learnersOutline: [CGPoint]?
        if case .circledRegion(let circledRegion) = target {
            learnersOutline = circledRegion.outlineInOverlayCoordinates(
                overlayScreenFrame: screens[screenIndex].frame,
                mainDisplayHeight: screens.first?.frame.height ?? screenFrame.height
            )
        }
        return CursorLoopOnScreen(
            lineRect: lineRect,
            seed: CursorLoopOutline.seed(for: mediaRect),
            learnersOutline: learnersOutline,
            beganAt: loopOnTheMedia.since,
            shimmerSlowsAt: loopOnTheMedia.shimmerSlowsAt,
            isFadingOut: loopOnTheMedia.isFadingOut
        )
    }

    /// The agent line to draw, or nil when none shows or sparks may not draw now.
    func agentLineToDraw() -> (line: AgentSparkLine, isFadingOut: Bool)? {
        agentSparksMayDraw() ? state.agentLineOnTheMedia : nil
    }

    /// The agent sparks to draw on the screen with this frame, or nil when the media is on another screen or no agent line shows.
    func agentLoopToDraw(onScreenWithFrame screenFrame: CGRect) -> AgentLoopOnScreen? {
        guard let agentLineOnTheMedia = agentLineToDraw() else { return nil }
        let screens = NSScreen.screens
        guard let screenIndex = indexOfTheScreenFrameHolding(agentLineOnTheMedia.line.media.screenRect, screenFramesInAppKitCoordinates: screens.map(\.frame)),
              screens[screenIndex].frame == screenFrame else {
            return nil
        }
        let mediaRect = rectInOverlayCoordinates(of: agentLineOnTheMedia.line.media.screenRect, overlayScreen: screens[screenIndex])
        return AgentLoopOnScreen(
            lineRect: CursorLoopOutline.rectTheLineRunsAlong(around: mediaRect, insideScreenBounds: CGRect(origin: .zero, size: screenFrame.size)),
            seed: CursorLoopOutline.seed(for: mediaRect),
            agentIDs: agentLineOnTheMedia.line.agentIDs,
            drawsItsOwnTrack: state.agentLineDrawsItsOwnTrack,
            isFadingOut: agentLineOnTheMedia.isFadingOut
        )
    }

    // MARK: - State changes

    /// Every change goes through here, so the poll and the fade-out follow the state and nothing else.
    private func change(_ stateChange: (inout CursorLoopState) -> Void) {
        let loopWasFadingOut = if case .fadingOut = state.loop { true } else { false }
        let loopWasShowing = state.loopIsShowing
        let agentLineWasFadingOut = if case .fadingOut = state.agentLine { true } else { false }
        let agentLineWasShowing = state.agentLineIsShowing
        stateChange(&state)
        if state.loopIsShowing || state.agentLineIsShowing {
            if !loopWasShowing && state.loopIsShowing {
                print(state.mediaTheLoopIsAround == nil ? "Cursor loop: drawing along the learner's circle" : "Cursor loop: drawing around the media in the front tab")
            }
            if !agentLineWasShowing && state.agentLineIsShowing { print("Cursor loop: agent sparks lap the media in the front tab") }
            if pollTask == nil { startPollingTheFrontTab() }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
        if case .fadingOut = state.agentLine, !agentLineWasFadingOut {
            agentLineFadeOutTask?.cancel()
            agentLineFadeOutTask = Task {
                try? await Task.sleep(for: .seconds(CursorLoopState.fadeOutSeconds))
                guard !Task.isCancelled else { return }
                change { $0.agentLineFadeOutFinished() }
            }
        }
        if case .fadingOut = state.loop, !loopWasFadingOut {
            fadeOutTask?.cancel()
            fadeOutTask = Task {
                try? await Task.sleep(for: .seconds(CursorLoopState.fadeOutSeconds))
                guard !Task.isCancelled else { return }
                change { $0.fadeOutFinished() }
            }
        }
    }

    /// While a loop or an agent line shows, the front tab's window, tab, URL, and media position are sampled as it starts and once
    /// a second after, and any difference, or a sample that fails, clears it. The first sample catches a tab switch
    /// or window move between the release and the hand-off. This also covers a switch to a duplicate tab.
    /// The poll holds the controller weakly, so a controller nobody keeps ends its poll instead of polling forever.
    private func startPollingTheFrontTab() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // The controller is held only for the sample, never across the wait, so one nobody keeps goes while its poll
                // waits.
                guard let waitBeforeTheNextSample = self?.sampleTheFrontTabOnce() else { return }
                await waitBeforeTheNextSample()
            }
        }
    }

    /// One sample of the front tab: the wait before the next one when it still shows the same media, or nil when the poll is
    /// over, because nothing is watched any more or the sample differed and ended the loop.
    private func sampleTheFrontTabOnce() -> (() async -> Void)? {
        guard let mediaThePollWatches = state.mediaThePollWatches else { return nil }
        let sampleNow = readTheFrontTabSample()
        guard !Task.isCancelled else { return nil }
        if let sampleNow, mediaThePollWatches.isTheSameMediaInTheSameTab(as: sampleNow) {
            return waitBetweenFrontTabPolls
        }
        end(because: .tabOrMediaChanged)
        return nil
    }

    // MARK: - Reading Chrome

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The release's front tab, but only when Chrome is the front app. The check comes first so a loop that has no business
    /// reading Chrome never takes the shared read, which the voice command's screen read then makes itself.
    static func frontTabForTheLoop(frontTabRead: FrontTabReadAtRelease, chromeIsTheFrontApp: () -> Bool) -> ChromeVideoTab? {
        guard chromeIsTheFrontApp() else { return nil }
        return frontTabRead.frontTab()
    }

    /// The largest visible video or image in Chrome's front tab, with the tab it is in. Nil when Chrome is not the
    /// front app, shows no media worth framing, or refuses the read, and nil for media that fills a whole screen,
    /// which a loop would frame at the screen's edge for no reason.
    static func readTheMediaInTheFrontTab(frontTabRead: FrontTabReadAtRelease) -> MediaOnTheFrontTab? {
        guard let frontTab = frontTabForTheLoop(
                  frontTabRead: frontTabRead,
                  chromeIsTheFrontApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == chromeBundleIdentifier }
              ),
              let largestMedia = try? ChromeVideoTab.largestVisibleMediaInFrontTabOrNone() else {
            return nil
        }
        let screenFrames = NSScreen.screens.map(\.frame)
        let mediaRect = largestMedia.screenRect
        // The numbers come from the page, so a rect that is not finite frames nothing.
        guard [mediaRect.rectX, mediaRect.rectY, mediaRect.rectWidth, mediaRect.rectHeight].allSatisfy(\.isFinite),
              let screenIndex = indexOfTheScreenFrameHolding(mediaRect, screenFramesInAppKitCoordinates: screenFrames),
              let mainDisplayHeight = screenFrames.first?.height else {
            return nil
        }
        let screenFrameInChromeCoordinates = CGRect(
            x: screenFrames[screenIndex].minX,
            y: mainDisplayHeight - screenFrames[screenIndex].maxY,
            width: screenFrames[screenIndex].width,
            height: screenFrames[screenIndex].height
        )
        guard !mediaFillsTheWholeScreen(largestMedia.screenRect, screenFrameInChromeCoordinates: screenFrameInChromeCoordinates) else {
            return nil
        }
        return MediaOnTheFrontTab(
            screenRect: largestMedia.screenRect,
            sample: FrontTabSample(
                windowID: frontTab.windowId,
                tabID: frontTab.tabId,
                tabURL: frontTab.url,
                pageGeometry: largestMedia.pageGeometry
            )
        )
    }

    /// The front tab's window, tab, URL, and media position from two Apple Events, for the poll. Nil when Chrome is not
    /// the front app, shows no media worth framing, or refuses the read.
    static func readTheFrontTabSample() -> FrontTabSample? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == chromeBundleIdentifier,
              let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow(),
              let pageGeometry = try? ChromeVideoTab.pageGeometryOfTheLargestVisibleMediaInFrontTab() else {
            return nil
        }
        return FrontTabSample(windowID: frontTab.windowId, tabID: frontTab.tabId, tabURL: frontTab.url, pageGeometry: pageGeometry)
    }
}
