//
//  VideoQuizSummaryPanel.swift
//  leanring-buddy
//
//  The Card at the end of a video quiz or a video, printed on paper since the learner keeps it (`paperCard()`): the score,
//  each question to look at again (a button that goes back to it), what the learner learned, and the study guide link.
//  The questions and the learned lines scroll inside the room the display leaves, and the footer always shows.
//  At the end of a quiz it Glides out of the video; at the end of a video it Glides out of the cursor, after the agent
//  discs gather there. It closes back into where it came from on the shared carrier, and shows in a full-screen space too.
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

/// Where the summary Card may reach in height on a display: the display's visible frame less the window's shadow margins and a
/// gap of 12 points on each side (the space `videoQuizSummaryCardFrame` keeps from the edge). The Card scrolls its body inside
/// this and keeps its footer on screen. It never goes under `VideoQuizSummaryCardLayout.leastCardHeight`.
func videoQuizSummaryCardHeightBudget(visibleFrame: CGRect) -> CGFloat {
    max(visibleFrame.height - AgentListWindowMargins.vertical - 2 * videoQuizSummaryCardGapFromTheScreenEdge, VideoQuizSummaryCardLayout.leastCardHeight)
}

/// The space between the Card and the edge of the display's visible frame.
let videoQuizSummaryCardGapFromTheScreenEdge: CGFloat = 12

/// Lays the Card out as three parts, each given the width: a header and a footer, which always show whole, and a body that takes
/// the room left under `maxHeight`, and is as tall as its content when that fits, so a short list leaves no blank paper. The
/// body is a scroll view, so its content scrolls once it is taller than the room. The first subview is the header, the last is
/// the footer, and a subview between them, when there is one, is the body.
struct VideoQuizSummaryCardLayout: Layout {
    /// The tallest the three parts may be together, in points.
    let maxHeight: CGFloat

    /// The least height the body keeps, so a header and footer taller than the budget still leave a visible list.
    static let leastBodyHeight: CGFloat = 96
    /// The least a Card is given, with its padding, whatever the display's height.
    static let leastCardHeight: CGFloat = 320

    private struct PartHeights {
        let header: CGFloat
        let body: CGFloat
        let footer: CGFloat
        var total: CGFloat { header + body + footer }
    }

