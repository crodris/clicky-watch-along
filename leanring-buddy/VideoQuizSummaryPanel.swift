//
//  VideoQuizSummaryPanel.swift
//  leanring-buddy
//
//  The Card at the end of a video quiz or a video: the score, what the learner learned, each question to look at again
//  (a button that goes back to it), and the study guide link. At the end of a quiz it Glides out of the video; at the end of
//  a video it Glides out of the cursor, after the agent discs gather there. It closes back into where it came from on the
//  shared carrier, and shows in a full-screen space too.
//

import AppKit
import SwiftUI

/// Where the summary Card sits: centered on the video, inside the screen's visible frame, or centered on the screen with
/// no video. Global AppKit coordinates.
func videoQuizSummaryCardFrame(cardSize: CGSize, videoRect: CGRect?, visibleFrame: CGRect) -> CGRect {
    let center = videoRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
    let margin: CGFloat = 12
    let originX = min(max(center.x - cardSize.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - margin - cardSize.width)
    let originY = min(max(center.y - cardSize.height / 2, visibleFrame.minY + margin), visibleFrame.maxY - margin - cardSize.height)
    return CGRect(origin: CGPoint(x: originX, y: originY), size: cardSize)
}

/// The point the Card Glides out of: the top edge of the video, where the loop ran, or the mouse with no video.
func videoQuizSummaryGlideOrigin(videoRect: CGRect?, mouseLocation: CGPoint) -> CGPoint {
    guard let videoRect else { return mouseLocation }
    return CGPoint(x: videoRect.midX, y: videoRect.maxY)
}

/// The point the Card of a video's end Glides out of: where the discs landed, so the Card unfolds from them, unless that point is
/// off the Card's display, since a carrier move stays on one display, or there is none, and then the video's top edge or the mouse,
/// as for a quiz's end. The screen frame comes in as an input, so a test passes its own and never reads the real displays.
func videoRecapGlideOrigin(cursorPoint: CGPoint?, cardScreenFrame: CGRect, videoRect: CGRect?, mouseLocation: CGPoint) -> CGPoint {
    if let cursorPoint, cardScreenFrame.contains(cursorPoint) { return cursorPoint }
    return videoQuizSummaryGlideOrigin(videoRect: videoRect, mouseLocation: mouseLocation)
}

/// A Chrome screen rect (top-left origin on the main display) in global AppKit coordinates (bottom-left origin).
func appKitRect(of screenRect: ScreenRectInChromeCoordinates, mainDisplayHeight: CGFloat) -> CGRect {
    CGRect(x: screenRect.rectX, y: mainDisplayHeight - (screenRect.rectY + screenRect.rectHeight), width: screenRect.rectWidth, height: screenRect.rectHeight)
}

struct VideoQuizSummaryCardView: View {
    static let cardWidth: CGFloat = 320

    let recap: VideoRecap
    let moment: VideoRecapMoment
    let accentColor: Color
    let goBackToTheMissedQuestion: (VideoQuizMissedQuestion) -> Void
    let openTheStudyGuide: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(recap.title(when: moment))
                    .font(DS.TypeScale.voice.font)
                    .foregroundStyle(Color.white)
                Spacer(minLength: 8)
                if let summary = recap.summary {
                    Text(summary.scoreText)
                        .font(DS.TypeScale.title.font)
                        // Green means right in Clicky, so only a quiz with every answer right shows its score in green.
                        .foregroundStyle(summary.missedQuestions.isEmpty ? DS.Colors.success : DS.Colors.textPrimary)
                }
            }
            if let summary = recap.summary {
                Text(summary.captionText)
                    .font(DS.TypeScale.caption.font)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recap.learnedLines.isEmpty {
                learnedLines
            }
            // A long list scrolls inside the Card, so its Close button always stays on screen.
            if let summary = recap.summary, !summary.missedQuestions.isEmpty {
                if summary.missedQuestions.count > Self.missedQuestionsShownWithoutScrolling {
                    ScrollView {
                        missedQuestionButtons(of: summary)
                    }
                    .frame(height: Self.scrollingListHeight)
                } else {
                    missedQuestionButtons(of: summary)
                }
            }
            HStack(spacing: 8) {
                if recap.studyGuideURL != nil {
                    VideoRecapStudyGuideButton(accentColor: accentColor, action: openTheStudyGuide)
                }
                Spacer()
                VideoQuizSummaryCloseButton(close: close)
            }
        }
        .padding(14)
        .frame(width: Self.cardWidth, alignment: .leading)
        .tetherCard()
    }

    static let missedQuestionsShownWithoutScrolling = 5
    /// About five rows of two lines each.
    static let scrollingListHeight: CGFloat = 300

    private var learnedLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What you learned")
                .font(DS.TypeScale.caption.font)
                .foregroundStyle(DS.Colors.textSecondary)
            ForEach(recap.learnedLines, id: \.self) { learnedLine in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 5, height: 5)
                        // The dot sits on the first line's middle, not its baseline.
                        .offset(y: -2)
                    Text(learnedLine)
                        .font(DS.TypeScale.body.font)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func missedQuestionButtons(of summary: VideoQuizSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(summary.missedQuestions) { missedQuestion in
                VideoQuizMissedQuestionButton(missedQuestion: missedQuestion, accentColor: accentColor) {
                    goBackToTheMissedQuestion(missedQuestion)
                }
            }
        }
    }
}

