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

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default - buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

/// Whether the buddy draws on one screen. While the settings dial is on screen the buddy draws nowhere: the dial draws its
/// own cursor glyph in the center, and the buddy, which sits 35 points right of and 25 below the mouse, would show through
/// the plate as it fades in and out, a second cursor under the dial. Otherwise it draws on the screen the mouse is on while it
/// follows the mouse, on every screen while it flies to or points at a target, and on no screen another screen's buddy is
/// busy on (so only one buddy ever shows).
func buddyIsVisible(
    navigationMode: BuddyNavigationMode,
    anotherScreensBuddyIsBusy: Bool,
    isCursorOnThisScreen: Bool,
    settingsDialIsOnScreen: Bool
) -> Bool {
    if settingsDialIsOnScreen { return false }
    switch navigationMode {
    case .followingCursor:
        return !anotherScreensBuddyIsBusy && isCursorOnThisScreen
    case .navigatingToTarget, .pointingAtTarget:
        return true
    }
}

/// The buddy's fade as the settings dial's presence changes. It goes at once as the dial opens, since the dial's own cursor
/// glyph fades in then, and a buddy that faded out over the same 150 ms would show beside it as a second cursor. It fades back
/// in once the dial's window is gone, instead of cutting. SwiftUI reads the animation after the change, so the one for "on
/// screen" is the animation of the buddy leaving.
func buddyFadeAsTheSettingsDialChanges(settingsDialIsOnScreen: Bool) -> Animation? {
    settingsDialIsOnScreen ? nil : .easeInOut(duration: DS.Move.fadeSeconds)
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
// at takes over the thinking light from the dots, and the buddy draws
// it: it flies to the line's start, traces it, and flies back.
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
    /// Whether a status line's Callout is on screen above the cursor, which pulls the thinking dots' orbit in under it.
    @ObservedObject private var statusLinePresence: TetherCalloutPresence
    /// The slide along a video's progress bar before a voice seek.
    @ObservedObject private var cursorScrubController: CursorScrubController
    /// Whether the settings dial is on screen. The buddy hides while it is (see `buddyIsVisible`).
    @ObservedObject private var settingsDialPresence = SettingsDialPresence.shared
    /// The scrub this screen's buddy is playing, from the flight to the bar until it is back at the mouse.
    @State private var playingScrubID: UUID?
    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        self.themeSettings = companionManager.themeSettings
        self.cursorLoopController = companionManager.cursorLoopController
        self.statusLinePresence = LiveSceneStatusLabel.shared.statusLabelModel.presence
        self.cursorScrubController = companionManager.cursorScrubController

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

    /// Where the ring goes when the buddy lands on the target it is flying to: the element itself, not the spot beside it.
    @State private var pointedTargetCenter: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// How fast the buddy flies, from 0 at the ends of a flight to 1 at its middle (`CursorPointFlight.speedShare`). The
    /// Point move stretches the cursor along its flight by it, a theme's streaks show by it, and the glow grows with it.
    @State private var buddyFlightSpeedShare: Double = 0

    /// The direction of the current or last flight, in the convention of `triangleRotationDegrees`. The Point move stretches
    /// the cursor along it and squashes it along it on landing, whichever way the cursor itself faces.
    @State private var buddyFlightDirectionDegrees: Double = 0

    /// When the buddy last landed, which starts the Point move's landing squash.
    @State private var buddyLandedAt: Date?

    /// The ring on the target the buddy is pointing at, which stays until the buddy leaves it.
    @State private var landingRing: CursorLandingRing?

    /// The emote that is playing (a nod, a shake, or a hop), started by `CompanionManager.playCursorEmote`.
    @State private var playingEmote: PlayingCursorEmote?

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
            : buddyFlightSpeedShare
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

    /// The loop this screen's buddy draws, and how much of its line shows. The trace runs on `navigationAnimationTimer`, so
    /// every path that stops a flight stops a trace too.
    @State private var loopDraw: BuddyLoopDraw?
    /// The token `CursorLoopController` gave this screen's buddy when it left the mouse to draw a loop, until it is back or a
    /// pointing or a scrub takes it. It is kept apart from `loopDraw`, since a newer loop can replace the draw while the buddy
    /// still flies back from the older one.
    @State private var loopDrawAwayToken: UUID?

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

            // Onboarding video - always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.row, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt - "press control + option and say hi" streamed after video ends
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
            // its words brighten as the voice reaches them, and it leaves with a fade and a 6 point rise, or shrinks
            // into the cursor when a push-to-talk press interrupted the narration (`navigationBubbleExit`).
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

            // The ring on the target the buddy landed on, under the cursor so the triangle stays on top.
            if let landingRing {
                CursorLandingRingView(landingRing: landingRing, color: themeSettings.shownTheme.cursorColor)
                    .position(landingRing.center)
                    .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity : 0)
                    .animation(buddyFadeForTheSettingsDial, value: settingsDialPresence.isOnScreen)
            }

            // The loop around the video or image Clicky is looking at, under the cursor so the triangle stays on top. The
            // buddy draws it, so the view shows only the line behind the cursor.
            if let loopToDraw = cursorLoopController.loopToDraw(onScreenWithFrame: screenFrame) {
                CursorLoopView(
                    loop: loopToDraw,
                    ink: BuddyLoopDraw.ink(for: loopToDraw, draw: loopDraw, wayForANewLoop: loopDrawWayNow),
                    color: themeSettings.shownTheme.cursorColor
                )
                .id(loopToDraw.beganAt)
            }

            // The sparks background agents lap around the same media, over a request's loop when one shows.
            if let agentLoopToDraw = cursorLoopController.agentLoopToDraw(onScreenWithFrame: screenFrame) {
                CursorLoopAgentSparkView(
                    agentLoop: agentLoopToDraw,
                    agentStore: companionManager.backgroundAgentStore,
                    trackColor: themeSettings.shownTheme.cursorColor,
                    reduceMotionIsOn: reduceMotionIsOn
                )
            }

            // The theme's cursor: the triangle, shapes such as a school's volleyball, or a picture. It stays visible through every voice state,
            // with the ring around it, and stays in the view tree so SwiftUI doesn't remove/re-insert it
            // (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation - the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            CursorBodyLanguageView(
                glyph: CustomCursorView(
                    customTheme: themeSettings.shownTheme,
                    picture: themeSettings.shownThemePicture,
                    streakOpacity: cursorStreakOpacity,
                    streakFacingDegrees: themeSettings.shownTheme.cursorFacing == .upright ? directionOfTravelDegrees : 0,
                    voiceState: companionManager.voiceState,
                    audioPowerLevel: companionManager.currentAudioPowerLevel
                )
                .rotationEffect(.degrees(buddyRotationDegrees)),
                glowColor: themeSettings.shownTheme.cursorColor,
                flightSpeedShare: buddyFlightSpeedShare,
                flightDirectionDegrees: buddyFlightDirectionDegrees,
                playingEmote: playingEmote,
                landedAt: buddyLandedAt
            )
                .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity * flightFadeOpacity : 0)
                .animation(buddyFadeForTheSettingsDial, value: settingsDialPresence.isOnScreen)
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
            // while thinking. It follows the cursor like the triangle, and a status label's Callout above the cursor does not hide it.
            CursorRingView(
                cue: cursorCue(
                    voiceState: companionManager.voiceState,
                    loopIsShowing: cursorLoopController.isShowingTheLoop(onScreenWithFrame: screenFrame)
                ),
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                color: themeSettings.shownTheme.cursorColor,
                aStatusLineShows: statusLinePresence.isInTheViewTree
            )
                .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity * flightFadeOpacity : 0)
                .animation(buddyFadeForTheSettingsDial, value: settingsDialPresence.isOnScreen)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
        }
        // Each speech Callout pops in as it enters the tree and leaves with a fade-rise (see `.tetherCalloutPopAndFadeRise`),
        // and the pointing bubble leaves the way `navigationBubbleExit` says (`.tetherCalloutPop(andLeave:)`).
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
            // A scrub can be asked for in the same turn that shows the overlay, before this view's first render, when no
            // onChange would see it.
            if let scrubRequest = cursorScrubController.request {
                startScrubbing(scrubRequest)
            }
            loopOnThisScreenChanged(to: cursorLoopController.loopToDraw(onScreenWithFrame: screenFrame))
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            releaseTheBuddyFromTheLoopDraw()
            // A scrub this view played ends with it, so a later overlay never replays a seek that already ran.
            endThePlayingScrub()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.cursorEmoteRequest) { newEmoteRequest in
            guard let newEmoteRequest else { return }
            playingEmote = PlayingCursorEmote(emote: newEmoteRequest.emote, startedAt: Date())
        }
        .onChange(of: companionManager.detectedElementBubbleText) { newBubbleText in
            // A narration holds the buddy on a part and changes the text for each sentence it speaks there.
            guard buddyNavigationMode == .pointingAtTarget,
                  currentTargetHoldsUntilReleased,
                  let newBubbleText else { return }
            navigationBubbleText = ""
            typeNavigationBubble(phrase: newBubbleText)
        }
        .onChange(of: cursorScrubController.request) { newScrubRequest in
            // A scrub on another display takes the one buddy there, so this screen's loop draw lands and its buddy goes back.
            if let newScrubRequest, !targetDisplayIsThisScreen(newScrubRequest.displayFrame) {
                landTheLoopDrawAtOnce(sendingTheBuddyBack: true, evenWhileItFliesBack: true)
            }
            if let newScrubRequest {
                startScrubbing(newScrubRequest)
            } else if playingScrubID != nil {
                // A push-to-talk press landed the scrub at once, so the buddy goes back to the mouse, where the ring listens.
                // A pointing on another display is that display's, so this one leaves it set.
                navigationAnimationTimer?.invalidate()
                navigationAnimationTimer = nil
                finishNavigationAndResumeFollowing(clearingTheSharedPointing: false)
            }
        }
        .onChange(of: cursorLoopController.loopToDraw(onScreenWithFrame: screenFrame)) { newLoop in
            loopOnThisScreenChanged(to: newLoop)
        }
        .onChange(of: cursorLoopController.buddyAwayForTheLoop) { newBuddyAwayForTheLoop in
            // Another screen's buddy left to draw a newer loop, so a buddy still flying back here comes back at once, and
            // only one buddy shows.
            guard theLoopDrawLandsForAnotherDraw(heldToken: loopDrawAwayToken, newRecordToken: newBuddyAwayForTheLoop?.token) else { return }
            landTheLoopDrawAtOnce(sendingTheBuddyBack: true, evenWhileItFliesBack: true)
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

            // Only navigate if the target is on THIS screen. A pointing on another display takes the one buddy there, so this
            // screen's loop draw lands and its buddy goes back.
            guard targetDisplayIsThisScreen(displayFrame) else {
                landTheLoopDrawAtOnce(sendingTheBuddyBack: true, evenWhileItFliesBack: true)
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
        // If another screen's BlueCursorView is navigating to an element, scrubbing, or drawing the loop,
        // the cursor on this screen hides to prevent a duplicate buddy.
        let anotherScreenLoopDrawHoldsTheBuddy = cursorLoopController.screenFrameWhereTheBuddyDrawsTheLoop.map {
            $0 != screenFrame && loopDrawAwayToken == nil
        } ?? false
        let anotherScreensBuddyIsBusy = companionManager.detectedElementScreenLocation != nil
            || cursorScrubController.request != nil
            || anotherScreenLoopDrawHoldsTheBuddy
        return buddyIsVisible(
            navigationMode: buddyNavigationMode,
            anotherScreensBuddyIsBusy: anotherScreensBuddyIsBusy,
            isCursorOnThisScreen: isCursorOnThisScreen,
            settingsDialIsOnScreen: settingsDialPresence.isOnScreen
        )
    }

    private var buddyFadeForTheSettingsDial: Animation? {
        buddyFadeAsTheSettingsDialChanges(settingsDialIsOnScreen: settingsDialPresence.isOnScreen)
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement - it completes its full animation and return flight.
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
        // directly on top of it - 8px to the right, 12px below.
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

        // A pointing takes over a scrub this buddy was playing, whose seek then runs at once, and lands a loop it was drawing.
        endThePlayingScrub()
        landTheLoopDrawAtOnce(sendingTheBuddyBack: false)

        // Enter navigation mode - stop cursor following
        buddyIsFrozenWhereItStopped = false
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        endTheLandingRing()
        pointedTargetCenter = CGPoint(x: clampedTarget.x - 8, y: clampedTarget.y - 12)
        currentTargetHoldsUntilReleased = companionManager.detectedElementPointingHold.holdsUntilReleased

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, stretches along that direction
    /// at the middle of the flight (the Point move), and the glow grows with its speed.
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
        buddyLandedAt = nil

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic (the Point move, clamped to 0.6s-1.4s).
        let pointMoveCurve = DS.Move.point.curve
        let flightDurationSeconds = pointMoveCurve.seconds(travelingPoints: distance)
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
                self.buddyFlightSpeedShare = 0
                // The landing squash starts when the cursor lands on a target, not when it comes back to the mouse. Reduce Motion
                // never reaches it, since its flight is the fade.
                if !self.isReturningToCursor { self.buddyLandedAt = Date() }
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // The Point move's easing, smoothstep: 3t² - 2t³ (Hermite interpolation)
            let easedFlightProgress = pointMoveCurve.progress(atSeconds: linearProgress * flightDurationSeconds, travelingPoints: distance)

            // Quadratic bezier: B(p) = (1-p)²·P0 + 2(1-p)p·P1 + p²·P2, with p the eased flight progress
            let oneMinusEasedProgress = 1.0 - easedFlightProgress
            let bezierX = oneMinusEasedProgress * oneMinusEasedProgress * startPosition.x
                        + 2.0 * oneMinusEasedProgress * easedFlightProgress * controlPoint.x
                        + easedFlightProgress * easedFlightProgress * endPosition.x
            let bezierY = oneMinusEasedProgress * oneMinusEasedProgress * startPosition.y
                        + 2.0 * oneMinusEasedProgress * easedFlightProgress * controlPoint.y
                        + easedFlightProgress * easedFlightProgress * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(p) = 2(1-p)(P1-P0) + 2p(P2-P1)
            let tangentX = 2.0 * oneMinusEasedProgress * (controlPoint.x - startPosition.x)
                         + 2.0 * easedFlightProgress * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusEasedProgress * (controlPoint.y - startPosition.y)
                         + 2.0 * easedFlightProgress * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0
            self.buddyFlightDirectionDegrees = self.triangleRotationDegrees

            // The cursor stretches along its flight, most at the middle, and the streaks and glow follow the same speed.
            // A flight that goes nowhere has no direction to stretch along, so it stays round.
            self.buddyFlightSpeedShare = distance > 1 ? CursorPointFlight.speedShare(linearProgress: linearProgress) : 0
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

    /// Transitions to pointing mode - shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        navigationBubbleExit = .fadeRise
        // Marks the target for the whole time the buddy points at it. Reduce Motion fades it in and leaves it still.
        landingRing = CursorLandingRing(center: pointedTargetCenter, landedAt: Date(), endedAt: nil)

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
        // A buddy drawing a loop is not the replay's, so it goes back to the mouse instead of freezing on the line.
        guard loopDrawAwayToken == nil else {
            landTheLoopDrawAtOnce(sendingTheBuddyBack: true)
            return
        }
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleTypingGeneration += 1
        navigationBubbleOpacity = 0.0
        // A buddy stopped mid-flight stands still, so it loses the flight's stretch.
        buddyFlightSpeedShare = 0
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
        // A flight still on its way to the part would land in that turn and type a new bubble, so it stops here.
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        DispatchQueue.main.async {
            let newPointingDisplayFrame = companionManager.detectedElementDisplayFrame
            // startNavigatingToElement refuses a target while the first-launch welcome types.
            let thisScreenFliesToTheNewPointing = newPointingDisplayFrame.map(targetDisplayIsThisScreen) == true
                && (!showWelcome || welcomeText.isEmpty)
            switch pointingBubbleRecallStep(
                buddyIsAwayFromTheMouse: buddyNavigationMode != .followingCursor && !isReturningToCursor,
                aNewPointingIsSet: companionManager.detectedElementScreenLocation != nil,
                thisScreenFliesToTheNewPointing: thisScreenFliesToTheNewPointing
            ) {
            case .nothingLeftToDo, .leaveTheBuddyToTheNewPointing:
                return
            case .flyBackToTheMouse:
                navigationBubbleOpacity = 0.0
                startFlyingBackToCursor()
            case .giveWayToThePointingElsewhere:
                // The buddy shows on the target's screen, so this one goes back to following the mouse, out of sight,
                // and leaves the shared pointing to that screen.
                finishNavigationAndResumeFollowing(clearingTheSharedPointing: false)
            }
        }
    }

    private func targetDisplayIsThisScreen(_ displayFrame: CGRect) -> Bool {
        screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY)) || displayFrame == screenFrame
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30-60ms) for a natural "speaking" rhythm.
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
        endTheLandingRing()

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing(clearingTheSharedPointing: self.buddyOwnsTheSharedPointing)
        }
    }

    /// The ring on the target fades out when the buddy leaves it.
    private func endTheLandingRing() {
        guard var ring = landingRing, ring.endedAt == nil else { return }
        ring.endedAt = Date()
        landingRing = ring
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        buddyFlightSpeedShare = 0
        flightFadeOpacity = 1.0
        // A scrub or a loop draw never owns the shared pointing, which a pointing on another display may have set during its
        // flight back.
        finishNavigationAndResumeFollowing(clearingTheSharedPointing: buddyOwnsTheSharedPointing)
    }

    /// Whether the buddy is away for a pointing, which owns the shared pointing location, and not for a scrub or a loop draw.
    private var buddyOwnsTheSharedPointing: Bool {
        playingScrubID == nil && loopDrawAwayToken == nil
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    /// `clearingTheSharedPointing` is false only when this screen gives way to a pointing on another display, which that
    /// display's buddy is about to show.
    private func finishNavigationAndResumeFollowing(clearingTheSharedPointing: Bool = true) {
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
        buddyFlightSpeedShare = 0
        endTheLandingRing()
        flightFadeOpacity = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        if clearingTheSharedPointing {
            companionManager.clearDetectedElementLocation()
        }
        endThePlayingScrub()
        releaseTheBuddyFromTheLoopDraw()
    }

    // MARK: - Drawing the loop

    /// How a loop that appears now gets drawn: the buddy traces it while it is free, and Reduce Motion fades it in whole.
    private var loopDrawWayNow: CursorLoopDrawWay {
        cursorLoopDrawWay(reduceMotionIsOn: reduceMotionIsOn, theBuddyIsFree: theBuddyIsFreeToDrawALoop)
    }

    /// A loop never takes the buddy from a pointing, a scrub, an instant replay's hold, or the first-launch welcome.
    private var theBuddyIsFreeToDrawALoop: Bool {
        buddyNavigationMode == .followingCursor
            && playingScrubID == nil
            && !buddyIsFrozenWhereItStopped
            && companionManager.detectedElementScreenLocation == nil
            && cursorScrubController.request == nil
            && (!showWelcome || welcomeText.isEmpty)
    }

    /// A new loop on this screen sends the buddy to draw it. A loop that ends or starts to fade while the buddy draws it lands
    /// the draw: the whole line shows, and the buddy goes back to the mouse. A push-to-talk press ends the loop, so it lands
    /// the draw this way.
    private func loopOnThisScreenChanged(to loop: CursorLoopOnScreen?) {
        guard let loop, !loop.isFadingOut else {
            landTheLoopDrawAtOnce(sendingTheBuddyBack: true)
            return
        }
        guard loopDraw?.loopBeganAt != loop.beganAt else { return }
        // A buddy still flying back from an older loop comes back at once, so it is free to draw this one.
        landTheLoopDrawAtOnce(sendingTheBuddyBack: true, evenWhileItFliesBack: true)
        let way = loopDrawWayNow
        loopDraw = BuddyLoopDraw(loopBeganAt: loop.beganAt, way: way)
        guard way == .theCursorTracesIt else { return }
        flyToTheLoopAndTraceIt(loop)
    }

    /// The buddy flies from the mouse to the line's start on the Point move, traces the line, and flies back.
    private func flyToTheLoopAndTraceIt(_ loop: CursorLoopOnScreen) {
        let line = CursorLoopLine(outline: loop.outline)
        let loopBeganAt = loop.beganAt
        // The facing is read once per draw, so a theme change mid-draw never moves the glyph off the spot it landed on.
        let cursorFacing = themeSettings.shownTheme.cursorFacing
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(NSEvent.mouseLocation)
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        endTheLandingRing()
        let awayToken = cursorLoopController.theBuddyStartedDrawingTheLoop(onScreenWithFrame: screenFrame)
        loopDrawAwayToken = awayToken
        let lineStart = CursorLoopTracerPlacement(on: line, atShare: 0, cursorFacing: cursorFacing)
        animateBezierFlightArc(to: lineStart.glyphCenter) {
            guard self.loopDraw?.loopBeganAt == loopBeganAt,
                  self.loopDrawAwayToken == awayToken,
                  self.buddyNavigationMode == .navigatingToTarget,
                  !self.isReturningToCursor else { return }
            self.traceTheLoop(line, loopBeganAt: loopBeganAt, cursorFacing: cursorFacing)
        }
    }

    /// Moves the buddy along the line on `CursorLoopTimeline`, and moves the line's ink to the same share in the same step, so
    /// the ink ends under it.
    /// The triangle keeps its pointer angle with the ink at its tip, and a cursor that turns toward movement faces along the
    /// line. Once the line is whole, the buddy flies back to the mouse.
    private func traceTheLoop(_ line: CursorLoopLine, loopBeganAt: TimeInterval, cursorFacing: CursorFacing) {
        let traceBeganAt = ProcessInfo.processInfo.systemUptime
        loopDraw?.theCursorReachedTheStart()
        // The cursor sets off along the line at once, so the flight's landing squash does not play under the trace.
        buddyLandedAt = nil
        let rotationWhenTheTraceBegan = triangleRotationDegrees
        // Read by pattern, since an enum's Equatable conformance is the main actor's and a timer's closure is not.
        let keepsItsPointerAngle: Bool
        if case .pointerAngle = cursorFacing { keepsItsPointerAngle = true } else { keepsItsPointerAngle = false }
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            // Every exit stops this timer, and this guard keeps a tick that slipped through from moving the cursor for an
            // older loop.
            guard self.loopDraw?.loopBeganAt == loopBeganAt else {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let secondsSinceTheTraceBegan = now - traceBeganAt
            guard !CursorLoopTimeline.traceIsDone(secondsSinceTheTraceBegan: secondsSinceTheTraceBegan) else {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = CursorLoopTracerPlacement(on: line, atShare: 1, cursorFacing: cursorFacing).glyphCenter
                self.buddyFlightSpeedShare = 0
                self.loopDraw?.theTraceFinished(at: now)
                self.startFlyingBackToCursor()
                return
            }
            let tracedShare = CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: secondsSinceTheTraceBegan)
            let placement = CursorLoopTracerPlacement(on: line, atShare: tracedShare, cursorFacing: cursorFacing)
            self.cursorPosition = placement.glyphCenter
            self.loopDraw?.theCursorTraced(toShare: tracedShare)
            // The triangle turns back to its pointer angle, and every other cursor's facing and streaks follow the line.
            self.triangleRotationDegrees = CursorLoopTimeline.turnTowardTheLine(
                fromDegrees: rotationWhenTheTraceBegan,
                toDegrees: keepsItsPointerAngle ? CursorLoopTracerPlacement.pointerAngleDegrees : placement.headingDegrees,
                secondsSinceTheTraceBegan: secondsSinceTheTraceBegan
            )
            self.buddyFlightDirectionDegrees = placement.headingDegrees
            // The Point move's stretch scales about the glyph's center, which would pull the triangle's tip off the ink, so the
            // triangle traces unstretched. A cursor with the ink at its center stretches and shows its streaks with the speed.
            self.buddyFlightSpeedShare = keepsItsPointerAngle
                ? 0
                : CursorLoopTimeline.traceSpeedShare(secondsSinceTheTraceBegan: secondsSinceTheTraceBegan)
        }
    }

    /// The whole line shows at once. `sendingTheBuddyBack` puts a buddy still on the line back with the mouse, as a press
    /// does, and is false when a pointing or a scrub on this screen takes the buddy from here. A buddy already flying back keeps
    /// flying, unless `evenWhileItFliesBack` asks for it at once, for a newer loop or a pointing or scrub on another display.
    private func landTheLoopDrawAtOnce(sendingTheBuddyBack: Bool, evenWhileItFliesBack: Bool = false) {
        if var draw = loopDraw {
            draw.landAtOnce(at: ProcessInfo.processInfo.systemUptime)
            loopDraw = draw
        }
        guard loopDrawAwayToken != nil else { return }
        if sendingTheBuddyBack {
            guard !isReturningToCursor || evenWhileItFliesBack else { return }
            navigationAnimationTimer?.invalidate()
            navigationAnimationTimer = nil
            finishNavigationAndResumeFollowing(clearingTheSharedPointing: false)
        } else {
            releaseTheBuddyFromTheLoopDraw()
        }
    }

    /// The buddy is back at the mouse, or another job took it, so the other screens show their buddy again.
    private func releaseTheBuddyFromTheLoopDraw() {
        guard let loopDrawAwayToken else { return }
        self.loopDrawAwayToken = nil
        cursorLoopController.theBuddyFinishedDrawingTheLoop(token: loopDrawAwayToken)
    }

    // MARK: - Scrub by voice

    /// Flies to the current time on the video's line, slides along it to the moment, tells the controller it arrived so the
    /// video seeks, holds there for a moment, and flies back to the mouse. With Reduce Motion on, it fades in at the moment
    /// instead, with no travel. A scrub this buddy already plays, or one for another screen, changes nothing. During the
    /// first-launch welcome the buddy does not fly, and the controller hears the refusal, so the seek runs at once.
    private func startScrubbing(_ scrubRequest: CursorScrubRequest) {
        guard playingScrubID != scrubRequest.scrubID,
              targetDisplayIsThisScreen(scrubRequest.displayFrame) else { return }
        guard !showWelcome || welcomeText.isEmpty else {
            // The welcome holds the buddy, so it does not fly, and the request clears now: while it is set, every screen
            // hides its buddy.
            cursorScrubController.overlayRefused(scrubID: scrubRequest.scrubID)
            return
        }
        // The buddy sits beside the point as it does beside a pointed element, so its tip touches the line, and stays 20
        // points inside the screen as a pointing does, for a line on the screen's bottom edge.
        func besideThePoint(_ screenPoint: CGPoint) -> CGPoint {
            let pointInSwiftUI = convertScreenPointToSwiftUICoordinates(screenPoint)
            return CGPoint(
                x: max(20, min(pointInSwiftUI.x + 8, screenFrame.width - 20)),
                y: max(20, min(pointInSwiftUI.y + 12, screenFrame.height - 20))
            )
        }
        let scrubID = scrubRequest.scrubID
        let momentInSwiftUI = convertScreenPointToSwiftUICoordinates(scrubRequest.momentPoint)
        // A scrub takes the buddy from a loop it was drawing, whose line then shows whole.
        landTheLoopDrawAtOnce(sendingTheBuddyBack: false)
        playingScrubID = scrubID
        buddyIsFrozenWhereItStopped = false
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        currentTargetHoldsUntilReleased = false
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        endTheLandingRing()
        pointedTargetCenter = momentInSwiftUI
        let arriveAtTheMoment = {
            guard self.playingScrubID == scrubID else { return }
            self.holdAtTheScrubMoment(scrubID: scrubID)
        }
        switch cursorScrubMotion(reduceMotionIsOn: reduceMotionIsOn) {
        case .fadeAtTheMoment:
            // The flight's Reduce Motion form is the fade, so this flight fades in at the moment.
            animateBezierFlightArc(to: besideThePoint(scrubRequest.momentPoint), onComplete: arriveAtTheMoment)
        case .flyThenSlide:
            animateBezierFlightArc(to: besideThePoint(scrubRequest.startPoint)) {
                guard self.playingScrubID == scrubID else { return }
                self.slideAlongTheScrubLine(to: besideThePoint(scrubRequest.momentPoint), onComplete: arriveAtTheMoment)
            }
        }
    }

    /// Slides the buddy in a straight line along the video's line, paced like the Point move, with its pointer angle, so it
    /// reads as the cursor dragging the playhead.
    private func slideAlongTheScrubLine(to destination: CGPoint, onComplete: @escaping () -> Void) {
        navigationAnimationTimer?.invalidate()
        let startPosition = cursorPosition
        let slideDistance = hypot(destination.x - startPosition.x, destination.y - startPosition.y)
        let pointMoveCurve = DS.Move.point.curve
        let slideDurationSeconds = pointMoveCurve.seconds(travelingPoints: slideDistance)
        let slideStartDate = Date()
        triangleRotationDegrees = -35.0
        buddyFlightSpeedShare = 0
        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let elapsedSeconds = Date().timeIntervalSince(slideStartDate)
            guard elapsedSeconds < slideDurationSeconds else {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = destination
                onComplete()
                return
            }
            let easedSlideProgress = pointMoveCurve.progress(atSeconds: elapsedSeconds, travelingPoints: slideDistance)
            self.cursorPosition = CGPoint(
                x: startPosition.x + (destination.x - startPosition.x) * easedSlideProgress,
                y: startPosition.y + (destination.y - startPosition.y) * easedSlideProgress
            )
        }
    }

    /// The buddy is on the moment: the landing ring marks it, the video seeks, and after a short hold the buddy flies back.
    private func holdAtTheScrubMoment(scrubID: UUID) {
        buddyNavigationMode = .pointingAtTarget
        triangleRotationDegrees = -35.0
        landingRing = CursorLandingRing(center: pointedTargetCenter, landedAt: Date(), endedAt: nil)
        cursorScrubController.cursorReachedTheMoment(scrubID: scrubID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondsTheScrubHoldsAtTheMoment) {
            guard self.playingScrubID == scrubID, self.buddyNavigationMode == .pointingAtTarget else { return }
            self.startFlyingBackToCursor()
        }
    }

    /// Long enough to see the video jump under the cursor before it leaves.
    private static let secondsTheScrubHoldsAtTheMoment: Double = 0.7

    /// The scrub ends here: the buddy is back at the mouse, or a pointing took over.
    private func endThePlayingScrub() {
        guard let playingScrubID else { return }
        self.playingScrubID = nil
        cursorScrubController.overlayFinished(scrubID: playingScrubID)
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

// Manager for overlay windows - creates one per screen so the cursor
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
