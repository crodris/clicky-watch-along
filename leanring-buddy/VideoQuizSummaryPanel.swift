//
//  VideoQuizSummaryPanel.swift
//  leanring-buddy
//
//  The Card at the end of a video quiz: the score and each question to look at again, each a button that goes back to it.
//  It Glides out of the video on the shared carrier and closes back into it, and shows in a full-screen space too.
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

/// A Chrome screen rect (top-left origin on the main display) in global AppKit coordinates (bottom-left origin).
func appKitRect(of screenRect: ScreenRectInChromeCoordinates, mainDisplayHeight: CGFloat) -> CGRect {
    CGRect(x: screenRect.rectX, y: mainDisplayHeight - (screenRect.rectY + screenRect.rectHeight), width: screenRect.rectWidth, height: screenRect.rectHeight)
}

struct VideoQuizSummaryCardView: View {
    static let cardWidth: CGFloat = 320

    let summary: VideoQuizSummary
    let accentColor: Color
    let goBackToTheMissedQuestion: (VideoQuizMissedQuestion) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Quiz done")
                    .font(DS.TypeScale.voice.font)
                    .foregroundStyle(Color.white)
                Spacer(minLength: 8)
                Text(summary.scoreText)
                    .font(DS.TypeScale.title.font)
                    // Green means right in Clicky, so only a quiz with every answer right shows its score in green.
                    .foregroundStyle(summary.missedQuestions.isEmpty ? DS.Colors.success : DS.Colors.textPrimary)
            }
            Text(summary.captionText)
                .font(DS.TypeScale.caption.font)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // A long list scrolls inside the Card, so its Close button always stays on screen.
            if summary.missedQuestions.count > Self.missedQuestionsShownWithoutScrolling {
                ScrollView {
                    missedQuestionButtons
                }
                .frame(height: Self.scrollingListHeight)
            } else {
                missedQuestionButtons
            }
            HStack {
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

    private var missedQuestionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(summary.missedQuestions) { missedQuestion in
                VideoQuizMissedQuestionButton(missedQuestion: missedQuestion, accentColor: accentColor) {
                    goBackToTheMissedQuestion(missedQuestion)
                }
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

    /// True from the moment the Card starts to Glide in, so Escape closes it even before it lands.
    var isShowing: Bool { panel != nil }

    /// Shows the Card for `summary`, Gliding out of the video, or fading in with Reduce Motion on.
    func show(
        summary: VideoQuizSummary,
        videoRect: CGRect?,
        accentColor: Color,
        goBackToTheMissedQuestion: @escaping (VideoQuizMissedQuestion) -> Void
    ) {
        close(animated: false)
        let cardView = VideoQuizSummaryCardView(
            summary: summary,
            accentColor: accentColor,
            goBackToTheMissedQuestion: { [weak self] missedQuestion in
                self?.close(animated: true)
                goBackToTheMissedQuestion(missedQuestion)
            },
            close: { [weak self] in self?.close(animated: true) }
        )
        let hostingView = FirstMouseHostingView(rootView: cardView)
        let cardSize = hostingView.fittingSize
        let mouseLocation = NSEvent.mouseLocation
        let screen = videoRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        let cardFrame = videoQuizSummaryCardFrame(cardSize: cardSize, videoRect: videoRect, visibleFrame: screen.visibleFrame)
        let summaryPanel = NonKeyFloatingPanel(contentRect: cardFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        glideOrigin = videoQuizSummaryGlideOrigin(videoRect: videoRect, mouseLocation: mouseLocation)
        print("Video quiz summary: showing the Card at \(cardFrame.integral), \(videoRect == nil ? "with no video in front" : "over the quiz video")")

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
        // A Card still Gliding in lands at once, and the guard in its landing keeps the real panel from showing.
        glideInFlight?.landAtOnce()
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