    private func partHeights(width: CGFloat, subviews: Subviews) -> PartHeights {
        let widthOnly = ProposedViewSize(width: width, height: nil)
        guard subviews.count >= 2, let header = subviews.first, let footer = subviews.last else {
            return PartHeights(header: subviews.first?.sizeThatFits(widthOnly).height ?? 0, body: 0, footer: 0)
        }
        let headerHeight = header.sizeThatFits(widthOnly).height
        let footerHeight = footer.sizeThatFits(widthOnly).height
        guard subviews.count == 3 else { return PartHeights(header: headerHeight, body: 0, footer: footerHeight) }
        let bodyContentHeight = subviews[1].sizeThatFits(widthOnly).height
        let roomForTheBody = max(maxHeight - headerHeight - footerHeight, Self.leastBodyHeight)
        return PartHeights(header: headerHeight, body: min(bodyContentHeight, roomForTheBody), footer: footerHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: partHeights(width: width, subviews: subviews).total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = partHeights(width: bounds.width, subviews: subviews)
        var partTop = bounds.minY
        func place(_ subview: LayoutSubview, height: CGFloat) {
            subview.place(at: CGPoint(x: bounds.minX, y: partTop), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            partTop += height
        }
        guard subviews.count >= 2, let header = subviews.first, let footer = subviews.last else {
            if let onlyPart = subviews.first { place(onlyPart, height: heights.header) }
            return
        }
        place(header, height: heights.header)
        if subviews.count == 3 { place(subviews[1], height: heights.body) }
        place(footer, height: heights.footer)
    }
}

/// The recap printed on paper (`paperCard()`), since it is what the learner keeps: a kicker, a serif title, the score on a flat
/// highlight in the theme's accent, the questions to go back to, what the learner learned, and a colophon with the time the
/// Card was made beside the buttons. The questions and the learned lines scroll when the Card would pass `heightBudget`, and
/// the header and the footer never do, so Close and Study guide stay on the display.
struct VideoQuizSummaryCardView: View {
    static let cardWidth: CGFloat = 360
    private static let padding = EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20)
    /// How far a missed question's hover wash reaches past the text on each side. The scroll view keeps room for it.
    private static let rowHoverOutset: CGFloat = 6

    let recap: VideoRecap
    let moment: VideoRecapMoment
    let accentColor: Color
    /// When the Card was made, for its colophon. The panel makes the Card once and carries the same value on and off the screen.
    var madeAt = Date()
    /// The tallest the Card may be, padding included. The panel passes what fits the display it shows on.
    var heightBudget: CGFloat = .infinity
    let goBackToTheMissedQuestion: (VideoQuizMissedQuestion) -> Void
    let openTheStudyGuide: () -> Void
    let close: () -> Void

    private var bodyHasContent: Bool { !(recap.summary?.missedQuestions.isEmpty ?? true) || !recap.learnedLines.isEmpty }

    var body: some View {
        VideoQuizSummaryCardLayout(maxHeight: heightBudget - Self.padding.top - Self.padding.bottom) {
            header
            if bodyHasContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // The missed questions come first, since they are what the learner can act on.
                        if let summary = recap.summary, !summary.missedQuestions.isEmpty {
                            section("Review these first") {
                                missedQuestionButtons(of: summary)
                            }
                        }
                        if !recap.learnedLines.isEmpty {
                            section("What you learned") {
                                learnedLines
                            }
                        }
                    }
                    // Room inside the scroll view for a row's hover wash, which reaches past the text, so the scroll view's
                    // edge never cuts it.
                    .padding(.horizontal, Self.rowHoverOutset)
                }
                .padding(.horizontal, -Self.rowHoverOutset)
            }
            footer
        }
        .padding(Self.padding)
        .frame(width: Self.cardWidth, alignment: .leading)
        .paperCard()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(recap.kicker(when: moment))
                .font(DS.TypeScale.caption.font.weight(.semibold))
                .foregroundStyle(DS.Colors.paperInkTertiary)
            Text(recap.title(when: moment))
                .font(DS.PaperType.title.font)
                .foregroundStyle(DS.Colors.paperInk)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            if let summary = recap.summary {
                VStack(alignment: .leading, spacing: 6) {
                    PaperHighlight(text: summary.scoreText, accent: accentColor)
                    Text(summary.captionText)
                        .font(DS.TypeScale.body.font)
                        .foregroundStyle(DS.Colors.paperInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A section: a hairline rule, its italic serif label, and its content.
    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PaperRule()
            Text(label)
                .font(DS.PaperType.sectionLabel.font)
                .foregroundStyle(DS.Colors.paperInkSecondary)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, 14)
    }

    private var learnedLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(recap.learnedLines.enumerated()), id: \.offset) { learnedLineIndex, learnedLine in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: "\(learnedLineIndex + 1)")
                        .font(DS.PaperType.numeral.font)
                        .foregroundStyle(DS.Colors.paperInkTertiary)
                        .frame(width: 18, alignment: .leading)
                    Text(learnedLine)
                        .font(DS.TypeScale.body.font)
                        .foregroundStyle(DS.Colors.paperInk)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The colophon on the left and the buttons on the right, or the buttons under the colophon when they do not fit side by side.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaperRule()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    colophon
                    Spacer(minLength: 10)
                    buttons
                }
                VStack(alignment: .trailing, spacing: 10) {
                    colophon.frame(maxWidth: .infinity, alignment: .leading)
                    buttons
                }
            }
            .padding(.top, 12)
        }
        .padding(.top, 14)
    }

    private var colophon: some View {
        Text(verbatim: videoRecapColophonText(madeAt: madeAt))
            .font(DS.TypeScale.data.font.weight(.medium))
            .foregroundStyle(DS.Colors.paperInkTertiary)
            .lineLimit(1)
            .fixedSize()
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            TetherButton("Close", role: .paperOutline, shape: .capsule, size: .prominent, action: close)
            if recap.studyGuideURL != nil {
                TetherButton("Study guide", role: .paperFilled, shape: .capsule, size: .prominent, action: openTheStudyGuide)
            }
        }
    }

    private func missedQuestionButtons(of summary: VideoQuizSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(summary.missedQuestions) { missedQuestion in
                VideoQuizMissedQuestionButton(missedQuestion: missedQuestion) {
                    goBackToTheMissedQuestion(missedQuestion)
                }
            }
        }
    }
}

