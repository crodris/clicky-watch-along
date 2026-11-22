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
    private func alpha(of image: NSImage, atX pointX: CGFloat, y pointY: CGFloat) throws -> CGFloat {
        let bitmap = try renderedBitmap(of: image)
        return bitmap.colorAt(x: Int(pointX * 2), y: Int(pointY * 2))?.alphaComponent ?? 0
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
        let badged = MenuBarIconArt.image(for: .idle, cursor: .triangle, badge: .needsYourOK, foreground: .white)
        #expect(plain.isTemplate)
        #expect(!badged.isTemplate)
        let bitmap = try renderedBitmap(of: badged)
        let badgeCenter = MenuBarIconArt.badgeCenter
        let badgePixel = try #require(bitmap.colorAt(x: Int(badgeCenter.x * 2), y: Int(badgeCenter.y * 2)))
        // Amber is mostly red, some green, and little blue.
        #expect(badgePixel.alphaComponent > 0.9 && badgePixel.redComponent > 0.9 && badgePixel.greenComponent > 0.5 && badgePixel.blueComponent < 0.4)
        // The plain icon has nothing there, and the badge draws over any state.
        #expect(try alpha(of: plain, atX: badgeCenter.x, y: badgeCenter.y) == 0)
        let listeningBadged = MenuBarIconArt.image(for: .listening, cursor: .triangle, badge: .needsYourOK, foreground: .white)
        let listeningPixel = try #require(try renderedBitmap(of: listeningBadged).colorAt(x: Int(badgeCenter.x * 2), y: Int(badgeCenter.y * 2)))
        #expect(listeningPixel.redComponent > 0.9 && listeningPixel.blueComponent < 0.4)
    }

    @Test func theIconGetsARedBadgeForAPermissionOffAfterSetupOrAnOfflineWorkerAndAmberWinsOverIt() {
        func badge(approval: Bool = false, setupIsFinished: Bool = true, permissionOff: Bool = false, offline: Bool = false) -> MenuBarIconBadge? {
            menuBarIconBadge(approvalIsWaiting: approval, setupIsFinished: setupIsFinished, aRequiredPermissionIsOff: permissionOff, workerIsUnreachable: offline)
        }
        #expect(badge() == nil)
        #expect(badge(permissionOff: true) == .problem)
        #expect(badge(offline: true) == .problem)
        // During setup the checklist lists a permission that is off, so the icon says nothing about it yet.
        #expect(badge(setupIsFinished: false, permissionOff: true) == nil)
        #expect(badge(setupIsFinished: false, offline: true) == .problem)
        // The panel's banner shows the approval card first, and the icon follows the same order.
        #expect(badge(approval: true, permissionOff: true, offline: true) == .needsYourOK)
    }

    @Test func theProblemBadgeIsARedDotWhereTheAmberOneSits() throws {
        let problemIcon = MenuBarIconArt.image(for: .idle, cursor: .triangle, badge: .problem, foreground: .white)
        #expect(!problemIcon.isTemplate)
        let badgeCenter = MenuBarIconArt.badgeCenter
        let badgePixel = try #require(try renderedBitmap(of: problemIcon).colorAt(x: Int(badgeCenter.x * 2), y: Int(badgeCenter.y * 2)))
        // Red: much red, little green and blue, unlike the amber badge's green above 0.5.
        #expect(badgePixel.alphaComponent > 0.9 && badgePixel.redComponent > 0.8 && badgePixel.greenComponent < 0.45 && badgePixel.blueComponent < 0.45)
    }

    @Test func aThemesDrawnCursorBecomesASilhouetteWithItsOpenSeamsCutOut() throws {
        let volleyball = bundledTheme("school-karasuno").cursor
        let image = MenuBarIconArt.image(for: .idle, cursor: volleyball)
        // The ball fills the middle of the canvas, and a seam line crosses it, which the template cuts to nothing.
        #expect(try alpha(of: image, atX: 9, y: 9) > 0.9)
        let bitmap = try renderedBitmap(of: image)
        let transparentPixelsInsideTheBall = (14...24).flatMap { pixelColumn in (10...24).map { pixelRow in (column: pixelColumn, row: pixelRow) } }
            .filter { bitmap.colorAt(x: $0.column, y: $0.row)?.alphaComponent ?? 1 < 0.2 }
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

    @Test func aSettledRequestTurnsTheDiscsFaceIntoACheckOrAGrayDashAt2x() throws {
        // A running disc's orbiting dot is an AppKit layer, which `ImageRenderer` does not draw, so a cancelled agent with no
        // loop and no badge stands in for it.
        var agent = runningAgent(kind: .task)
        agent.phase = .cancelled
        // Points from the disc's center, which is the render's center, since the padding is the same on every side.
        func pixel(_ mark: AgentTokenApprovalSettledMark, pointsRightOfTheCenter x: CGFloat, pointsBelowTheCenter y: CGFloat) throws -> NSColor {
            let pixels = try renderedPixels(of: AgentTokenDiscView(agent: agent, approvalSettledMark: mark).frame(width: AgentTokenMetrics.discDiameter, height: AgentTokenMetrics.discDiameter))
            return try #require(pixels.colorAt(x: pixels.pixelsWide / 2 + Int(x * 2), y: pixels.pixelsHigh / 2 + Int(y * 2))?.usingColorSpace(.sRGB))
        }
        // The check's face is green near its top edge, above the white check.
        let checkFace = try pixel(.allowed, pointsRightOfTheCenter: 0, pointsBelowTheCenter: -6)
        #expect(checkFace.greenComponent > 0.5 && checkFace.greenComponent > checkFace.redComponent && checkFace.greenComponent > checkFace.blueComponent)
        // The dash sits across the dark face's center in a mid gray, and the face above it stays dark.
        let dash = try pixel(.notAllowed, pointsRightOfTheCenter: 0, pointsBelowTheCenter: 0)
        #expect(abs(dash.redComponent - dash.greenComponent) < 0.1 && dash.brightnessComponent > 0.3)
        let faceAboveTheDash = try pixel(.notAllowed, pointsRightOfTheCenter: 0, pointsBelowTheCenter: -5)
        #expect(faceAboveTheDash.brightnessComponent < 0.3)
    }

    @Test func aPausedAgentsChipSaysItIsPausedAndHowToLetItGoOn() {
        var agent = runningAgent()
        let pausedAt = Date()
        agent.pausedAt = pausedAt
        let content = agentTokenPeekContent(for: agent, approvalCapability: nil, isWaitingForApproval: false, at: pausedAt)
        #expect(content.caption.hasPrefix("Paused · Build the experiment · "))
        #expect(content.hint == "Say go ahead to let it go on")
        // VoiceOver reads the chip from the same lines.
        #expect(agentDiscAccessibilityLabel(agentName: agent.displayName, peekContent: content).contains("Paused"))
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

    @Test func theMenuHoldsAWaitingResultWhileAQuizQuestionOpensAfterTheMenuShowed() {
        var aQuizQuestionIsOpen = false
        var showedTheScene = 0
        var heardTheAnswer = 0
        var cancelledAgentIDs: [UUID] = []
        let menuActions = AgentDiscMenuActions.holdingAWaitingResultDuringAQuizQuestion(
            aVideoQuizQuestionIsOpen: { aQuizQuestionIsOpen },
            cancelAgent: { cancelledAgentIDs.append($0) },
            showReadyScene: { showedTheScene += 1 },
            hearTaskAnswer: { heardTheAnswer += 1 },
            tryAgain: { _ in }
        )
        // The menu was built with no question open, and a question opened before the click.
        aQuizQuestionIsOpen = true
        menuActions.showReadyScene()
        menuActions.hearTaskAnswer()
        #expect(showedTheScene == 0 && heardTheAnswer == 0)
        // Cancel is never held.
        let agentID = UUID()
        menuActions.cancelAgent(agentID)
        #expect(cancelledAgentIDs == [agentID])
        aQuizQuestionIsOpen = false
        menuActions.showReadyScene()
        menuActions.hearTaskAnswer()
        #expect(showedTheScene == 1 && heardTheAnswer == 1)
    }

    @Test func aFailedAgentThatMayBeTriedAgainOffersTryAgainUntilItWasTried() {
        var failedAgent = runningAgent(kind: .task)
        failedAgent.phase = .failed(reason: "x")
        failedAgent.canBeTriedAgain = true
        #expect(agentDiscMenuItems(for: failedAgent, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.tryAgain])
        #expect(AgentDiscMenuItem.tryAgain.title == "Try again")
        // Once the work started again, the store clears the flag (`markTriedAgain`), and the item goes.
        var triedAgain = failedAgent
        triedAgain.canBeTriedAgain = false
        #expect(agentDiscMenuItems(for: triedAgain, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.openAgentList])
        // A cancelled agent never offers it, even with the flag left on.
        var cancelledAgent = failedAgent
        cancelledAgent.phase = .cancelled
        #expect(agentDiscMenuItems(for: cancelledAgent, isWaitingForApproval: false, aVideoQuizQuestionIsOpen: false) == [.openAgentList])
    }

    // MARK: - The press

    @Test func aPressEndsTheRecapGatherThenLandsTheFlightsThenRecallsTheChip() throws {
        let pressSteps = PushToTalkPressStep.allCases
        let recapGatherEnds = try #require(pressSteps.firstIndex(of: .endTheRecapGather))
        let flightsLand = try #require(pressSteps.firstIndex(of: .landTheFlights))
        let chipIsRecalled = try #require(pressSteps.firstIndex(of: .recallTheChip))
        // The gather knows it was cancelled before its flights land, so the Card does not unfold over the new request.
        #expect(recapGatherEnds < flightsLand)
        // A Bring back spark lands and shows its chip before the Recall shrinks it into the cursor.
        #expect(flightsLand < chipIsRecalled)
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

    @Test func theDropComesDownBesideTheVideoAndTurnsInToTheCursorOnlyAtItsEnd() {
        // A video under the menu bar with the cursor on it, whose default elbow 100 points right would drop through it.
        let videoRect = CGRect(x: 300, y: 300, width: 640, height: 360)
        let cursorPoint = CGPoint(x: 700, y: 420)
        let path = agentTokenBringBackPath(from: discCenter, to: cursorPoint, onScreenWithFrame: screenFrame, keepingClearOf: videoRect)
        // The nearer side is the right one, 240 points away against 400.
        #expect(path.elbow.x == videoRect.maxX + AgentTokenBringBackPath.sideMargin)
        // Until it is halfway down from the video's top to the cursor, the spark stays outside the video, and only then turns in.
        for sampleIndex in 0...60 {
            let point = path.point(atFlightProgress: Double(sampleIndex) / 60)
            if point.y > cursorPoint.y + (videoRect.maxY - cursorPoint.y) / 2 { #expect(!videoRect.contains(point)) }
        }
    }

    @Test func theElbowStaysWhereItWasWhenTheVideoIsNotInTheWayOrFillsTheScreensWidth() {
        let cursorPoint = CGPoint(x: 500, y: 420)
        // A video below the cursor, or off to the side, is not in the drop's way.
        #expect(agentTokenBringBackPath(from: discCenter, to: cursorPoint, onScreenWithFrame: screenFrame, keepingClearOf: CGRect(x: 400, y: 0, width: 400, height: 300)).elbow.x == 600)
        #expect(agentTokenBringBackPath(from: discCenter, to: cursorPoint, onScreenWithFrame: screenFrame, keepingClearOf: CGRect(x: 800, y: 300, width: 400, height: 400)).elbow.x == 600)
        // A video as wide as the screen has no side to come down beside.
        #expect(agentTokenBringBackPath(from: discCenter, to: cursorPoint, onScreenWithFrame: screenFrame, keepingClearOf: CGRect(x: 0, y: 300, width: 1512, height: 400)).elbow.x == 600)
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

    @Test func theStillRingFitsAMenuBarOf24PointsAndAFullSizeOneAtTheDiscsPanelWidth() throws {
        // A 24 point bar, as a display with no notch has, is only 2 points taller than the disc.
        #expect(agentTokenStillRingDiameter(panelHeight: 24) == 22.5)
        #expect(agentTokenStillRingDiameter(panelHeight: 37) == AgentTokenMetrics.panelWidth - 2)

        let store = makeBackgroundAgentStore()
        let discModel = AgentTokenDiscModel()
        discModel.stillRingColor = Color(hex: "#FF00FF")
        let pixels = try renderedPixels(of: AgentTokenDiscContent(store: store, discModel: discModel, tokenSlot: .overflow, overflowCount: 2)
            .frame(width: AgentTokenMetrics.panelWidth, height: 24))
        // The ring's top, half a point under the panel's top edge, is drawn and not cut off.
        let ringTopPixel = try #require(pixels.colorAt(x: Int((20 + AgentTokenMetrics.panelWidth / 2) * 2), y: Int((20 + 0.5) * 2)))
        #expect(ringTopPixel.redComponent > 0.8 && ringTopPixel.greenComponent < 0.4 && ringTopPixel.blueComponent > 0.8)
    }

    @Test func theStillRingOfAReduceMotionServeStaysForASecond() {
        #expect(agentTokenServeStillRingSeconds == 1)
    }
}
