//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

// A nonactivating panel, because a drag on the live scene would otherwise
// make Clicky the frontmost app and take the keyboard from the page under it.
class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        // One level above .screenSaver (see OverlayWindowManager.cursorOverlayWindowLevel, which sets it), so the cursor
        // draws over the live scene window, the status label, submenus, and popups. The .screenSaver here is only the
        // level before the manager replaces it.
        self.level = .screenSaver
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

/// How the buddy gets from where it is to a target, or back to the mouse.
enum CursorFlightMotion: Equatable {
    /// Travels along the bezier arc, swooping and turning toward its direction of travel.
    case travelAlongArc
    /// Reduce Motion: fades out where it is, then fades in at the destination, with no travel between.
    case fadeToDestination
}

/// Reduce Motion replaces the swooping arc with a short fade, so nothing crosses the screen. Both motions
/// report arrival the same way, so the pointing hold and the narration's wait for arrival work either way.
func cursorFlightMotion(reduceMotionIsOn: Bool) -> CursorFlightMotion {
    reduceMotionIsOn ? .fadeToDestination : .travelAlongArc
}

/// How long the buddy keeps pointing once it reaches a detected element.
enum BuddyPointingHold: Equatable {
    /// A few seconds after its bubble text appears, then it flies back to the cursor.
    case briefly
    /// Until CompanionManager clears the location, so it stays on a 3D scene part for as long as
    /// Clicky talks about it. Only the narration with this ID may release it.
    case untilReleased(byNarrationID: UUID)

    var holdsUntilReleased: Bool {
        if case .untilReleased = self { return true }
        return false
    }
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, a ring around the
// triangle shows ticks that follow the voice (listening) or three
// orbiting dots (processing), and the streaming text bubble shows
// while Clicky responds. A loop around the media Clicky is looking
// at takes over the thinking light from the dots.
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager
    /// The team theme, which sets the cursor's color. Observed here because it is its own object, so a change in the
    /// menu bar panel redraws the cursor at once.
    @ObservedObject private var themeSettings: CompanionThemeSettings
    /// The loop around the video or image Clicky is looking at. It is the thinking light while it shows, so it is
    /// observed here to redraw the ring and the loop together.
    @ObservedObject private var cursorLoopController: CursorLoopController
    /// A status line shows as a Callout above the cursor, so the ring hides under it. The triangle stays.
    @ObservedObject private var statusLabelModel = LiveSceneStatusLabel.shared.statusLabelModel

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        self.themeSettings = companionManager.themeSettings
        self.cursorLoopController = companionManager.cursorLoopController

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var onboardingPromptBubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0
    /// Multiplies the cursor's and the ring's opacity. Reduce Motion's flight fades it to 0 at the start and back to 1
    /// at the destination, in place of travelling along the arc.
    @State private var flightFadeOpacity: Double = 1.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The buddy's rotation in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target. The triangle also
    /// uses it while following, and the volleyball uses `cursorFollowMotion` then.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero
    /// The whole sentence the bubble speaks. `navigationBubbleText` is the part of it the voice has reached.
    @State private var navigationBubblePhrase: String = ""
    /// Counts each phrase the bubble starts typing, so typing that a newer phrase replaced stops.
    @State private var navigationBubbleTypingGeneration = 0

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// How much bigger the buddy is at the middle of a flight. The volleyball's streaks
    /// divide by it, so they show fully at the middle and fade out as the ball lands.
    private let buddyFlightPeakExtraScale: CGFloat = 0.3

    /// While a cursor that turns toward movement, such as a school theme's volleyball, follows the mouse, it turns toward
    /// the mouse's movement and shows streaks at speed. It advances under every theme, so switching themes never shows an
    /// old facing or old streaks.
    @State private var cursorFollowMotion = CursorFollowMotion.atRest


    /// A cursor that follows the mouse's movement (such as a school's volleyball) faces it while it follows, and its flight
    /// direction otherwise. The triangle keeps its pointer angle while it follows. A cursor that does not turn stays upright.
    private var buddyRotationDegrees: Double {
        switch themeSettings.shownTheme.cursorFacing {
        case .pointerAngle:
            return triangleRotationDegrees
        case .followsMouseMovement:
            return directionOfTravelDegrees
        case .upright:
            return 0
        }
    }

