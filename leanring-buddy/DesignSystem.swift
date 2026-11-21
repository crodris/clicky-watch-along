//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system using a blue accent palette on dark surfaces,
//  with a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.
        // Higher surfaces are lighter, creating a sense of depth.

        /// The deepest background — used for the main app window fill.
        static let background = Color(hex: "#101211")

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        static let surface1 = Color(hex: "#171918")

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        static let surface2 = Color(hex: "#202221")

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        static let surface3 = Color(hex: "#272A29")

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        static let surface4 = Color(hex: "#2E3130")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = Color(hex: "#373B39")

        /// Strong border — used for focused inputs, hovered card outlines.
        static let borderStrong = Color(hex: "#444947")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(hex: "#ECEEED")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#ADB5B2")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#6B736F")

        /// Text used on top of the accent fill (#2563eb blue), like the primary button label.
        /// White on #2563eb achieves ~5.1:1 contrast — WCAG AA compliant.
        /// White on #1d4ed8 hover achieves ~6.5:1 — also WCAG AA compliant.
        static let textOnAccent: Color = .white

        // ── Tailwind Blue Scale ─────────────────────────────────────
        // Full Tailwind CSS v4 blue palette for consistent blue usage.
        //
        // Usage guide:
        //   50–100  → Very subtle tinted backgrounds (selected rows, hover fills on dark surfaces)
        //   200–300 → Light text/icons on dark backgrounds, disabled states
        //   400     → Bright accent text, links, icons, chat user bubbles
        //   500     → Mid-tone fills, badges, secondary buttons
        //   600     → Primary action fills (buttons, toggles) — main accent
        //   700     → Hover/pressed state for primary actions
        //   800–900 → Deep backgrounds, dark overlays, header bars
        //   950     → Deepest blue — near-black tinted backgrounds

        static let blue50  = Color(hex: "#eff6ff")
        static let blue100 = Color(hex: "#dbeafe")
        static let blue200 = Color(hex: "#bfdbfe")
        static let blue300 = Color(hex: "#93c5fd")
        static let blue400 = Color(hex: "#60a5fa")
        static let blue500 = Color(hex: "#3b82f6")
        static let blue600 = Color(hex: "#2563eb")
        static let blue700 = Color(hex: "#1d4ed8")
        static let blue800 = Color(hex: "#1e40af")
        static let blue900 = Color(hex: "#1e3a8a")
        static let blue950 = Color(hex: "#172554")

        // ── Status Line Palettes ────────────────────────────────────
        // Tailwind CSS v4 purple, orange, green, pink, and sky shades for the status label's
        // lines (LiveSceneStatusLine). Most lines use their hue's shades this way:
        //   500  → icon color        700  → text and deep icon strokes
        //   300  → light strokes     400  → letter highlight
        //   100 or 200 → pale fills  50   → wash behind the icon
        // The pink line has no 500, so it uses 400 for the icon and 300 for the highlight.
        // The pop-out line uses the blue scale above.

        static let purple50  = Color(hex: "#faf5ff")
        static let purple100 = Color(hex: "#f3e8ff")
        static let purple300 = Color(hex: "#d8b4fe")
        static let purple400 = Color(hex: "#c084fc")
        static let purple500 = Color(hex: "#a855f7")
        static let purple700 = Color(hex: "#7e22ce")

        static let orange50  = Color(hex: "#fff7ed")
        static let orange200 = Color(hex: "#fed7aa")
        static let orange300 = Color(hex: "#fdba74")
        static let orange400 = Color(hex: "#fb923c")
        static let orange500 = Color(hex: "#f97316")
        static let orange700 = Color(hex: "#c2410c")

        static let green50  = Color(hex: "#f0fdf4")
        static let green100 = Color(hex: "#dcfce7")
        static let green300 = Color(hex: "#86efac")
        static let green400 = Color(hex: "#4ade80")
        static let green500 = Color(hex: "#22c55e")
        static let green700 = Color(hex: "#15803d")

        static let pink50  = Color(hex: "#fdf2f8")
        static let pink100 = Color(hex: "#fce7f3")
        static let pink300 = Color(hex: "#f9a8d4")
        static let pink400 = Color(hex: "#f472b6")
        static let pink700 = Color(hex: "#be185d")

        static let sky50  = Color(hex: "#f0f9ff")
        static let sky100 = Color(hex: "#e0f2fe")
        static let sky300 = Color(hex: "#7dd3fc")
        static let sky400 = Color(hex: "#38bdf8")
        static let sky500 = Color(hex: "#0ea5e9")
        static let sky700 = Color(hex: "#0369a1")

        static let teal50  = Color(hex: "#f0fdfa")
        static let teal100 = Color(hex: "#ccfbf1")
        static let teal300 = Color(hex: "#5eead4")
        static let teal400 = Color(hex: "#2dd4bf")
        static let teal500 = Color(hex: "#14b8a6")
        static let teal700 = Color(hex: "#0f766e")

        // Lime, for the experiment agent, which needs a lab green that reads apart from teal and green.
        static let lime500 = Color(hex: "#84cc16")
        static let lime700 = Color(hex: "#4d7c0f")

        // ── Accent (derived from blue scale) ───────────────────────
        // The primary fill is Blue 600; hover darkens to Blue 700.

        /// Accent fill — used for solid button backgrounds.
        /// #2563eb → ~5.1:1 contrast with white text (WCAG AA).
        static let accent = blue600

        /// Accent hover — slightly darker blue for hover state.
        /// #1d4ed8 → ~6.5:1 contrast with white text (WCAG AA+).
        static let accentHover = blue700

        /// Accent text — bright blue used for accent-colored text and icons
        /// on dark backgrounds (links, active nav items, highlighted labels).
        static let accentText = blue400

        /// Very subtle accent tint — used for selected item backgrounds (e.g. current step
        /// in the sidebar). Low opacity so it doesn't overpower.
        static let accentSubtle = blue500.opacity(0.10)

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages, close button hover.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#F2555A")   // Radix Red 10

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = Color(hex: "#FF6369")    // Radix Red 11

        /// Success — checkmarks, granted status, completion indicators.
        /// Independent green so success states are visually distinct from the blue accent.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// Warning text — brighter variant for text on dark backgrounds.
        static let warningText = Color(hex: "#F1A10D")        // Radix Amber 11

        /// Info/feature highlight — used for prompt card headers, code highlights.
        /// Lighter than accentText so informational elements are visually distinct
        /// from interactive accent-colored elements.
        static let info = Color(hex: "#70B8FF")               // Radix Blue 9

        /// Inline code text color — slightly brighter blue for monospace code snippets.
        static let codeText = Color(hex: "#9DC2FF")           // Radix Blue 11 variant

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The blue cursor/bubble color used in OverlayWindow.
        /// Kept distinct from the accent since it serves a different purpose
        /// (screen overlay vs in-app UI).
        static let overlayCursorBlue = Color(hex: overlayCursorBlueHex)

        /// The same blue as text, for the frame pop-out page, which cannot read a SwiftUI Color.
        static let overlayCursorBlueHex = "#3380ff"

        // ── Tether materials ─────────────────────────────────────────
        // The two materials every Tether surface is drawn in (`TetherMaterials.swift`). They never follow the theme: the
        // theme's accent is the only color a surface takes from it.

        /// The top of the Card's surface gradient.
        static let cardSurfaceTop = Color(hex: "#121419")

        /// The bottom of the Card's surface gradient.
        static let cardSurfaceBottom = Color(hex: "#171a21")

        /// The Callout's solid surface. Solid, not blurred: a blur turned it mid gray on a white page, where white words
        /// fell from 17.9 to 5.4 contrast in the phase-zero prototype.
        static let calloutSurface = Color(hex: "#14171e")

        /// The ink of an icon on an accent-filled disc. Near-black on every accent, Clicky blue included, since white on
        /// `#3380ff` is only 3.9 contrast and this is 5.3.
        static let inkOnAccent = Color(hex: "#0b0c0e")

        // ── Settings Dial ────────────────────────────────────────────

        /// The dial's plate and the first-run hint's background, a near-black blue.
        static let settingsDialPlate = Color(hex: "#0a0c12")

        /// An unselected token's fill, and the fill of a Model pill.
        static let settingsDialToken = Color(hex: "#171b24")

        /// Dark text on the agent count's white badge, and the Random ball's outline.
        static let settingsDialDarkInk = Color(hex: "#111111")

        /// The Random ball in the Team fan.
        static let settingsDialRandomBall = Color(hex: "#374151")

        // ── Background Agents ────────────────────────────────────────

        /// The color of a study guide agent. Each new agent kind gets its own color here.
        static let backgroundAgentStudyGuideAmber = Color(hex: "#FFB020")

        /// The study guide agent's chip letters. Tailwind Amber 700, the status lines' 700 for text.
        static let backgroundAgentStudyGuideAmberText = Color(hex: "#b45309")

        /// The color of a 3D model agent. Tailwind Violet 400, apart from the cursor's blue and the guide's amber.
        static let backgroundAgentThreeDModelViolet = Color(hex: "#a78bfa")

        /// The 3D model agent's chip letters. Tailwind Violet 700.
        static let backgroundAgentThreeDModelVioletText = Color(hex: "#6d28d9")

        /// The color of a general task agent. Tailwind Teal 400, apart from the cursor's blue, the guide's amber, and the model's violet.
        static let backgroundAgentTaskTeal = Color(hex: "#2dd4bf")

        /// The task agent's chip letters. Tailwind Teal 700.
        static let backgroundAgentTaskTealText = Color(hex: "#0f766e")

        /// The opaque dark track of an agent token's progress ring, so the ring reads on a light menu bar and a bright wallpaper.
        static let agentTokenTrack = Color(hex: "#2b303b")

        /// The dark face of a token that shows a kind's triangle, and of the "+N" disc.
        static let agentTokenFace = Color(hex: "#171b24")

        /// A team player's name on the ending chip. Tailwind Gray 900, since a pale team color fails as text.
        static let backgroundAgentPlayerNameText = Color(hex: "#111827")

        /// The color of an experiment agent. Lime reads apart from the model's violet and the task's teal.
        static let backgroundAgentExperimentLime = lime500

        /// The experiment agent's chip letters. Tailwind Lime 700.
        static let backgroundAgentExperimentLimeText = lime700

        // ── Floating Button Gradient ─────────────────────────────────

        /// The floating session button gradient colors (unchanged from original —
        /// this gradient is intentionally distinct from the rest of the palette
        /// to make the floating button stand out as a "jewel" on the desktop).
        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Help Chat ──────────────────────────────────────────────

        /// User message bubble background in the help chat.
        /// Blue 800 — deep blue that's clearly distinct from the dark surface
        /// while keeping white text highly readable (~9:1 contrast).
        static let helpChatUserBubble = blue800

        /// Slightly lighter variant for hover/pressed states on user bubbles.
        static let helpChatUserBubbleHover = blue700

        /// Footer/backdrop behind the floating help chat.
        /// Slightly lighter than the main window background so the chat zone reads
        /// as a distinct docked surface even before the pill input is visible.
        static let helpChatBackdrop = Color(hex: "#212121")

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = 12
        /// The Tether Card (`tetherCard()`).
        static let card: CGFloat = 14
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - Tether type scale

    /// The Tether type scale: four sizes (17, 15, 13, 11) in six styles. Every Tether surface sets its text in one of them,
    /// such as `Text("Popping it out").font(DS.TypeScale.voice.font)`. Set a Data style string with `Text(verbatim:)`, since
    /// SwiftUI turns a URL in a plain `Text` into a blue link.
    /// (`DS.Type` would be Swift's metatype of `DS`, so the scale has this name.)
    enum TypeScale: CaseIterable {
        /// 17/700 rounded: a Card's heading, such as "Set up Clicky".
        case headline
        /// 15/700 rounded: anything Clicky says on a Callout, such as "Popping it out".
        case voice
        /// 13/600: a row's name, such as "Task · Booster catch". The spec's 650 is not a system weight, so semibold.
        case title
        /// 13/400: a row's line, such as "Reading nasa.gov for the booster catch numbers".
        case body
        /// 11/500: a hint under a control.
        case caption
        /// 11 monospaced: a link, a path, or a raw value.
        case data

        var pointSize: CGFloat {
            switch self {
            case .headline: return 17
            case .voice: return 15
            case .title, .body: return 13
            case .caption, .data: return 11
            }
        }

        var weight: Font.Weight {
            switch self {
            case .headline, .voice: return .bold
            case .title: return .semibold
            case .body, .data: return .regular
            case .caption: return .medium
            }
        }

        var design: Font.Design {
            switch self {
            case .headline, .voice: return .rounded
            case .title, .body, .caption: return .default
            case .data: return .monospaced
            }
        }

        var font: Font { .system(size: pointSize, weight: weight, design: design) }
    }

    // MARK: - Tether moves

    /// The ten named moves of the Tether redesign. Every animated change on a Tether surface is one of them, so a surface
    /// asks for a move by name, such as `withAnimation(DS.Move.pop.animation(reduceMotionIsOn: reduceMotion)) { ... }`, and
    /// never writes its own duration or spring. Each move has a `curve` and a Reduce Motion form (`reduceMotionForm`), which
    /// keeps the change of state and drops the travel.
    ///
    /// A move that crosses windows (Send, and a Card's Glide out of a disc and its Glide close back into it) runs on the shared
    /// carrier panel (`TetherCarrier`), which samples the same curve for Core Animation.
    ///
    /// Today's timings, and the move each becomes as the Tether PRs adopt these tokens:
    /// - The pointing bubble's spring(0.4, 0.6) scale and 0.5 s fade: Pop.
    /// - The status label's and chip's 0.2 s ease-out at scale 0.4: Pop in, and the Pop played backward at 0.7x speed out.
    /// - The dial token's, disc hover's, fan's, and fan ball's 0.1 to 0.14 s ease-outs and spring(0.18, 0.8): Snap.
    /// - The dial's spring(0.22, 0.78) open: Glide. Its fan items' spring(0.26, 0.72) with a 14 ms stagger: Pop.
    /// - The dial's, agent list's, studio's, and panel's close, which is `orderOut` today: Glide close at 0.7x.
    /// - A disc's phase and check, 0.25 s ease-out: Pop for the badge, Snap for the ring.
    /// - The ring cue's 0.15 and 0.35 s crossfades and the loop's 0.3 s fade: one fade, `fadeSeconds`.
    /// - The pointing flight's 0.6 to 1.4 s smoothstep with a peak scale of 1.3: Point, with a stretch of 1.15 and a
    ///   landing ring.
    /// - The agent serve's 0.5 s keyframes: Send, on the carrier panel.
    /// - The welcome fade's and onboarding video's 2 s eases: Glide over 0.6 s, on the first run only.
    /// - The scene pages' CSS (0.15, 0.3, and 0.6 s labels, the 0.45 s shake, the 0.7 s burst, the 0.4 s lift): Snap, Pop,
    ///   Shake, a hop, and Glide.
    /// - The ring's dots (1.2 s), the loop's spark (2.2 s), and the status icons (1.4 to 3.2 s) are ambient loops, not
    ///   moves, and keep their timings.
    enum Move: CaseIterable {
        /// Work leaves the cursor for its disc: the serve, a smoothstep arc over 0.5 s.
        case send
        /// A result comes back: a spark runs from the disc along the screen edge to the cursor, then the chip pops.
        case bringBack
        /// The pointing flight, paced by its distance from 0.6 to 1.4 s, with a stretch and a landing ring.
        case point
        /// A scene grows out of the media rect over 1.6 s (`scene-rise.js`).
        case rise
        /// A pop-out flattens back into the video over 0.8 s (`returnToSource` in `frame-popout.html`).
        case returnToSource
        /// A Callout or a badge appears from its anchor.
        case pop
        /// A Card opens out of its origin with the tether line, and closes back into it at `glideCloseTimeFactor`.
        case glide
        /// Hover, selection, and press.
        case snap
        /// An interrupt: speech, chips, and status lines shrink into the cursor in 180 ms. Scenes, the studio, and lists stay.
        case recall
        /// A failure or a wrong quiz answer: one small shake. Never alone, since Reduce Motion drops it: the red color and
        /// the cross badge carry the failure.
        case shake

        var curve: MoveCurve {
            switch self {
            case .send: return .timed(seconds: 0.5, bezier: .smoothstep)
            case .bringBack: return .timed(seconds: 0.6, bezier: .smoothstep)
            case .point: return .pacedByDistance(pointsPerSecond: 800, shortestSeconds: 0.6, longestSeconds: 1.4, bezier: .smoothstep)
            case .rise: return .timed(seconds: 1.6, bezier: .cubicEaseInOut)
            case .returnToSource: return .timed(seconds: 0.8, bezier: .cubicEaseInOut)
            case .pop: return .spring(response: 0.32, dampingFraction: 0.68)
            case .glide: return .spring(response: 0.42, dampingFraction: 0.9)
            case .snap: return .spring(response: 0.18, dampingFraction: 0.86)
            case .recall: return .timed(seconds: 0.18, bezier: .quadraticEaseIn)
            case .shake: return .decayingShake(seconds: 0.45, amplitudePoints: 7, cyclesPerSecond: 3.5, decayPerSecond: 7)
            }
        }

        /// What the move becomes with Reduce Motion on: a flight fades in at its target and leaves a still ring there,
        /// a Card or Callout crossfades in place, and the shake does nothing.
        var reduceMotionForm: ReducedMotionForm {
            switch self {
            case .send, .bringBack, .point: return .fadeAtTheTargetLeavingAStillRing(seconds: 0.2)
            case .rise, .returnToSource, .pop, .glide, .snap, .recall: return .crossfade(seconds: Self.fadeSeconds)
            case .shake: return .none
            }
        }

        /// The SwiftUI animation for this move. Nil when the change should apply with no animation: the shake, which moves
        /// an offset (`curve.progress`) instead of easing a value, and any move whose Reduce Motion form is none.
        /// - `travelingPoints`: how far the thing moves, which only the Point move's duration depends on.
        func animation(reduceMotionIsOn: Bool, travelingPoints: Double = 0) -> SwiftUI.Animation? {
            if reduceMotionIsOn {
                switch reduceMotionForm {
                case .crossfade(let seconds), .fadeAtTheTargetLeavingAStillRing(let seconds): return .easeOut(duration: seconds)
                case .none: return nil
                }
            }
            return curve.animation(travelingPoints: travelingPoints)
        }

        // The shapes the moves take, shared by every surface that plays them.

        /// The one fade every crossfade uses, the ring cue's included.
        static let fadeSeconds: Double = 0.15
        /// Pop grows from this scale, pivoting on the Callout's tail tip (`TetherCalloutShape.tailTip`).
        static let popStartScale: CGFloat = 0.4
        /// Pop's opacity reaches 1 in this time, well before its spring settles.
        static let popFadeInSeconds: Double = 0.12
        /// A Glide grows from this scale at its origin, so it reads as coming out of a 22 point disc.
        static let glideStartScale: CGFloat = 0.07
        /// A Glide close plays the open's spring this many times as long, so a close is quicker than an open.
        static let glideCloseTimeFactor: Double = 0.7
        /// Snap scales a pressed control to this.
        static let snapPressScale: CGFloat = 0.97
        /// Recall shrinks to this scale as it fades into the cursor.
        static let recallEndScale: CGFloat = 0.1
        /// Point stretches the cursor to this length along its flight at the fastest point.
        static let pointStretch: CGFloat = 1.15
        /// The tether line's width, in the origin's color.
        static let tetherLineWidth: CGFloat = 1
        /// The tether line fades out over this time after the carried thing lands.
        static let tetherFadeSeconds: Double = 0.25
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }
}