/// Opens the video's study guide, in the accent, at the Card's foot beside Close.
private struct VideoRecapStudyGuideButton: View {
    let accentColor: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Study guide")
                    .font(DS.TypeScale.title.font)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isHovered ? accentColor : Color.white.opacity(0.1), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverAndPointer { hovering in
            withAnimation(DS.Move.snap.animation(reduceMotionIsOn: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                isHovered = hovering
            }
        }
    }
}

private struct VideoQuizMissedQuestionButton: View {
    let missedQuestion: VideoQuizMissedQuestion
    let accentColor: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(missedQuestion.question)
                    .font(DS.TypeScale.body.font)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: missedQuestion.timestampText)
                    .font(DS.TypeScale.data.font)
                    .foregroundStyle(accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isHovered ? accentColor : Color.white.opacity(0.1), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverAndPointer { hovering in
            withAnimation(DS.Move.snap.animation(reduceMotionIsOn: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                isHovered = hovering
            }
        }
    }
}

private struct VideoQuizSummaryCloseButton: View {
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: close) {
            Text("Close")
                .font(DS.TypeScale.title.font)
                .foregroundStyle(isHovered ? Color.white : DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverAndPointer { hovering in
            withAnimation(DS.Move.snap.animation(reduceMotionIsOn: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                isHovered = hovering
            }
        }
    }
}

/// Owns the summary Card's panel: a nonactivating panel that never becomes key, so the page under it keeps the keyboard.
@MainActor
final class VideoQuizSummaryPanelController {
    private var panel: NonKeyFloatingPanel?
    private var shownCardFrame: CGRect?
    private var glideOrigin: CGPoint = .zero
    private var shownCardView: VideoQuizSummaryCardView?
    private var accentNSColor: NSColor = .white
    /// The Glide that carries the Card in, so a close before it lands can end it at once.
    private var glideInFlight: CarrierFlight?
    /// Called each time a shown Card closes, however it closed, so the discs a video's end gathered at the cursor go back.
    var onClosed: ((_ glideOrigin: CGPoint) -> Void)?

    /// True from the moment the Card starts to Glide in, so Escape closes it even before it lands.
    var isShowing: Bool { panel != nil }

    /// Shows the Card for `recap`, over the video when its rect is known. It Glides out of the video's top edge when a quiz
    /// ended, or out of `cursorPoint`, where the discs gathered, when the video did, or fades in with Reduce Motion on.
    /// A `cursorPoint` off the Card's display, or none, makes a video's end Glide out of the video's top edge too, since a
    /// carrier move stays on one display.
    func show(
        recap: VideoRecap,
        moment: VideoRecapMoment,
        cursorPoint: CGPoint? = nil,
        videoRect: CGRect?,
        accentColor: Color,
        goBackToTheMissedQuestion: @escaping (VideoQuizMissedQuestion) -> Void,
        openTheStudyGuide: @escaping () -> Void
    ) {
        close(animated: false)
        let cardView = VideoQuizSummaryCardView(
            recap: recap,
            moment: moment,
            accentColor: accentColor,
            goBackToTheMissedQuestion: { [weak self] missedQuestion in
                self?.close(animated: true)
                goBackToTheMissedQuestion(missedQuestion)
            },
            openTheStudyGuide: openTheStudyGuide,
            close: { [weak self] in self?.close(animated: true) }
        )
        // The window is larger than the Card by the margins the other Cards use, so the Card's shadow has room to draw.
        let hostingView = FirstMouseHostingView(rootView: cardView.padding(EdgeInsets(
            top: AgentListWindowMargins.top,
            leading: AgentListWindowMargins.leading,
            bottom: AgentListWindowMargins.bottom,
            trailing: AgentListWindowMargins.trailing
        )))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        let windowSize = hostingView.fittingSize
        let cardSize = CGSize(
            width: windowSize.width - AgentListWindowMargins.horizontal,
            height: windowSize.height - AgentListWindowMargins.vertical
        )
        let mouseLocation = NSEvent.mouseLocation
        let screen = videoRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        let cardFrame = videoQuizSummaryCardFrame(cardSize: cardSize, videoRect: videoRect, visibleFrame: screen.visibleFrame)
        let windowTopLeft = AgentListWindowMargins.windowTopLeft(forCardTopLeft: CGPoint(x: cardFrame.minX, y: cardFrame.maxY))
        let windowFrame = CGRect(x: windowTopLeft.x, y: windowTopLeft.y - windowSize.height, width: windowSize.width, height: windowSize.height)
        let summaryPanel = NonKeyFloatingPanel(contentRect: windowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        summaryPanel.isOpaque = false
        summaryPanel.backgroundColor = .clear
        summaryPanel.hasShadow = false
        // Over the video and a live scene, and one below the cursor overlay windows, so the cursor draws over the Card.
        summaryPanel.level = .screenSaver
        // A full-screen video has its own space, and the Card must show there too.
        summaryPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        summaryPanel.hidesOnDeactivate = false
        summaryPanel.isReleasedWhenClosed = false
        summaryPanel.contentView = hostingView
        panel = summaryPanel
        shownCardFrame = cardFrame
        shownCardView = cardView
        accentNSColor = NSColor(accentColor)
        switch moment {
        case .quizEnded:
            glideOrigin = videoQuizSummaryGlideOrigin(videoRect: videoRect, mouseLocation: mouseLocation)
        case .videoEnded:
            glideOrigin = videoRecapGlideOrigin(cursorPoint: cursorPoint, cardScreenFrame: screen.frame, videoRect: videoRect, mouseLocation: mouseLocation)
        }
        print("Video quiz summary: showing the Card at \(cardFrame.integral) after \(moment == .videoEnded ? "the video ended" : "the quiz ended"), \(videoRect == nil ? "with no video in front" : "over the video")")

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            summaryPanel.alphaValue = 0
            summaryPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Move.fadeSeconds
                summaryPanel.animator().alphaValue = 1
            }
            return
        }
        glideInFlight = TetherCarrier.shared.play(
            .glideFromOrigin(glideOrigin, into: cardFrame),
            carrying: cardView,
            onDisplay: screen.displayID,
            tetherColor: accentNSColor,
            onLanded: { [weak self, weak summaryPanel] in
                // A close during the Glide already dropped this panel, so the Card does not appear after it.
                guard let summaryPanel, self?.panel === summaryPanel else { return }
                summaryPanel.orderFrontRegardless()
            }
        )
    }

    /// Closes the Card. Animated, it Glides back into the video, or fades with Reduce Motion on.
    func close(animated: Bool) {
        guard let closingPanel = panel else { return }
        panel = nil
        onClosed?(glideOrigin)
        // A Card still Gliding in lands at once and leaves with it, and the guard in its landing keeps the real panel from
        // showing.
        glideInFlight?.landAtOnce(hidingTheCarriedView: true)
        glideInFlight = nil
        guard animated, closingPanel.isVisible, let cardFrame = shownCardFrame, let cardView = shownCardView else {
            closingPanel.orderOut(nil)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DS.Move.fadeSeconds
                closingPanel.animator().alphaValue = 0
            }, completionHandler: { closingPanel.orderOut(nil) })
            return
        }
        guard let closingScreen = closingPanel.screen else {
            closingPanel.orderOut(nil)
            return
        }
        TetherCarrier.shared.play(
            .glideClose(from: cardFrame, into: glideOrigin),
            carrying: cardView,
            onDisplay: closingScreen.displayID,
            tetherColor: accentNSColor,
            onLanded: {}
        )
        // The carrier draws the Card from its resting frame, so the real panel goes as the close starts.
        closingPanel.orderOut(nil)
    }
}
