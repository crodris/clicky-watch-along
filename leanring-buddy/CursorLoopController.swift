//
//  CursorLoopController.swift
//  leanring-buddy
//
//  Runs the loop around the media Clicky is looking at. It reads the front tab's media rect when
//  push-to-talk is released, feeds `CursorLoopState` the events that draw and clear the loop, and while a
//  loop shows it re-reads the front tab once a second and clears the loop when anything differs.
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
    /// Reads Chrome's front tab. Tests pass their own, since the real one drives Chrome.
    private let readTheMediaInTheFrontTab: () -> MediaOnTheFrontTab?

    private static let secondsBetweenFrontTabPolls: TimeInterval = 1
    /// The voice state goes idle for a moment after a request is submitted, when the dictation session finishes
    /// and before the request sets its own processing state, so an idle ends a loop only after it holds this long.
    static let secondsAnIdleMustHoldToEndTheLoop: TimeInterval = 0.3
    private static let chromeBundleIdentifier = "com.google.Chrome"

    init(readTheMediaInTheFrontTab: @escaping () -> MediaOnTheFrontTab? = CursorLoopController.readTheMediaInTheFrontTab) {
        self.readTheMediaInTheFrontTab = readTheMediaInTheFrontTab
        // The front app changing is a system event, so a notification is the only way to hear it.
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
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
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
    }

    var isShowingTheLoop: Bool { state.loopIsShowing }

    // MARK: - Events

    func pushToTalkWasPressed() {
        mediaRectReadTask?.cancel()
        end(because: .newPushToTalk)
    }

    /// Starts the rect read beside the router call. It is wasted unless the request becomes a look at the media.
    func pushToTalkWasReleased() {
        change { $0.pushToTalkWasReleased() }
        mediaRectReadTask?.cancel()
        mediaRectReadTask = Task {
            let readStartedAt = Self.now
            let media = readTheMediaInTheFrontTab()
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
            guard !Task.isCancelled, latestVoiceState == .idle else { return }
            end(because: .thinkingStopped)
        }
    }

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

    /// While a loop shows, the front tab's window, tab, URL, and media rect are read once a second, and any
    /// difference, or a read that fails, clears the loop. That also covers a window move and a switch to a duplicate tab.
    private func startPollingTheFrontTab() {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.secondsBetweenFrontTabPolls))
                guard !Task.isCancelled, let mediaTheLoopIsAround = state.mediaTheLoopIsAround else { return }
                let mediaNow = readTheMediaInTheFrontTab()
                guard !Task.isCancelled else { return }
                if mediaNow?.isTheSameMediaInTheSameTab(as: mediaTheLoopIsAround) != true {
                    end(because: .tabOrMediaChanged)
                    return
                }
            }
        }
    }

    // MARK: - Reading Chrome

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The largest visible video or image in Chrome's front tab, with the tab it is in. Nil when Chrome is not the
    /// front app, shows no media worth framing, or refuses the read, and nil for media that fills a whole screen,
    /// which a loop would frame at the screen's edge for no reason.
    static func readTheMediaInTheFrontTab() -> MediaOnTheFrontTab? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == chromeBundleIdentifier,
              let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow(),
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
            windowID: frontTab.windowId,
            tabID: frontTab.tabId,
            tabURL: frontTab.url
        )
    }
}