// MARK: - Move curves

/// What a move does with Reduce Motion on (`DS.Move.reduceMotionForm`). Every form keeps the change of state.
nonisolated enum ReducedMotionForm: Equatable, Sendable {
    /// Fade in place over this time, with no scale and no travel.
    case crossfade(seconds: Double)
    /// A flight: no travel, a fade in at the target over this time, and a still ring left on the target.
    case fadeAtTheTargetLeavingAStillRing(seconds: Double)
    /// Nothing moves. Only the shake has this, so a failure never relies on it alone.
    case none

    /// How long the fade takes, and 0 when nothing animates.
    var fadeSeconds: Double {
        switch self {
        case .crossfade(let seconds), .fadeAtTheTargetLeavingAStillRing(let seconds): return seconds
        case .none: return 0
        }
    }
}

/// A cubic bezier easing from (0, 0) to (1, 1): the curve CSS `cubic-bezier`, SwiftUI's `timingCurve`, and
/// `CAMediaTimingFunction(controlPoints:)` take, so a move eases the same way in each.
nonisolated struct MoveBezier: Equatable, Sendable {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    /// Exactly smoothstep, `3t² - 2t³`, the curve the serve and the pointing flight use: its x control points are evenly
    /// spaced, so x is the time itself.
    static let smoothstep = MoveBezier(x1: 1.0 / 3, y1: 0, x2: 2.0 / 3, y2: 1)
    /// Exactly `t²`: it starts slowly and speeds up, as a Recall does into the cursor.
    static let quadraticEaseIn = MoveBezier(x1: 1.0 / 3, y1: 0, x2: 2.0 / 3, y2: 1.0 / 3)
    /// The rise's and the pop-out return's ease in and out, `cubic-bezier(0.65, 0, 0.35, 1)`.
    static let cubicEaseInOut = MoveBezier(x1: 0.65, y1: 0, x2: 0.35, y2: 1)

    /// The eased progress after `linearProgress` of the time, from 0 to 1. Progress outside 0 to 1 is clamped.
    func progress(atLinearProgress linearProgress: Double) -> Double {
        guard linearProgress > 0 else { return 0 }
        guard linearProgress < 1 else { return 1 }
        // With the x control points at a third and two thirds, x is the time itself, so the curve needs no search and
        // smoothstep comes out exact.
        if x1 == 1.0 / 3 && x2 == 2.0 / 3 {
            return Self.coordinate(atParameter: linearProgress, firstControl: y1, secondControl: y2)
        }
        // The curve's x grows with its parameter, since both x control points lie in 0 to 1, so halving the range 50 times
        // finds the parameter whose x is the time to far below a pixel.
        var lowParameter = 0.0
        var highParameter = 1.0
        for _ in 0..<50 {
            let middleParameter = (lowParameter + highParameter) / 2
            if Self.coordinate(atParameter: middleParameter, firstControl: x1, secondControl: x2) < linearProgress {
                lowParameter = middleParameter
            } else {
                highParameter = middleParameter
            }
        }
        return Self.coordinate(atParameter: (lowParameter + highParameter) / 2, firstControl: y1, secondControl: y2)
    }

    /// One coordinate of the curve from 0 to 1 through the two control values.
    private static func coordinate(atParameter parameter: Double, firstControl: Double, secondControl: Double) -> Double {
        let remaining = 1 - parameter
        return 3 * remaining * remaining * parameter * firstControl + 3 * remaining * parameter * parameter * secondControl + parameter * parameter * parameter
    }
}

