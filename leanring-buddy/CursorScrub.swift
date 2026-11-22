//
//  CursorScrub.swift
//  leanring-buddy
//
//  Scrub by voice: when the router seeks the front video to a moment (`seek_to_moment`, `seek_to_time`), the blue cursor
//  flies to the video's progress bar at the current time, slides along it to the moment, and the video seeks as it
//  arrives. The progress bar is YouTube's when the page has one, and the video's bottom edge otherwise.
//

import AppKit
import Combine
import Foundation

/// The line the cursor slides along, in global AppKit points (bottom-left origin), and the video it stands for.
nonisolated struct VideoScrubLine: Equatable {
    /// Where the line starts (time 0) and ends (the video's duration). Both share one y.
    let startPoint: CGPoint
    let endPoint: CGPoint
    let durationSeconds: Double
    let currentSeconds: Double
    /// True for YouTube's own progress bar, false for the video's bottom edge.
    let followsTheProgressBar: Bool

    /// A line shorter than this is too small to slide along, such as a thumbnail-sized player.
    static let shortestLengthInPoints: CGFloat = 40

    /// The point on the line for a time, with a time outside the video held at its ends.
    func point(atSeconds seconds: Double) -> CGPoint {
        let shareOfTheVideo = seconds.isFinite ? min(1, max(0, seconds / durationSeconds)) : 0
        return CGPoint(
            x: startPoint.x + (endPoint.x - startPoint.x) * shareOfTheVideo,
            y: startPoint.y + (endPoint.y - startPoint.y) * shareOfTheVideo
        )
    }
}

/// What the page script reports besides the window geometry: the line's times and which line it is.
nonisolated private struct VideoScrubLineTimes: Decodable {
    let currentSeconds: Double
    let durationSeconds: Double
    let followsTheProgressBar: Bool
}

/// Reads the page script's reply. Nil for a page with no video, a line off the screen, a video with no known length, or a
/// line too short to slide along. `screenRect` turns the page geometry into a Chrome screen rect, from the web area when it can.
func videoScrubLine(
    fromScriptReply scriptReply: String,
    mainDisplayHeight: CGFloat,
    screenRect: (ChromePageGeometry) -> ScreenRectInChromeCoordinates?
) -> VideoScrubLine? {
    let replyData = Data(scriptReply.utf8)
    guard let pageGeometry = try? JSONDecoder().decode(ChromePageGeometry.self, from: replyData),
          let lineTimes = try? JSONDecoder().decode(VideoScrubLineTimes.self, from: replyData),
          lineTimes.durationSeconds.isFinite, lineTimes.durationSeconds > 0,
          lineTimes.currentSeconds.isFinite,
          let lineRectInChrome = screenRect(pageGeometry) else {
        return nil
    }
    let lineRect = appKitRect(of: lineRectInChrome, mainDisplayHeight: mainDisplayHeight)
    guard lineRect.width >= VideoScrubLine.shortestLengthInPoints else { return nil }
    return VideoScrubLine(
        startPoint: CGPoint(x: lineRect.minX, y: lineRect.minY),
        endPoint: CGPoint(x: lineRect.maxX, y: lineRect.minY),
        durationSeconds: lineTimes.durationSeconds,
        currentSeconds: lineTimes.currentSeconds,
        followsTheProgressBar: lineTimes.followsTheProgressBar
    )
}

