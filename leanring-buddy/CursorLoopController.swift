//
//  CursorLoopController.swift
//  leanring-buddy
//
//  Runs the loop around the media Clicky is looking at. It reads the front tab's media rect when
//  push-to-talk is released, feeds `CursorLoopState` the events that draw and clear the loop, and while a
//  loop shows it samples the front tab as the loop starts and once a second after, and clears the loop when anything differs.
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
    private var appActivationObserver: NSObjectProtocol?
    private var idleMustHoldTask: Task<Void, Never>?
    private var latestVoiceState = CompanionVoiceState.idle
    /// Read Chrome's front tab: the full media read at release, and the cheap sample the poll takes. Tests pass
    /// their own, since the real ones drive Chrome. The release's front tab read is shared with the voice command's screen
    /// read, so the media read asks it for the tab instead of reading the tab itself.
    private let readTheMediaInTheFrontTab: (FrontTabReadAtRelease) -> MediaOnTheFrontTab?
    private let readTheFrontTabSample: () -> FrontTabSample?
    /// The wait between front tab samples. Tests pass one that counts its calls, so they check when the poll waits without
    /// reading the clock of a busy machine.
    private let waitBetweenFrontTabPolls: () async -> Void
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
    private static let chromeBundleIdentifier = "com.google.Chrome"

    init(
        readTheMediaInTheFrontTab: @escaping (FrontTabReadAtRelease) -> MediaOnTheFrontTab? = CursorLoopController.readTheMediaInTheFrontTab,
        readTheFrontTabSample: @escaping () -> FrontTabSample? = CursorLoopController.readTheFrontTabSample,
        waitBetweenFrontTabPolls: @escaping () async -> Void = CursorLoopController.sleepBetweenFrontTabPolls,
        appActivationNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.readTheMediaInTheFrontTab = readTheMediaInTheFrontTab
        self.readTheFrontTabSample = readTheFrontTabSample
        self.waitBetweenFrontTabPolls = waitBetweenFrontTabPolls
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
                guard let self, self.state.loopIsShowing || self.state.turn != .notWaitingForALoop else { return }
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

    /// Whether the loop shows on the screen with this frame. The cursor's cue asks per screen, since the loop's spark
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
            change { $0.mediaRectArrived(media, at: Self.now) }
        }
    }

    /// The request became a look at the media on screen. The caller skips this while a scene already covers it.
    func requestBecameALookAtTheMedia() {
        print("Cursor loop: the request became a look at the media, turn is \(state.turn == .notWaitingForALoop ? "not waiting for a loop" : "waiting")")
        change { $0.requestBecameALookAtTheMedia(at: Self.now) }
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
            try? await Task.sleep(for: .seconds(Self.secondsAnIdleMustHoldToEndTheLoop))
            // A request that has not handed off yet may sit idle for its whole router call, so only a loop that
            // is showing ends here. A cancelled request never hands off, and the next press ends its turn.
            guard !Task.isCancelled, latestVoiceState == .idle, state.loopIsShowing else { return }
            end(because: .thinkingStopped)
        }
    }

    // MARK: - Waiting for background work

    /// Each returns once a task the controller started has finished, so a test reads the result when the work is done instead of
    /// sleeping for a guessed time, which a loaded runner can outlast. A task that has not started yet is not waited for.
    func waitForTheMediaReadToFinish() async { await mediaRectReadTask?.value }
    func waitForTheIdleHoldToFinish() async { await idleMustHoldTask?.value }
    /// Only returns when the poll ends the loop, since a poll whose samples match keeps sampling for as long as the loop shows.
    func waitForThePollToEndTheLoop() async { await pollTask?.value }

    func end(because reason: CursorLoopEndReason) {
        guard state.loopIsShowing || state.turn != .notWaitingForALoop else { return }
        print("Cursor loop: ended because \(reason), \(state.loopIsShowing ? "with the loop showing" : "before any loop drew")")
        change { $0.end(because: reason) }
    }

    // MARK: - Drawing

    /// The loop to draw on the screen with this frame, or nil when the media is on another screen or no loop shows.
    func loopToDraw(onScreenWithFrame screenFrame: CGRect) -> CursorLoopOnScreen? {
        guard let loopOnTheMedia = state.loopOnTheMedia else { return nil }
        let media = loopOnTheMedia.media
        let screens = NSScreen.screens
        guard let screenIndex = indexOfTheScreenFrameHolding(media.screenRect, screenFramesInAppKitCoordinates: screens.map(\.frame)),
              screens[screenIndex].frame == screenFrame else {
            return nil
        }
        let mediaRect = rectInOverlayCoordinates(of: media.screenRect, overlayScreen: screens[screenIndex])
        let lineRect = CursorLoopOutline.rectTheLineRunsAlong(
            around: mediaRect,
            insideScreenBounds: CGRect(origin: .zero, size: screenFrame.size)
        )
        return CursorLoopOnScreen(
            lineRect: lineRect,
            seed: CursorLoopOutline.seed(for: mediaRect),
            beganAt: loopOnTheMedia.since,
            sparkSlowsAt: loopOnTheMedia.sparkSlowsAt,
            isFadingOut: loopOnTheMedia.isFadingOut
        )
    }

    // MARK: - State changes

    /// Every change goes through here, so the poll and the fade-out follow the state and nothing else.
    private func change(_ stateChange: (inout CursorLoopState) -> Void) {
        let loopWasFadingOut = if case .fadingOut = state.loop { true } else { false }
        let loopWasShowing = state.loopIsShowing
        stateChange(&state)
        if state.loopIsShowing {
            if !loopWasShowing { print("Cursor loop: drawing around the media in the front tab") }
            if pollTask == nil { startPollingTheFrontTab() }
        } else {
            pollTask?.cancel()
            pollTask = nil
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

    /// While a loop shows, the front tab's window, tab, URL, and media position are sampled as the loop starts and once
    /// a second after, and any difference, or a sample that fails, clears the loop. The first sample catches a tab switch
    /// or window move between the release and the hand-off. This also covers a switch to a duplicate tab.
    private func startPollingTheFrontTab() {
        pollTask = Task {
            while !Task.isCancelled {
                guard let mediaTheLoopIsAround = state.mediaTheLoopIsAround else { return }
                let sampleNow = readTheFrontTabSample()
                guard !Task.isCancelled else { return }
                if let sampleNow, mediaTheLoopIsAround.isTheSameMediaInTheSameTab(as: sampleNow) {
                    await waitBetweenFrontTabPolls()
                    continue
                }
                end(because: .tabOrMediaChanged)
                return
            }
        }
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