/// How a move's value travels from its start (0) to its end (1) over time. SwiftUI plays it through `animation`, and the
/// carrier samples `progress` into Core Animation keyframes, so both draw the same curve.
nonisolated enum MoveCurve: Equatable, Sendable {
    /// A damped spring, with the meaning SwiftUI's `spring(response:dampingFraction:)` gives these two values. A damping
    /// fraction of 1 or more never overshoots and is played as critically damped.
    case spring(response: Double, dampingFraction: Double)
    /// A fixed time along a bezier.
    case timed(seconds: Double, bezier: MoveBezier)
    /// A time that grows with the distance traveled, held between the shortest and longest time.
    case pacedByDistance(pointsPerSecond: Double, shortestSeconds: Double, longestSeconds: Double, bezier: MoveBezier)
    /// An offset that swings either way and dies out. Its `progress` is the signed share of `amplitudePoints`, from -1 to 1,
    /// and it is 0 at the start and at the end.
    case decayingShake(seconds: Double, amplitudePoints: Double, cyclesPerSecond: Double, decayPerSecond: Double)

    /// A spring has settled once the envelope its swing decays inside falls under this share of the whole move. The swing
    /// itself can be up to `1 / sqrt(1 - dampingFraction²)` times the envelope, about 0.5% of the move for the Glide, which
    /// is about a point at the far edge of a 300 point card when the move snaps to its end.
    private static let springSettledShare = 0.002

    /// How long the move takes. A spring's time is how long it takes to settle.
    /// - `travelingPoints`: the distance moved, which only a move paced by distance reads.
    func seconds(travelingPoints: Double = 0) -> Double {
        switch self {
        case .spring(let response, let dampingFraction):
            let naturalFrequency = 2 * Double.pi / response
            guard dampingFraction < 1 else {
                // Critically damped, the distance left is (1 + ωt)e^(-ωt). It has no closed form for its time, so step ωt in
                // hundredths until the distance falls under the settled share.
                var scaledTime = 0.0
                while (1 + scaledTime) * exp(-scaledTime) >= Self.springSettledShare { scaledTime += 0.01 }
                return scaledTime / naturalFrequency
            }
            return -log(Self.springSettledShare) / (dampingFraction * naturalFrequency)
        case .timed(let seconds, _):
            return seconds
        case .pacedByDistance(let pointsPerSecond, let shortestSeconds, let longestSeconds, _):
            return min(max(travelingPoints / pointsPerSecond, shortestSeconds), longestSeconds)
        case .decayingShake(let seconds, _, _, _):
            return seconds
        }
    }

    /// The share of the move done `elapsedSeconds` after it started: 0 before the start, exactly 1 from `seconds` on, and
    /// a little past 1 while a spring overshoots. A shake's is its signed offset share instead (see `decayingShake`).
    func progress(atSeconds elapsedSeconds: Double, travelingPoints: Double = 0) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        let totalSeconds = seconds(travelingPoints: travelingPoints)
        switch self {
        case .spring(let response, let dampingFraction):
            guard elapsedSeconds < totalSeconds else { return 1 }
            let naturalFrequency = 2 * Double.pi / response
            guard dampingFraction < 1 else {
                return 1 - (1 + naturalFrequency * elapsedSeconds) * exp(-naturalFrequency * elapsedSeconds)
            }
            let dampedFrequency = naturalFrequency * (1 - dampingFraction * dampingFraction).squareRoot()
            let envelope = exp(-dampingFraction * naturalFrequency * elapsedSeconds)
            return 1 - envelope * (cos(dampedFrequency * elapsedSeconds)
                + dampingFraction * naturalFrequency / dampedFrequency * sin(dampedFrequency * elapsedSeconds))
        case .timed(_, let bezier), .pacedByDistance(_, _, _, let bezier):
            return bezier.progress(atLinearProgress: elapsedSeconds / totalSeconds)
        case .decayingShake(_, _, let cyclesPerSecond, let decayPerSecond):
            guard elapsedSeconds < totalSeconds else { return 0 }
            return exp(-decayPerSecond * elapsedSeconds) * sin(2 * Double.pi * cyclesPerSecond * elapsedSeconds)
        }
    }

    /// The same curve played `factor` times as long, as a Glide close plays the open at 0.7x.
    func timeScaled(by factor: Double) -> MoveCurve {
        switch self {
        case .spring(let response, let dampingFraction):
            return .spring(response: response * factor, dampingFraction: dampingFraction)
        case .timed(let seconds, let bezier):
            return .timed(seconds: seconds * factor, bezier: bezier)
        case .pacedByDistance(let pointsPerSecond, let shortestSeconds, let longestSeconds, let bezier):
            return .pacedByDistance(pointsPerSecond: pointsPerSecond / factor, shortestSeconds: shortestSeconds * factor, longestSeconds: longestSeconds * factor, bezier: bezier)
        case .decayingShake(let seconds, let amplitudePoints, let cyclesPerSecond, let decayPerSecond):
            return .decayingShake(seconds: seconds * factor, amplitudePoints: amplitudePoints, cyclesPerSecond: cyclesPerSecond / factor, decayPerSecond: decayPerSecond / factor)
        }
    }

    /// The SwiftUI animation that plays this curve. Nil for a shake, which moves an offset instead of easing a value.
    func animation(travelingPoints: Double = 0) -> SwiftUI.Animation? {
        switch self {
        case .spring(let response, let dampingFraction):
            // SwiftUI would play a damping fraction above 1 as an overdamped spring, slower than the carrier's critically
            // damped samples, so both get the same curve.
            return .spring(response: response, dampingFraction: min(dampingFraction, 1))
        case .timed(_, let bezier), .pacedByDistance(_, _, _, let bezier):
            return .timingCurve(bezier.x1, bezier.y1, bezier.x2, bezier.y2, duration: seconds(travelingPoints: travelingPoints))
        case .decayingShake:
            return nil
        }
    }
}