/// A question to look at again: a go-back arrow, the question, and its timestamp in a monospaced column. A click takes the
/// learner back to it, and the row says so with a wash and the pointing hand.
private struct VideoQuizMissedQuestionButton: View {
    let missedQuestion: VideoQuizMissedQuestion
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(DS.glyphFont(pointSize: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.paperInkSecondary)
                    .accessibilityHidden(true)
                Text(missedQuestion.question)
                    .font(DS.TypeScale.title.font)
                    .foregroundStyle(DS.Colors.paperInk)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: missedQuestion.timestampText)
                    .font(DS.TypeScale.data.font.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.paperInkSecondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.chip, style: .continuous)
                    .fill(isHovered ? DS.Colors.paperWash : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The row's text lines up with the rest of the Card, so its own padding hangs out into the Card's.
        .padding(.horizontal, -6)
        .accessibilityLabel("\(missedQuestion.question), at \(missedQuestion.timestampText)")
        .accessibilityHint("Goes back to this question")
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
    /// Readable by a test, which checks the window's frame and its mouse state.
    private(set) var panel: NonKeyFloatingPanel?
    /// Lets the mouse pass through the window's shadow margin to the page under it (`ShadowMarginMousePassThrough`).
    private var shadowMarginMouse: ShadowMarginMousePassThrough?
    /// Where the pointer is on screen. A test sets it, since the real pointer is wherever the learner left it.
    var mouseLocationOnScreen: () -> CGPoint = { NSEvent.mouseLocation } {
        didSet { shadowMarginMouse?.mouseLocationOnScreen = mouseLocationOnScreen }
    }
    /// A test sets this to put the Card in a frame far off every screen, with no screen to Glide on, so no one sees it.
    var visibleFrameForTests: CGRect?
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
        let mouseLocation = NSEvent.mouseLocation
        let screen = visibleFrameForTests != nil ? nil : videoRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let visibleFrame = visibleFrameForTests ?? screen?.visibleFrame else { return }
        let cardView = VideoQuizSummaryCardView(
            recap: recap,
            moment: moment,
            accentColor: accentColor,
            // A recap taller than the display scrolls its body, so Close and Study guide stay inside the visible frame.
            heightBudget: videoQuizSummaryCardHeightBudget(visibleFrame: visibleFrame),
            goBackToTheMissedQuestion:{ [weak self] missedQuestion in
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
        let cardFrame = videoQuizSummaryCardFrame(cardSize: cardSize, videoRect: videoRect, visibleFrame: visibleFrame)
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
            glideOrigin = videoRecapGlideOrigin(cursorPoint: cursorPoint, cardScreenFrame: screen?.frame ?? visibleFrame, videoRect: videoRect, mouseLocation: mouseLocation)
        }
        print("Video quiz summary: showing the Card at \(cardFrame.integral) after \(moment == .videoEnded ? "the video ended" : "the quiz ended"), \(videoRect == nil ? "with no video in front" : "over the video")")

        let mousePassThrough = ShadowMarginMousePassThrough(panel: summaryPanel, mouseLocationOnScreen: mouseLocationOnScreen)
        mousePassThrough.start()
        shadowMarginMouse = mousePassThrough

        // With no screen to Glide on, the Card fades in place.
        guard let screen, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
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
        shadowMarginMouse?.stop()
        shadowMarginMouse = nil
        // The Card fades or Glides for a moment, and a click on it then must not reach its buttons.
        closingPanel.ignoresMouseEvents = true
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