/// The page script that finds the scrub line of the front tab's main video. It reports the line as an element box of height
/// 0 in the shape of `ChromePageGeometry`, so the same web area math places it, plus the video's times. YouTube's progress bar
/// is the line when the video's player has one, and the video's bottom edge otherwise. A YouTube player hides its controls
/// about 2 seconds after its last mouse move, so the script sends the player a mouse move every half second for 6 seconds,
/// which keeps the bar showing through the flight, the slide, and the hold at the moment.
/// It returns 'no-video', 'off-screen' when any part of the line is outside the viewport, since the time to point mapping
/// needs the whole line, or 'no-length' for a video with no known length, such as a live stream, and wakes the controls only
/// for a line it returns. It holds no double quote or backslash, since it runs inside an AppleScript string.
nonisolated let videoScrubLineJavaScript = [
    "(function () {",
    LearnerVideoCommand.mainVideoJavaScript,
    "if (!video) { return 'no-video'; }",
    "var line = null;",
    "var player = video.closest('.html5-video-player');",
    "var bar = player ? player.querySelector('.ytp-progress-bar') : null;",
    "if (bar) {",
    "var barRect = bar.getBoundingClientRect();",
    "if (barRect.width > 0) { line = { left: barRect.left, top: barRect.top + barRect.height / 2, width: barRect.width }; }",
    "}",
    "if (!line) { var videoRect = video.getBoundingClientRect(); line = { left: videoRect.left, top: videoRect.bottom, width: videoRect.width }; bar = null; }",
    "if (line.left < -1 || line.left + line.width > window.innerWidth + 1 || line.top < 0 || line.top > window.innerHeight) { return 'off-screen'; }",
    "if (!Number.isFinite(video.duration) || video.duration <= 0) { return 'no-length'; }",
    "if (bar) {",
    "var wakeTheControls = function () { player.dispatchEvent(new MouseEvent('mousemove', { bubbles: true })); };",
    "wakeTheControls(); var wakesLeft = 12; var wakeTimer = setInterval(function () { wakesLeft -= 1; if (wakesLeft <= 0) { clearInterval(wakeTimer); } wakeTheControls(); }, 500);",
    "}",
    "return JSON.stringify({ screenX: window.screenX, screenY: window.screenY, outerWidth: window.outerWidth, outerHeight: window.outerHeight, innerWidth: window.innerWidth, innerHeight: window.innerHeight, devicePixelRatio: window.devicePixelRatio, left: line.left, top: line.top, width: line.width, height: 0, imageSourceURL: null, currentSeconds: video.currentTime, durationSeconds: Number.isFinite(video.duration) ? video.duration : 0, followsTheProgressBar: !!bar });",
    "})()",
].joined(separator: " ")

/// One scrub the overlay plays: fly to `startPoint` on the line, slide to `momentPoint`, and tell the controller on arrival.
nonisolated struct CursorScrubRequest: Equatable {
    let scrubID: UUID
    /// The current time's point on the line, in global AppKit points.
    let startPoint: CGPoint
    /// The moment's point on the line, where the video seeks.
    let momentPoint: CGPoint
    /// The frame of the display that holds the line, so only that screen's overlay plays it.
    let displayFrame: CGRect
}

/// How the overlay moves the cursor for a scrub.
nonisolated enum CursorScrubMotion: Equatable {
    /// The Point flight to the current time on the line, then a slide along it to the moment, paced like the Point move.
    case flyThenSlide
    /// Reduce Motion: no travel. The cursor fades out and fades in at the moment.
    case fadeAtTheMoment
}

nonisolated func cursorScrubMotion(reduceMotionIsOn: Bool) -> CursorScrubMotion {
    reduceMotionIsOn ? .fadeAtTheMoment : .flyThenSlide
}

/// How the wait before the seek ended.
nonisolated enum CursorScrubOutcome: Equatable {
    /// No line to slide along (no bar found, Chrome not in front, or no screen holds it), so the seek runs at once.
    case noScrubLine
    case reachedTheMoment
    /// A push-to-talk press, or a cancel of the voice command, landed it at once.
    case landedAtOnce
    /// The overlay never reported arrival.
    case timedOut
    /// The overlay of the line's display would not fly, such as during the first-launch welcome, so the seek runs at once.
    case refusedByTheOverlay
    /// A newer scrub, or a pointing, took over before this one arrived.
    case replaced
}

/// What decides whether a voice seek scrubs at all, read before the line, since the read costs an Apple Event and an
/// accessibility walk on the main actor.
nonisolated struct CursorScrubConditions: Equatable {
    /// Another app's window may cover the line otherwise.
    var chromeIsTheFrontApp: Bool
    /// A narration, a quiz question, or an instant replay holds the cursor on a part, and the scrub must not take it away.
    var cursorIsPointing: Bool
    /// A pop-out or a scene covers the video and its bar.
    var sceneIsOnScreen: Bool
    /// A push-to-talk press cancelled the voice command, so the learner is talking and nothing should fly.
    var commandWasCancelled: Bool
}

/// The line to scrub along, or nil when the seek should run at once with no motion.
func scrubLineToPlay(_ conditions: CursorScrubConditions, readTheLine: () -> VideoScrubLine?) -> VideoScrubLine? {
    guard conditions.chromeIsTheFrontApp, !conditions.cursorIsPointing, !conditions.sceneIsOnScreen, !conditions.commandWasCancelled else {
        return nil
    }
    return readTheLine()
}

/// The tab a voice seek moves after the scrub: the tab checked before it, only while that page is still the one in front,
/// since the scrub takes a few seconds and YouTube may have played the next video meanwhile.
func tabToSeekAfterTheScrub(checkedTab: ChromeVideoTab, tabInFrontNow: ChromeVideoTab) throws -> ChromeVideoTab {
    guard tabInFrontNow.isTheSamePage(as: checkedTab) else { throw VideoQuizFailure.theVideoChangedDuringTheScrub }
    return checkedTab
}