// MARK: - Button Styles

/// Primary button — the main call-to-action per screen.
/// Accent-colored background with white text. One per view maximum.
/// Used for: "start"/"resume", "let's go", "continue", "verify completion".
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    // Separate state for the scale expansion so it animates on a slower,
    // more gradual timeline (0.6s) than the background color snap (0.15s).
    @State private var isHoverScaleExpanded = false

    // Whether the hover glow shadow is active. Builds up gradually (0.6s)
    // on hover entry, fades out faster (0.3s) on exit.
    @State private var isHoverGlowActive = false

    // Continuously toggles while hovered to drive a gentle breathing pulse
    // in the glow shadow. Creates a living, organic feel — like the button
    // is softly glowing, not just statically lit.
    @State private var isGlowBreathingIn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, isFullWidth ? 0 : 20)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            // Hover glow — builds up gradually, then gently breathes while hovered.
            // The breathing oscillates opacity and radius on a slow 2.5s loop,
            // creating a candle-flame-like "alive" quality rather than a static highlight.
            .shadow(
                color: DS.Colors.accent.opacity(
                    isHoverGlowActive ? (isGlowBreathingIn ? 0.32 : 0.18) : 0
                ),
                radius: isHoverGlowActive ? (isGlowBreathingIn ? 16 : 10) : 0
            )
            // Hover: gradually expand to 1.03. Press: snap down to 0.97.
            .scaleEffect(configuration.isPressed ? 0.97 : (isHoverScaleExpanded ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                // Background color — fast snap so the button feels responsive
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }

                // Scale — slow, gradual expansion (like the button is swelling)
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverScaleExpanded = hovering
                }

                // Glow — builds up gradually on entry, fades faster on exit
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverGlowActive = hovering
                }

                // Breathing glow loop — gentle pulse while hovered.
                // The 2.5s cycle keeps it feeling organic, not mechanical.
                if hovering {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        isGlowBreathingIn = true
                    }
                } else {
                    // Override the repeating animation with a finite one to stop cleanly
                    withAnimation(.easeOut(duration: 0.3)) {
                        isGlowBreathingIn = false
                    }
                }

                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            // Pressed: brighten slightly beyond hover
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — low-emphasis actions with subtle hover background.
/// Transparent at rest, shows surface fill on hover. Used for: navigation
/// links, sidebar items, medium-low emphasis actions.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Outlined button — medium emphasis, used where a border helps define
/// the button's bounds. Used for: display selector, copy prompt.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circular button for utility actions.
/// Used for: close button (x), send message, small toolbar actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            // Cursor change via AppKit cursor rects — more reliable than NSCursor.push/pop
            // because cursor rects are managed at the window level and don't conflict
            // with SwiftUI's internal cursor handling.
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                // Show the tooltip after a delay (like native tooltips), hide immediately
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            // Custom styled tooltip — positioned above the button with enough gap
            // to not overlap the button. Horizontally aligned based on tooltipAlignment
            // so tooltips near window edges don't clip outside the visible area.
            // Uses .allowsHitTesting(false) so the tooltip doesn't interfere
            // with the button's hover state.
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.Colors.surface3.opacity(0.85))
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Applies the primary button style (accent-colored CTA).
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the secondary button style (surface-colored supporting action).
    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the tertiary/ghost button style (subtle hover background).
    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    /// Applies the text-only button style (no background ever, just color change).
    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    /// Applies the outlined button style (bordered, medium emphasis).
    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the destructive button style (red-tinted danger action).
    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    /// Applies the icon-only button style (compact circle).
    /// `tooltipAlignment` controls where the tooltip sits horizontally relative to the button:
    /// `.leading` for left-edge buttons, `.trailing` for right-edge buttons, `.center` for middle.
    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Buddy Composer Visual Style

enum BuddyComposerVisualStyle {
    static let waveformLeadingColor = Color(hex: "#F3FBFF")
    static let waveformTrailingColor = Color(hex: "#8FD2FF")
    static let waveformGlowColor = Color(hex: "#AEE3FF")
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
