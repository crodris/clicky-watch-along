//
//  MenuBarAndDiscTests.swift
//  leanring-buddyTests
//
//  The Tether menu bar PR: the status icon's states and drawing, the disc's loops and "!" face, the peek card's content and
//  placement, the right-click menu's items, Bring back's route and plans, the tether that ends when a disc slides, and the
//  still ring a Reduce Motion serve leaves.
//

import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct MenuBarAndDiscTests {
    // MARK: - Status icon

    @Test func theIconSaysListeningWhileTheLearnerTalksAndThinkingWhileClickyThinksAndIdleOtherwise() {
        #expect(menuBarIconState(for: .idle) == .idle)
        #expect(menuBarIconState(for: .listening) == .listening)
        #expect(menuBarIconState(for: .processing) == .thinking)
        // The answer is audible, so speaking needs no icon of its own.
        #expect(menuBarIconState(for: .responding) == .idle)
    }

    /// The icon's alpha at a point in its 26 by 18 point canvas, y down, at 2x.
    private func alpha(of image: NSImage, atX x: CGFloat, y: CGFloat) throws -> CGFloat {
        let bitmap = try renderedBitmap(of: image)
        return bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.alphaComponent ?? 0
    }

    private func renderedBitmap(of image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(MenuBarIconArt.size.width * 2),
            pixelsHigh: Int(MenuBarIconArt.size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        // 2x: the bitmap has twice as many pixels as the icon has points.
        bitmap.size = MenuBarIconArt.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: MenuBarIconArt.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    @Test func everyStateIsATemplateImageOfTheSameWidth() {
        for state in [MenuBarIconState.idle, .listening, .thinking] {
            let image = MenuBarIconArt.image(for: state, cursor: .triangle)
            #expect(image.isTemplate)
            #expect(image.size == MenuBarIconArt.size)
        }
    }

    @Test func listeningAddsSoundWavesToTheRightOfTheCursorAndThinkingAddsADotAtTheTop() throws {
        // The outer sound wave passes (21.7, 9) in the canvas, past the idle cursor's right edge.
        let idle = MenuBarIconArt.image(for: .idle, cursor: .triangle)
        let listening = MenuBarIconArt.image(for: .listening, cursor: .triangle)
        #expect(try alpha(of: idle, atX: 21.5, y: 9) == 0)
        #expect(try alpha(of: listening, atX: 21.5, y: 9) > 0.5)

        // The dot starts at 12 o'clock, 7.6 points above the center, and a half turn later it is at the bottom.
        let thinkingAtTheTop = MenuBarIconArt.image(for: .thinking, thinkingFrame: 0, cursor: .triangle)
        let thinkingAtTheBottom = MenuBarIconArt.image(for: .thinking, thinkingFrame: MenuBarIconArt.thinkingFrameCount / 2, cursor: .triangle)
        #expect(try alpha(of: thinkingAtTheTop, atX: 13, y: 9 - 7.6) > 0.5)
        #expect(try alpha(of: thinkingAtTheTop, atX: 13, y: 9 + 7.6) == 0)
        #expect(try alpha(of: thinkingAtTheBottom, atX: 13, y: 9 + 7.6) > 0.5)
        #expect(try alpha(of: thinkingAtTheBottom, atX: 13, y: 9 - 7.6) == 0)
    }

    @Test func theApprovalBadgeIsAnAmberDotOnTheTopRightAndMakesTheIconAColoredImageNotATemplate() throws {
        let plain = MenuBarIconArt.image(for: .idle, cursor: .triangle)
        let badged = MenuBarIconArt.image(for: .idle, cursor: .triangle, badgeOnAForeground: .white)
        #expect(plain.isTemplate)
        #expect(!badged.isTemplate)
        let bitmap = try renderedBitmap(of: badged)
        let badgeCenter = MenuBarIconArt.badgeCenter
        let badgePixel = try #require(bitmap.colorAt(x: Int(badgeCenter.x * 2), y: Int(badgeCenter.y * 2)))
        // Amber is mostly red, some green, and little blue.
        #expect(badgePixel.alphaComponent > 0.9 && badgePixel.redComponent > 0.9 && badgePixel.greenComponent > 0.5 && badgePixel.blueComponent < 0.4)
        // The plain icon has nothing there, and the badge rides on top of any state.
        #expect(try alpha(of: plain, atX: badgeCenter.x, y: badgeCenter.y) == 0)
        let listeningBadged = MenuBarIconArt.image(for: .listening, cursor: .triangle, badgeOnAForeground: .white)
        let listeningPixel = try #require(try renderedBitmap(of: listeningBadged).colorAt(x: Int(badgeCenter.x * 2), y: Int(badgeCenter.y * 2)))
        #expect(listeningPixel.redComponent > 0.9 && listeningPixel.blueComponent < 0.4)
    }

    @Test func aThemesDrawnCursorBecomesASilhouetteWithItsOpenSeamsCutOut() throws {
        let volleyball = bundledTheme("school-karasuno").cursor
        let image = MenuBarIconArt.image(for: .idle, cursor: volleyball)
        // The ball fills the middle of the canvas, and a seam line crosses it, which the template cuts to nothing.
        #expect(try alpha(of: image, atX: 9, y: 9) > 0.9)
        let bitmap = try renderedBitmap(of: image)
        let transparentPixelsInsideTheBall = (14...24).flatMap { x in (10...24).map { y in (x, y) } }
            .filter { bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1 < 0.2 }
            .count
        let theSamePixelsOfASolidDisc = 0
        #expect(transparentPixelsInsideTheBall > theSamePixelsOfASolidDisc)
    }

    @Test func aPictureCursorFallsBackToTheTriangleInTheIcon() throws {
        let pictureCursor = CustomCursorDrawing.picture(CustomCursorPictureStyle(fit: .circle, outlineHex: "#FFFFFF", tintHex: nil, tintStrength: 0))
        let fromPicture = try renderedBitmap(of: MenuBarIconArt.image(for: .idle, cursor: pictureCursor))
        let fromTriangle = try renderedBitmap(of: MenuBarIconArt.image(for: .idle, cursor: .triangle))
        #expect(fromPicture.tiffRepresentation == fromTriangle.tiffRepresentation)
    }

    // MARK: - Disc

    @Test func aDiscWaitingForApprovalHasTheBangFaceInPlaceOfABadgeWhileFinishedAndFailedKeepTheirs() {
        #expect(agentTokenBadgeOnTheDisc(phase: .running(completedStepCount: 0), isWaitingForApproval: true) == nil)
        #expect(agentTokenBadgeOnTheDisc(phase: .finished(.readyScene), isWaitingForApproval: false) == .done)
        #expect(agentTokenBadgeOnTheDisc(phase: .failed(reason: "x"), isWaitingForApproval: false) == .failed)
        // The agent list's rows still draw the "!" badge.
        #expect(agentTokenBadge(phase: .running(completedStepCount: 0), isWaitingForApproval: true) == .needsYourOK)
    }

    private func loopLayer(of loop: AgentTokenLoop, reduceMotionIsOn: Bool) throws -> CALayer {
        let hostView = AgentTokenLoopHostView(loop: loop, reduceMotionIsOn: reduceMotionIsOn)
        return try #require(hostView.layer?.sublayers?.first)
    }

    @Test func aRunningDiscsDotTurnsClockwiseEvery3SecondsAndBreathesInPlaceWithReduceMotion() throws {
        let turningLayer = try loopLayer(of: .orbitingDot, reduceMotionIsOn: false)
        let turn = try #require(turningLayer.animation(forKey: "dot.turn") as? CABasicAnimation)
        #expect(turn.duration == 3)
        #expect(turn.repeatCount == .infinity)
        // Layer y grows upward, so a negative turn is clockwise.
        #expect((turn.toValue as? Double ?? 0) < 0)

        let stillLayer = try loopLayer(of: .orbitingDot, reduceMotionIsOn: true)
        #expect(stillLayer.animation(forKey: "dot.turn") == nil)
        let dotLayer = try #require(stillLayer.sublayers?.first)
        #expect(dotLayer.animation(forKey: "dot.breathing") != nil)
    }

    @Test func aWaitingDiscPulsesEvery1Point6SecondsAndIsAStillHaloWithReduceMotion() throws {
        let pulsingLayer = try #require(try loopLayer(of: .approvalPulse, reduceMotionIsOn: false).sublayers?.first)
        let pulse = try #require(pulsingLayer.animation(forKey: "pulse") as? CAAnimationGroup)
        #expect(pulse.duration == 1.6)
        #expect(pulse.repeatCount == .infinity)

        let haloLayer = try #require(try loopLayer(of: .approvalPulse, reduceMotionIsOn: true).sublayers?.first)
        #expect(haloLayer.animation(forKey: "pulse") == nil)
        #expect(haloLayer.opacity == AgentTokenLoop.reducedMotionPulseOpacity)
    }

    // MARK: - Reduce Motion serve

    private func renderedPixels(of view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.padding(20).background(Color.white))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    @Test func aDiscWithAStillRingDrawsItJustOutsideTheDiscAndOneWithoutDoesNot() throws {
        let store = makeBackgroundAgentStore()
        func disc(stillRingColor: Color?) -> some View {
            let discModel = AgentTokenDiscModel()
            discModel.stillRingColor = stillRingColor
            return AgentTokenDiscContent(store: store, discModel: discModel, tokenSlot: .overflow, overflowCount: 2)
                .frame(width: AgentTokenMetrics.panelWidth, height: 40)
        }
        let withRing = try renderedPixels(of: disc(stillRingColor: Color(hex: "#FF00FF")))
        let withoutRing = try renderedPixels(of: disc(stillRingColor: nil))
        // The panel is 28 wide and starts 20 points in, so its center is at x = 34, and the ring's radius is 13.
        let ringPixelX = Int((20 + AgentTokenMetrics.panelWidth / 2 - 13) * 2)
        let centerY = Int((20 + 20) * 2)
        let ringPixel = try #require(withRing.colorAt(x: ringPixelX, y: centerY))
        let sameSpotWithoutIt = try #require(withoutRing.colorAt(x: ringPixelX, y: centerY))
        #expect(ringPixel.redComponent > 0.8 && ringPixel.greenComponent < 0.4 && ringPixel.blueComponent > 0.8)
        #expect(sameSpotWithoutIt.greenComponent > 0.7)
    }

    // MARK: - Peek

    private func runningAgent(kind: BackgroundAgentKind = .experiment, subject: String? = "Trebuchet", secondsAgo: TimeInterval = 42) -> BackgroundAgent {
        let startedAt = Date(timeIntervalSinceNow: -secondsAgo)
        return BackgroundAgent(
            id: UUID(), kind: kind, subject: subject, studyGuideVideoKey: nil, startedAt: startedAt,
            currentStepStartedAt: startedAt, endedAt: nil, phase: .running(completedStepCount: 1)
        )
    }

    @Test func aRunningAgentsPeekNamesItsCurrentStepAndHowLongItHasRunWithAMeterOfItsSteps() {
        let agent = runningAgent()
        let content = agentTokenPeekContent(for: agent, approvalCapability: nil, isWaitingForApproval: false, at: Date())
        #expect(content.title == "Experiment · Trebuchet")
        #expect(content.caption == "Build the experiment · 0:42")
        #expect(content.meter == AgentTokenPeekMeter(stepCount: 2, litStepCount: 2))
        #expect(content.hint == nil)
    }

    @Test func aWaitingAgentsPeekNamesOnlyTheCapabilityNeverTheRequestsSummary() {
        let agent = runningAgent(kind: .task, subject: "Booster catch")
        let capabilities: [(HarnessCapability, String)] = [
            (.sends, "Needs your OK to send something"),
            (.deletes, "Needs your OK to delete something"),
            (.spends, "Needs your OK to spend something"),
            (.readsPrivate, "Needs your OK to read private data"),
            (.unknown("made_up"), "Needs your OK"),
        ]
        for (capability, expectedCaption) in capabilities {
            let content = agentTokenPeekContent(for: agent, approvalCapability: capability, isWaitingForApproval: true, at: Date())
            #expect(content.caption == expectedCaption)
            #expect(content.captionStyle == .needsYourOK)
            #expect(content.hint == "Click to review, or say yes or no")
        }
        // An agent whose request has gone is a running agent again.
        #expect(agentTokenPeekContent(for: agent, approvalCapability: nil, isWaitingForApproval: false, at: Date()).captionStyle == .plain)
    }

    @Test func aFinishedAgentsPeekSaysWhatToSayAndAFailedAgentsReasonIsCut() {
        var finishedModel = runningAgent(kind: .threeDModel, subject: nil)
        finishedModel.phase = .finished(.readyScene)
        finishedModel.resultIsWaitingToBeDelivered = true
        #expect(agentTokenPeekContent(for: finishedModel, approvalCapability: nil, isWaitingForApproval: false, at: Date()).caption == "Ready · say \"show the model\"")

        var failedAgent = runningAgent()
        failedAgent.phase = .failed(reason: String(repeating: "x", count: 200))
        let failedContent = agentTokenPeekContent(for: failedAgent, approvalCapability: nil, isWaitingForApproval: false, at: Date())
        #expect(failedContent.captionStyle == .failed)
        #expect(failedContent.hint?.count == agentTokenPeekLongestReason + 1)
    }

    @Test func thePlusDiscsPeekCountsItsAgents() {
        #expect(agentTokenOverflowPeekContent(overflowCount: 2).title == "2 more agents")
        #expect(agentTokenOverflowPeekContent(overflowCount: 1).title == "1 more agent")
    }

    @Test func thePeekCardSitsEightPointsBelowTheBarCenteredOnTheDiscAndStaysOnTheDisplay() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let discPanel = CGRect(x: 800, y: 982 - 37, width: 28, height: 37)
        let centered = agentTokenPeekCardFrame(cardHeight: 70, discPanelFrame: discPanel, screenFrame: screenFrame)
        #expect(centered.midX == discPanel.midX)
        #expect(centered.maxY == discPanel.minY - 8)
        #expect(centered.height == 70)
        // A disc near the right edge pushes the card back onto the display, 8 points in.
        let nearTheEdge = agentTokenPeekCardFrame(cardHeight: 70, discPanelFrame: CGRect(x: 1500, y: 945, width: 28, height: 37), screenFrame: screenFrame)
        #expect(nearTheEdge.maxX == screenFrame.maxX - 8)
    }

    // MARK: - Right-click menu

    @Test func aDiscsMenuOffersWhatItsListRowOffersInOrderWithCancelLast() {
        var waitingModel = runningAgent(kind: .experiment)
        waitingModel.phase = .finished(.readyScene)
        waitingModel.resultIsWaitingToBeDelivered = true
        #expect(agentDiscMenuItems(for: waitingModel, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.showReadyScene(title: "Show experiment")])
        // A quiz question holds a waiting result, as the list's own button is held.
        #expect(agentDiscMenuItems(for: waitingModel, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: true) == [.openAgentList])

        var heardLater = runningAgent(kind: .task)
        heardLater.phase = .finished(.answer(spokenSummary: "x", pageURL: URL(string: "https://www.notion.so/page")))
        heardLater.resultIsWaitingToBeDelivered = true
        #expect(agentDiscMenuItems(for: heardLater, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.hearAnswer, .openPage])

        let running = runningAgent(kind: .task)
        #expect(agentDiscMenuItems(for: running, isWaitingForApproval: true, aVideoQuizQuestionIsOpen: false) == [.reviewRequest, .cancelAgent])
        #expect(agentDiscMenuItems(for: running, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.cancelAgent])
    }

    @Test func thePlusDiscAndAnAgentWithNothingToOfferOpenTheAgentList() {
        #expect(agentDiscMenuItems(for: nil, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.openAgentList])
        var failedAgent = runningAgent()
        failedAgent.phase = .failed(reason: "x")
        #expect(agentDiscMenuItems(for: failedAgent, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.openAgentList])
    }

    // MARK: - Bring back

    private let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let discCenter = CGPoint(x: 860, y: 982 - 17)

    @Test func theSparkRunsFromTheDiscAlongTheTopEdgeThenDropsToTheCursorAndNeverCrossesTheScreenUnderTheEdgeRun() {
        let cursorPoint = CGPoint(x: 500, y: 420)
        let path = agentTokenBringBackPath(from: discCenter, to: cursorPoint, onScreenWithFrame: screenFrame)
        #expect(path.point(atFlightProgress: 0) == discCenter)
        #expect(path.point(atFlightProgress: 1) == cursorPoint)
        // Through the run along the edge, the spark stays at or above the disc's height, on the bar. Only the drop after it
        // reaches down to the cursor.
        for sampleIndex in 0...20 {
            let flightProgress = Double(sampleIndex) / 20
            let easedProgress = DS.Move.bringBack.curve.progress(atSeconds: flightProgress * AgentTokenBringBackPath.flightSeconds)
            let point = path.point(atFlightProgress: flightProgress)
            if easedProgress <= AgentTokenBringBackPath.shareOfTheMoveAlongTheEdge {
                #expect(point.y >= discCenter.y - 0.001)
            }
            #expect(screenFrame.contains(point))
        }
    }

    @Test func theElbowGoesToTheRightOfTheCursorWhenThereIsRoomAndToTheLeftWhenThereIsNot() {
        let roomOnTheRight = agentTokenBringBackPath(from: discCenter, to: CGPoint(x: 500, y: 420), onScreenWithFrame: screenFrame)
        #expect(roomOnTheRight.elbow.x == 600)
        let noRoomOnTheRight = agentTokenBringBackPath(from: discCenter, to: CGPoint(x: 1450, y: 420), onScreenWithFrame: screenFrame)
        #expect(noRoomOnTheRight.elbow.x == 1350)
        let nearTheLeftEdge = agentTokenBringBackPath(from: discCenter, to: CGPoint(x: 1480, y: 420), onScreenWithFrame: CGRect(x: 1400, y: 0, width: 112, height: 982))
        #expect(nearTheLeftEdge.elbow.x == 1400 + AgentTokenBringBackPath.sideMargin)
    }

    @Test func aBringBackPlanMovesInHalfASecondAndAHalfWithATetherThatTracesTheRoute() {
        let path = agentTokenBringBackPath(from: discCenter, to: CGPoint(x: 500, y: 420), onScreenWithFrame: screenFrame)
        let plan = CarrierFlightPlan.bringBack(along: path, sparkSize: CGSize(width: 16, height: 16))
        #expect(plan.seconds == 0.6)
        #expect(plan.poses.first?.pivot == discCenter)
        #expect(plan.poses.last?.pivot == CGPoint(x: 500, y: 420))
        #expect(plan.tetherOrigin == discCenter)
        #expect(plan.tetherFollowsThePath)
        #expect(plan.restingFrame == CGRect(x: 492, y: 412, width: 16, height: 16))
        #expect(plan.poses.allSatisfy { $0.scale == 1 && $0.opacity == 1 })
    }

    @Test func theReduceMotionBringBackFadesARingInAtTheCursorWithNoTravelAndNoTether() throws {
        let cursorPoint = CGPoint(x: 500, y: 420)
        let plan = CarrierFlightPlan.bringBackWithReduceMotion(at: cursorPoint, ringSize: CGSize(width: 24, height: 24))
        #expect(plan.seconds == DS.Move.bringBack.reduceMotionForm.fadeSeconds + CarrierFlightPlan.secondsTheStillRingHolds)
        #expect(plan.poses.allSatisfy { $0.pivot == cursorPoint && $0.scale == 1 })
        #expect(plan.poses.first?.opacity == 0)
        #expect(plan.poses.last?.opacity == 1)
        #expect(plan.tetherOrigin == nil)
        #expect(!plan.tetherFollowsThePath)
        // Fully in by the end of the fade, and held there.
        let heldPoses = plan.poses.filter { _ in true }.suffix(10)
        #expect(heldPoses.allSatisfy { $0.opacity == 1 })
    }

    @Test func theTrailTetherRevealsByTheShareOfTheRouteTheSparkHasCovered() {
        let pivots = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 10)]
        let covered = carrierTrailLengthsCovered(by: pivots)
        #expect(covered == [0, 5, 11])
    }

    // MARK: - Tether that ends when a disc slides

    @Test func endingTheTetherTakesItOffTheScreenBeforeItsOwnFadeWouldHave() throws {
        let screen = try #require(NSScreen.screens.first)
        let slotPoint = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 17)
        let path = agentTokenServePath(from: CGPoint(x: screen.frame.midX - 300, y: screen.frame.midY), to: slotPoint)
        let flight = TetherCarrier.shared.play(
            .send(along: path, carriedSize: CGSize(width: 28, height: 28)),
            carrying: Color.clear,
            onDisplay: screen.displayID,
            tetherColor: .white,
            onLanded: {}
        )
        #expect(flight.tetherIsShowing)
        flight.endTheTetherNow()
        #expect(!flight.tetherIsShowing)
        flight.landAtOnce()
    }

    @Test func theStillRingOfAReduceMotionServeStaysForASecond() {
        #expect(agentTokenServeStillRingSeconds == 1)
    }
}