/// Holds the one scrub the overlay plays and the wait for it. The overlay reads `request`, reports arrival with
/// `cursorReachedTheMoment` and the end of its flight back with `overlayFinished`, or a refusal to fly with
/// `overlayRefused`, and a push-to-talk press calls `landAtOnce`. Each scrub resumes its wait exactly once, whichever of
/// these comes first.
@MainActor
final class CursorScrubController: ObservableObject {
    @Published private(set) var request: CursorScrubRequest?
    private var pendingWait: (scrubID: UUID, continuation: CheckedContinuation<CursorScrubOutcome, Never>)?
    private let sleep: (_ seconds: Double) async -> Void

    init(sleep: @escaping (_ seconds: Double) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) }) {
        self.sleep = sleep
    }

    /// Shows the scrub for a seek to `targetSeconds` and returns once the seek may run: when the cursor reaches the moment,
    /// a press lands it, or `timeoutSeconds` pass. With no line, or no display that holds it, it returns at once.
    func scrubBeforeTheSeek(along scrubLine: VideoScrubLine?, toSeconds targetSeconds: Double, displayFrames: [CGRect], timeoutSeconds: Double) async -> CursorScrubOutcome {
        guard let scrubLine else { return .noScrubLine }
        let startPoint = scrubLine.point(atSeconds: scrubLine.currentSeconds)
        let momentPoint = scrubLine.point(atSeconds: targetSeconds)
        // Both ends must sit on one display, since each display's overlay draws only its own buddy, and a Chrome window can
        // span two. The line sits on its bottom edge for the video fallback, so a point exactly on a screen's edge still counts.
        guard let displayFrame = displayFrames.first(where: { frame in
            let frameWithItsEdges = frame.insetBy(dx: -1, dy: -1)
            return frameWithItsEdges.contains(startPoint) && frameWithItsEdges.contains(momentPoint)
        }) else {
            return .noScrubLine
        }
        resumeThePendingWait(with: .replaced)
        let scrubID = UUID()
        request = CursorScrubRequest(scrubID: scrubID, startPoint: startPoint, momentPoint: momentPoint, displayFrame: displayFrame)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingWait = (scrubID: scrubID, continuation: continuation)
                Task { [weak self] in
                    await self?.sleep(timeoutSeconds)
                    // Only a wait still open times out, so a cursor already flying back from the moment is left alone.
                    guard let self, self.pendingWait?.scrubID == scrubID else { return }
                    self.endTheWait(ofScrubID: scrubID, with: .timedOut, clearingTheRequest: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endTheWait(ofScrubID: scrubID, with: .landedAtOnce, clearingTheRequest: true) }
        }
        return outcome
    }

    /// The cursor reached the moment, so the video may seek while the cursor holds there and flies back.
    func cursorReachedTheMoment(scrubID: UUID) {
        endTheWait(ofScrubID: scrubID, with: .reachedTheMoment, clearingTheRequest: false)
    }

    /// The overlay is done with the scrub: the cursor is back at the mouse, or a pointing took over before it arrived.
    func overlayFinished(scrubID: UUID) {
        endTheWait(ofScrubID: scrubID, with: .replaced, clearingTheRequest: true)
    }

    /// The overlay of the line's display will not fly this scrub, such as during the first-launch welcome. The request
    /// clears at once, since while it is set every screen hides its buddy.
    func overlayRefused(scrubID: UUID) {
        endTheWait(ofScrubID: scrubID, with: .refusedByTheOverlay, clearingTheRequest: true)
    }

    /// A push-to-talk press: the seek runs now, and the cursor goes back to the mouse, where the ring listens.
    func landAtOnce() {
        guard let request else { return }
        endTheWait(ofScrubID: request.scrubID, with: .landedAtOnce, clearingTheRequest: true)
    }

    private func endTheWait(ofScrubID scrubID: UUID, with outcome: CursorScrubOutcome, clearingTheRequest: Bool) {
        if pendingWait?.scrubID == scrubID {
            resumeThePendingWait(with: outcome)
        }
        if clearingTheRequest, request?.scrubID == scrubID {
            request = nil
        }
    }

    private func resumeThePendingWait(with outcome: CursorScrubOutcome) {
        guard let pendingWait else { return }
        self.pendingWait = nil
        pendingWait.continuation.resume(returning: outcome)
    }
}