    /// The way the cursor moves: the mouse's movement while it follows, and the flight's direction otherwise. A cursor that
    /// faces its movement turns by this, and a custom cursor that stays upright turns only its streaks by it.
    private var directionOfTravelDegrees: Double {
        buddyNavigationMode == .followingCursor ? cursorFollowMotion.facingDegrees : triangleRotationDegrees
    }

    /// A cursor's streaks show the mouse's speed while it follows, and the flight's size
    /// pulse while it flies.
    private var cursorStreakOpacity: Double {
        buddyNavigationMode == .followingCursor
            ? cursorFollowMotion.streakStrength
            : (buddyFlightScale - 1.0) / buddyFlightPeakExtraScale
    }

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    /// True while the buddy flies to or points at a target that holds until released. CompanionManager
    /// has already reset its hold by the time the location clears, so the view keeps its own copy.
    @State private var currentTargetHoldsUntilReleased: Bool = false

    /// True after an instant replay ended with the buddy stopped where it was, mid-flight included. The buddy stays
    /// there until the mouse moves `frozenBuddyReleaseDistance` points, then flies back to it.
    @State private var buddyIsFrozenWhereItStopped = false
    /// How the pointing bubble leaves: a fade-rise, or a Recall into the cursor when the learner interrupted.
    @State private var navigationBubbleExit: TetherCalloutExit = .fadeRise
    @State private var mouseLocationWhenTheBuddyFroze: CGPoint = .zero
    private let frozenBuddyReleaseDistance: CGFloat = 100

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm clicky"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    /// Whether each speech Callout is on screen, which drives its Pop in and its leave.
    private var navigationBubbleIsShowing: Bool {
        buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty && navigationBubbleOpacity > 0
    }
    private var welcomeBubbleIsShowing: Bool {
        isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty
    }
    private var onboardingPromptBubbleIsShowing: Bool {
        isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty
    }

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if welcomeBubbleIsShowing {
                SpeechCalloutView(sentence: welcomeText, revealedCharacterCount: welcomeText.count, accent: themeSettings.shownTheme.cursorColor)
                    .onGeometryChange(for: CGSize.self) { calloutGeometry in
                        calloutGeometry.size
                    } action: { measuredCalloutSize in
                        bubbleSize = measuredCalloutSize
                    }
                    .opacity(bubbleOpacity)
                    .position(speechCalloutCenter(cursorPosition: cursorPosition, calloutSize: bubbleSize, screenSize: screenFrame.size))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .transition(.tetherCalloutPopAndFadeRise(reduceMotionIsOn: reduceMotionIsOn, pivotInTheView: speechCalloutPivot(cursorPosition: cursorPosition, calloutSize: bubbleSize, screenSize: screenFrame.size)))
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if onboardingPromptBubbleIsShowing {
                SpeechCalloutView(
                    sentence: companionManager.onboardingPromptText,
                    revealedCharacterCount: companionManager.onboardingPromptText.count,
                    accent: themeSettings.shownTheme.cursorColor
                )
                    .onGeometryChange(for: CGSize.self) { calloutGeometry in
                        calloutGeometry.size
                    } action: { measuredCalloutSize in
                        onboardingPromptBubbleSize = measuredCalloutSize
                    }
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(speechCalloutCenter(cursorPosition: cursorPosition, calloutSize: onboardingPromptBubbleSize, screenSize: screenFrame.size))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .transition(.tetherCalloutPopAndFadeRise(reduceMotionIsOn: reduceMotionIsOn, pivotInTheView: speechCalloutPivot(cursorPosition: cursorPosition, calloutSize: onboardingPromptBubbleSize, screenSize: screenFrame.size)))
            }

            // Navigation pointer bubble - shown when buddy arrives at a detected element, and while a narration
            // speaks. A Callout above the cursor whose tail points at the triangle: it pops out of the tail's tip,
            // its words brighten as the voice reaches them, and it leaves with a fade and a 6 point rise.
            if navigationBubbleIsShowing {
                SpeechCalloutView(
                    sentence: navigationBubblePhrase,
                    revealedCharacterCount: navigationBubbleText.count,
                    accent: themeSettings.shownTheme.cursorColor
                )
                    .onGeometryChange(for: CGSize.self) { calloutGeometry in
                        calloutGeometry.size
                    } action: { measuredCalloutSize in
                        navigationBubbleSize = measuredCalloutSize
                    }
                    .position(speechCalloutCenter(cursorPosition: cursorPosition, calloutSize: navigationBubbleSize, screenSize: screenFrame.size))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .transition(.tetherCalloutPop(andLeave: navigationBubbleExit, reduceMotionIsOn: reduceMotionIsOn, pivotInTheView: speechCalloutPivot(cursorPosition: cursorPosition, calloutSize: navigationBubbleSize, screenSize: screenFrame.size)))
            }

            // The loop around the video or image Clicky is looking at, under the cursor so the triangle stays on top.
            if let loopToDraw = cursorLoopController.loopToDraw(onScreenWithFrame: screenFrame) {
                CursorLoopView(loop: loopToDraw, cursorPosition: cursorPosition, color: themeSettings.shownTheme.cursorColor)
            }

            // The theme's cursor: the triangle, shapes such as a school's volleyball, or a picture. It stays visible through every voice state,
            // with the ring around it, and stays in the view tree so SwiftUI doesn't remove/re-insert it
            // (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            CustomCursorView(
                customTheme: themeSettings.shownTheme,
                picture: themeSettings.shownThemePicture,
                streakOpacity: cursorStreakOpacity,
                streakFacingDegrees: themeSettings.shownTheme.cursorFacing == .upright ? directionOfTravelDegrees : 0,
                voiceState: companionManager.voiceState,
                audioPowerLevel: companionManager.currentAudioPowerLevel
            )
                .rotationEffect(.degrees(buddyRotationDegrees))
                .shadow(color: themeSettings.shownTheme.cursorColor, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity * flightFadeOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // The ring around the cursor: ticks that follow the voice while listening, and three orbiting dots
            // while thinking. It follows the cursor like the triangle, and hides under a status label.
            CursorRingView(
                cue: cursorCue(
                    voiceState: companionManager.voiceState,
                    loopIsShowing: cursorLoopController.isShowingTheLoop(onScreenWithFrame: screenFrame),
                    aStatusLabelIsShowing: statusLabelModel.isVisible
                ),
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                color: themeSettings.shownTheme.cursorColor
            )
                .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity * flightFadeOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
        }
        // Each speech Callout pops in as it enters the tree and leaves with a fade-rise (see `.tetherCalloutPopAndFadeRise`).
        .animation(tetherCalloutAnimation(isAppearing: navigationBubbleIsShowing, exit: navigationBubbleExit, reduceMotionIsOn: reduceMotionIsOn), value: navigationBubbleIsShowing)
        .animation(tetherCalloutAnimation(isAppearing: welcomeBubbleIsShowing, exit: .fadeRise, reduceMotionIsOn: reduceMotionIsOn), value: welcomeBubbleIsShowing)
        .animation(tetherCalloutAnimation(isAppearing: onboardingPromptBubbleIsShowing, exit: .fadeRise, reduceMotionIsOn: reduceMotionIsOn), value: onboardingPromptBubbleIsShowing)
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementBubbleText) { newBubbleText in
            // A narration holds the buddy on a part and changes the text for each sentence it speaks there.
            guard buddyNavigationMode == .pointingAtTarget,
                  currentTargetHoldsUntilReleased,
                  let newBubbleText else { return }
            navigationBubbleText = ""
            typeNavigationBubble(phrase: newBubbleText)
        }
        .onChange(of: companionManager.buddyFreezeCount) { _ in
            freezeTheBuddyWhereItIs()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                if newLocation == nil {
                    flyBackFromAReleasedHeldTarget()
                }
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // A buddy an instant replay froze waits where it stopped until the mouse moves away from where it was then.
            if self.buddyIsFrozenWhereItStopped {
                let distanceSinceTheFreeze = hypot(mouseLocation.x - self.mouseLocationWhenTheBuddyFroze.x, mouseLocation.y - self.mouseLocationWhenTheBuddyFroze.y)
                if distanceSinceTheFreeze > self.frozenBuddyReleaseDistance {
                    self.buddyIsFrozenWhereItStopped = false
                    self.companionManager.releaseTheBuddyTheReplayFroze()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            let nextCursorPosition = CGPoint(x: buddyX, y: buddyY)
            // Reduce Motion keeps the following ball or custom cursor still: no turning toward the mouse and no streaks.
            // It is read from the system on each tick, because this timer closure holds a copy of the view
            // made when it appeared, and an @Environment value in that copy never updates.
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.cursorFollowMotion = .atRest
            } else {
                let mouseMovement = CGVector(
                    dx: nextCursorPosition.x - self.cursorPosition.x,
                    dy: nextCursorPosition.y - self.cursorPosition.y
                )
                self.cursorFollowMotion = self.cursorFollowMotion.advanced(byMouseMovement: mouseMovement)
            }
            self.cursorPosition = nextCursorPosition
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyIsFrozenWhereItStopped = false
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        currentTargetHoldsUntilReleased = companionManager.detectedElementPointingHold.holdsUntilReleased

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        // Read from the system on each flight, so a change in System Settings applies to the next flight.
        let motion = cursorFlightMotion(reduceMotionIsOn: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if motion == .fadeToDestination {
            fadeCursorToDestination(destination, onComplete: onComplete)
            return
        }
        flightFadeOpacity = 1.0

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * self.buddyFlightPeakExtraScale
        }
    }

    /// Reduce Motion's flight: fades the cursor out, puts it at the destination, and fades it back in. It calls
    /// `onComplete` once the cursor is at the destination, as the arc does, and a cancel invalidates the timer
    /// like the arc's, with `finishNavigationAndResumeFollowing` putting the opacity back.
    private func fadeCursorToDestination(_ destination: CGPoint, onComplete: @escaping () -> Void) {
        let fadeDurationSeconds = 0.12
        withAnimation(.easeOut(duration: fadeDurationSeconds)) {
            flightFadeOpacity = 0.0
        }
        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: fadeDurationSeconds, repeats: false) { _ in
            self.navigationAnimationTimer = nil
            self.cursorPosition = destination
            withAnimation(.easeIn(duration: fadeDurationSeconds)) {
                self.flightFadeOpacity = 1.0
            }
            onComplete()
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        navigationBubbleExit = .fadeRise

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state. The bubble pops in when its first letters appear.
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero

        // Use custom bubble text from the companion manager (the onboarding demo's comment, or the
        // sentence a narration is speaking) if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"
        typeNavigationBubble(phrase: pointerPhrase)
    }

    /// Types the phrase into the bubble. A target that is not held flies back 3.5 seconds after the last character.
    private func typeNavigationBubble(phrase: String) {
        navigationBubblePhrase = phrase
        navigationBubbleTypingGeneration += 1
        let typingGeneration = navigationBubbleTypingGeneration

        let onTypingComplete = {
            // A held target stays until CompanionManager clears the location.
            guard !self.currentTargetHoldsUntilReleased else { return }
            // All characters streamed. Hold for 3 seconds, then fly back.
            // A held target that arrived since then must not be cut short by this older timer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget, !self.currentTargetHoldsUntilReleased else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget, !self.currentTargetHoldsUntilReleased else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
        // A phrase Clicky is speaking brightens along with the voice. Any other phrase types at its own pace.
        if companionManager.spokenFractionOfTheLine(phrase) != nil {
            followTheVoiceInTheNavigationBubble(phrase: phrase, typingGeneration: typingGeneration, onComplete: onTypingComplete)
        } else {
            streamNavigationBubbleCharacter(phrase: phrase, characterIndex: 0, typingGeneration: typingGeneration, onComplete: onTypingComplete)
        }
    }

    /// Shows as much of the phrase as the voice has said, 30 times a second, so the caption never races
    /// ahead or falls behind. The bubble often arrives after the sentence started, and then catches up at once.
    private func followTheVoiceInTheNavigationBubble(phrase: String, typingGeneration: Int, onComplete: @escaping () -> Void) {
        guard buddyNavigationMode == .pointingAtTarget,
              typingGeneration == navigationBubbleTypingGeneration else { return }
        // A line that was stopped counts as said, so the caption finishes instead of freezing.
        let spokenFraction = companionManager.spokenFractionOfTheLine(phrase) ?? 1
        let revealedCharacterCount = SpokenLineProgress.revealedCharacterCount(phraseLength: phrase.count, spokenFraction: spokenFraction)
        if navigationBubbleText.count != revealedCharacterCount {
            navigationBubbleText = String(phrase.prefix(revealedCharacterCount))
        }
        guard revealedCharacterCount < phrase.count else {
            onComplete()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) {
            self.followTheVoiceInTheNavigationBubble(phrase: phrase, typingGeneration: typingGeneration, onComplete: onComplete)
        }
    }

    /// Whether the learner has Reduce Motion on, read when the bubble animates, since the setting can change while it runs.
    private var reduceMotionIsOn: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// An instant replay that ends stops the buddy where it is, mid-flight included, with no ease: the flight timer stops,
    /// the bubble hides, and the buddy keeps its position and heading. A buddy following the mouse has nothing to stop.
    private func freezeTheBuddyWhereItIs() {
        guard buddyNavigationMode != .followingCursor, !isReturningToCursor else { return }
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleTypingGeneration += 1
        navigationBubbleOpacity = 0.0
        buddyFlightScale = 1.0
        flightFadeOpacity = 1.0
        buddyNavigationMode = .pointingAtTarget
        currentTargetHoldsUntilReleased = true
        buddyIsFrozenWhereItStopped = true
        mouseLocationWhenTheBuddyFroze = NSEvent.mouseLocation
    }

    /// A held target ends when CompanionManager clears the location, once Clicky stops talking about that part.
    /// Only the screen whose buddy is at or flying to the target has anything to release.
    private func flyBackFromAReleasedHeldTarget() {
        guard currentTargetHoldsUntilReleased,
              buddyNavigationMode != .followingCursor,
              !isReturningToCursor else { return }
        currentTargetHoldsUntilReleased = false
        let exitOfTheBubble = companionManager.takeThePointingBubbleExit()
        guard exitOfTheBubble == .recall else {
            navigationBubbleExit = .fadeRise
            navigationBubbleOpacity = 0.0
            startFlyingBackToCursor()
            return
        }
        // SwiftUI removes a view with the transition it had on the last render, so the Recall is set one turn before the
        // bubble leaves the tree, and the cursor's flight back waits for that turn too.
        navigationBubbleExit = .recall
        DispatchQueue.main.async {
            navigationBubbleOpacity = 0.0
            startFlyingBackToCursor()
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        typingGeneration: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget,
              typingGeneration == navigationBubbleTypingGeneration else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                typingGeneration: typingGeneration,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        buddyFlightScale = 1.0
        flightFadeOpacity = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyIsFrozenWhereItStopped = false
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        currentTargetHoldsUntilReleased = false
        triangleRotationDegrees = -35.0
        // The follow motion froze before the flight. Starting it at rest lets the ball ease to the
        // pointer angle like the triangle, instead of spinning back to an old facing with old streaks.
        cursorFollowMotion = .atRest
        buddyFlightScale = 1.0
        flightFadeOpacity = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        // Reduce Motion shows the whole message at once instead of typing it one character at a time.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            welcomeText = fullWelcomeMessage
            holdThenHideTheWelcomeMessage()
            return
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                self.holdThenHideTheWelcomeMessage()
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }

    /// Holds the finished welcome text for 2 seconds, fades it out, then starts the onboarding video.
    private func holdThenHideTheWelcomeMessage() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.bubbleOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.showWelcome = false
            // Start the onboarding video right after the welcome text disappears
            self.companionManager.setupOnboardingVideo()
        }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    /// One above .screenSaver, where the live scene window and the status label sit, so the blue
    /// cursor draws over a 3D scene when it points at a part. These windows ignore the mouse, so
    /// clicks and drags still reach the scene under them.
    private static let cursorOverlayWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)
            window.level = Self.cursorOverlayWindowLevel

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
