//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized dark-surface design tokens: colors, corner radii, the type
//  scale, the moves, and the pointer cursor modifier. Every view reads them
//  from here.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.surface2`, `DS.CornerRadius.row`, `DS.TypeScale.caption.font`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Grays ────────────────────────────────────────────────────
        // One family: the Card's blue-gray (hue about 222, saturation 16 to 22 percent), so every panel, card, button, and
        // track reads as one set of surfaces. Layered surfaces from deepest to most elevated. Higher surfaces are lighter,
        // creating a sense of depth. `GrayFamilyTests` pins each one's hue to the Card's, and their order by lightness.

        /// The deepest background, for an input field or a well set into a surface.
        static let ground = Color(hex: "#101216")

        /// First elevation layer: the Card's own bottom color (`cardSurfaceBottom`), for a box inside a Card and the face of a
        /// dark disc or token.
        static let surface1 = Color(hex: "#171A21")

        /// Second elevation layer: a control at rest on the Card, the lit row of the next setup step.
        static let surface2 = Color(hex: "#1C2029")

        /// Third elevation layer: a secondary button at rest, a track, a key cap, a hovered row.
        static let surface3 = Color(hex: "#232833")

        /// Fourth elevation layer: a hovered secondary button, the dark track of an agent token's ring.
        static let surface4 = Color(hex: "#2B303B")

        // ── Borders ──────────────────────────────────────────────────

        /// A card's outline, a divider, an input field's border.
        static let border = Color(hex: "#343A49")

        /// The Card's own edge: a 1 point white line at 8 percent.
        static let edge = Color.white.opacity(0.08)

        /// The edge of a control the pointer is over.
        static let edgeHover = Color.white.opacity(0.18)

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text - main body text, titles, headings.
        static let textPrimary = Color(hex: "#EDEEF0")

        /// Secondary text - descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#AEB3C0")

        /// Tertiary text - very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#687187")

        // ── Status Line Accents ─────────────────────────────────────
        // One Tailwind CSS v4 400 step for each status line (`LiveSceneStatusLine.calloutAccent`), which a Callout takes as
        // its accent. The agent palette (`AgentPaletteColor`) and the Quick Look preview's agent swatches read sky and
        // pink too. Every other step of these hues was unused and is gone.

        static let blue400 = Color(hex: "#60a5fa")
        static let purple400 = Color(hex: "#c084fc")
        static let orange400 = Color(hex: "#fb923c")
        static let green400 = Color(hex: "#4ade80")
        static let pink400 = Color(hex: "#f472b6")
        static let sky400 = Color(hex: "#38bdf8")
        static let teal400 = Color(hex: "#2dd4bf")

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions - delete buttons, error messages, close button hover.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#F2555A")   // Radix Red 10

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = Color(hex: "#FF6369")    // Radix Red 11

        /// The dark red a turned-off setup step, a refused name, or a problem banner sits on, with a `destructiveEdge` border.
        static let destructiveSurface = Color(hex: "#2a1517")
        static let destructiveEdge = Color(hex: "#5a2a2e")

        // ── Menu bar panel ─────────────────────────────────────────
        /// The dark tile under the header's cursor, lighter at its upper left.
        static let panelCursorTileTop = Color(hex: "#24324f")
        static let panelCursorTileBottom = Color(hex: "#111620")
        /// The setup checklist's states that are a hue and not a gray: a done step's circle, a turned-off step's circle, and
        /// the green box that suggests a first question. Its grays are `surface2` (the lit row of the next step), `surface3`
        /// (the bar's empty track and an undone step's circle), and `border` (the lit row's edge).
        static let setupDoneCircle = Color(hex: "#173d2f")
        static let setupTurnedOffCircle = Color(hex: "#3a1416")
        static let setupAllSetSurface = Color(hex: "#16261f")
        static let setupAllSetEdge = Color(hex: "#1f5040")

        /// Success - checkmarks, granted status, completion indicators.
        /// Independent green so success states are visually distinct from the blue accent.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Warning - caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// Warning text - brighter variant for text on dark backgrounds.
        static let warningText = Color(hex: "#F1A10D")        // Radix Amber 11

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

        /// The bottom of the Card's surface gradient, the same color as `surface1`.
        static let cardSurfaceBottom = surface1

        /// The Callout's solid surface. Solid, not blurred: a blur turned it mid gray on a white page, where white words
        /// fell from 17.9 to 5.4 contrast in the phase-zero prototype.
        static let calloutSurface = Color(hex: "#14171e")

        /// The fixed ink for icons and text on a fixed fill, such as the approval card's amber disc. Every surface on a
        /// theme accent takes the ink that reads on it (`accentInk` or `Color.inkOnThisFill`), since one ink does not fit
        /// every accent: white on Clicky blue `#3380ff` is only 3.70 contrast.
        static let inkOnAccent = Color(hex: "#0b0c0e")

        /// The ring around the control that holds the keyboard focus in the menu bar panel. It is a fixed light blue, not the
        /// theme's accent, so it reads beside an accent border and on every theme.
        static let keyboardFocusRing = Color(hex: "#8fb6ff")

        // ── Paper ────────────────────────────────────────────────────
        // The material for what the learner keeps (`PaperMaterial.swift`): the quiz recap Card and the Save photo receipt.
        // Paper is opaque and light in light and dark mode alike, so these are fixed colors, never dynamic ones. Live controls,
        // approvals, status lines, and labels over video stay on the dark Card and Callout.

        /// The paper's surface, a warm off-white.
        static let paperSurface = Color(hex: "#F6F5F1")

        /// Body text and titles on paper. 16.4 contrast on `paperSurface`.
        static let paperInk = Color(hex: "#15171C")

        /// Secondary text on paper, such as the kicker's line under a score. 7.4 contrast.
        static let paperInkSecondary = Color(hex: "#4B505B")

        /// Small print on paper: the kicker, the numerals, the colophon. 4.8 contrast, a little darker than the mock's
        /// `#737986`, which reads at only 4.0 at 11 points.
        static let paperInkTertiary = Color(hex: "#676D7A")

        /// The ink of a section rule and of an outlined button's edge: `paperInk` at 13%.
        static let paperHairline = Color(hex: "#15171C").opacity(0.13)

        /// The edge of an outlined paper button while the pointer is on it: `paperInk` at 28%.
        static let paperHairlineHover = Color(hex: "#15171C").opacity(0.28)

        /// A wash over paper for a hovered row or button: `paperInk` at 5%.
        static let paperWash = Color(hex: "#15171C").opacity(0.05)

        /// The paper's own edge, which keeps it apart from a bright page behind it: black at 35%, half a point wide.
        static let paperEdge = Color.black.opacity(0.35)

        /// The label of a button filled with `paperInk`. 17.0 contrast on it.
        static let paperInkButtonLabel = Color(hex: "#F9F9F6")

        // ── Settings Dial ────────────────────────────────────────────

        /// The dial's plate and the first-run hint's background, a near-black blue.
        static let settingsDialPlate = Color(hex: "#0a0c12")

        // ── Background Agents ────────────────────────────────────────

        /// The color of a study guide agent. Each new agent kind gets its own color here.
        static let backgroundAgentStudyGuideAmber = Color(hex: "#FFB020")

        /// The color of a 3D model agent. Tailwind Violet 400, apart from the cursor's blue and the guide's amber.
        static let backgroundAgentThreeDModelViolet = Color(hex: "#a78bfa")

        /// The color of a general task agent. Tailwind Teal 400, apart from the cursor's blue, the guide's amber, and the model's violet.
        static let backgroundAgentTaskTeal = Color(hex: "#2dd4bf")

        /// The color of an experiment agent. Tailwind Lime 500, a lab green that reads apart from the model's violet, the
        /// task's teal, and the done check's green.
        static let backgroundAgentExperimentLime = Color(hex: "#84cc16")

    }

    // MARK: - Corner Radii

    /// Every corner radius a surface draws is one of these steps, by what it is. `tools/design-token-check.py` fails the
    /// build on a radius written as a number anywhere else. A shape drawn to its own geometry, such as a cursor or the
    /// Callout's outline, ends its line with `// design-token-exempt: <why>`.
    enum CornerRadius {
        /// A mark of 16 points or less: a color swatch, a shimmer bar.
        static let swatch: CGFloat = 3
        /// A chip, a tag, a key cap, a text field, a small thumbnail.
        static let chip: CGFloat = 6
        /// A button or a segment of a control (`TetherButton`'s rounded shape).
        static let control: CGFloat = 8
        /// A row, a banner, or a box inside a Card, and a control group that holds `control` segments 2 points in.
        static let row: CGFloat = 10
        /// The Tether Card (`tetherCard()`).
        static let card: CGFloat = 14
        /// Paper (`paperCard()`) and the Save photo receipt. Squarer than the Card, like a printed page.
        static let paper: CGFloat = 8
        /// A capsule or a circle. SwiftUI clamps a radius to half the shorter side.
        static let pill: CGFloat = .infinity
    }

    // MARK: - Tether type scale

    /// The Tether type scale: five sizes (120, 17, 15, 13, 11) in seven styles. The `display` style (120) is for a countdown
    /// that fills a video. Every Tether surface sets its text in one of them,
    /// such as `Text("Popping it out").font(DS.TypeScale.voice.font)`. Set a Data style string with `Text(verbatim:)`, since
    /// SwiftUI turns a URL in a plain `Text` into a blue link.
    /// (`DS.Type` would be Swift's metatype of `DS`, so the scale has this name.)
    enum TypeScale: CaseIterable {
        /// 120/700 rounded: the 3-2-1 countdown over the room art panel's video, read from a few steps back.
        case display
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
            case .display: return 120
            case .headline: return 17
            case .voice: return 15
            case .title, .body: return 13
            case .caption, .data: return 11
            }
        }

        var weight: Font.Weight {
            switch self {
            case .display, .headline, .voice: return .bold
            case .title: return .semibold
            case .body, .data: return .regular
            case .caption: return .medium
            }
        }

        var design: Font.Design {
            switch self {
            case .display, .headline, .voice: return .rounded
            case .title, .body, .caption: return .default
            case .data: return .monospaced
            }
        }

        var font: Font { .system(size: pointSize, weight: weight, design: design) }
    }

    // MARK: - Paper type

    /// The serif styles of paper (`paperCard()`), in New York, the system serif, so nothing is bundled. Everything else on
    /// paper is set in the Tether type scale: the kicker and the score in `caption` and `title`, the lines in `body`, the
    /// colophon and the timestamps in `data`.
    enum PaperType {
        /// 28/600: the recap's title.
        case title
        /// 14/400 italic: a section's label, such as "Review these first".
        case sectionLabel
        /// 14/600: a numeral beside a learned line.
        case numeral
        /// 15/600: the Save photo receipt's line.
        case receiptTitle

        var pointSize: CGFloat {
            switch self {
            case .title: return 28
            case .sectionLabel, .numeral: return 14
            case .receiptTitle: return 15
            }
        }

        var weight: Font.Weight {
            switch self {
            case .title, .numeral, .receiptTitle: return .semibold
            case .sectionLabel: return .regular
            }
        }

        var isItalic: Bool { self == .sectionLabel }

        var font: Font {
            let serifFont = Font.system(size: pointSize, weight: weight, design: .serif)
            return isItalic ? serifFont.italic() : serifFont
        }
    }

    /// A symbol or number whose size follows the disc or badge it sits in, such as a check on a 22 point agent disc.
    /// Text never uses it: text takes a `TypeScale` style. This is the one other place a font size is written, so
    /// `tools/design-token-check.py` accepts a size here and nowhere else.
    static func glyphFont(pointSize: CGFloat, weight: Font.Weight, design: Font.Design = .default) -> Font {
        .system(size: pointSize, weight: weight, design: design)
    }

    // MARK: - Tether moves

    /// The ten named moves of the Tether redesign. Every animated change on a Tether surface is one of them, so a surface
    /// asks for a move by name, such as `withAnimation(DS.Move.pop.animation(reduceMotionIsOn: reduceMotion)) { ... }`, and
    /// never writes its own duration or spring. Each move has a `curve` and a Reduce Motion form (`reduceMotionForm`), which
    /// keeps the change of state and drops the travel.
    ///
    /// A theme may restyle three moves (`ThemeMoveSprings`): Pop and Glide as springs and Point as a speed, all inside safe
    /// limits. The other seven are the same under every theme.
    ///
    /// A move that crosses windows (Send, and a Card's Glide out of a disc and its Glide close back into it) runs on the shared
    /// carrier panel (`TetherCarrier`), which samples the same curve for Core Animation.
    ///
    /// Today's timings, and the move each becomes as the Tether PRs adopt these tokens:
    /// - The pointing bubble's spring(0.4, 0.6) scale and 0.5 s fade: Pop.
    /// - The status label's and chip's 0.2 s ease-out at scale 0.4: Pop in, and the Pop played backward in 0.7 of its time out.
    /// - The dial token's, disc hover's, fan's, and fan ball's 0.1 to 0.14 s ease-outs and spring(0.18, 0.8): Snap.
    /// - The dial's spring(0.22, 0.78) open: Glide. Its fan items' spring(0.26, 0.72) with a 14 ms stagger: Pop.
    /// - The dial's, agent list's, studio's, and panel's close, which is `orderOut` today: Glide close at 0.7x.
    /// - A disc's phase and check, 0.25 s ease-out: Pop for the badge, Snap for the ring.
    /// - The ring cue's 0.15 and 0.35 s crossfades and the loop's 0.3 s fade: one fade, `fadeSeconds`.
    /// - The pointing flight's 0.6 to 1.4 s smoothstep: Point. Its old scale pulse of 1.3 is now a stretch of 1.15 along the
    ///   flight (`CursorPointFlight`), with a landing squash and a landing ring.
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

        /// The springs of the theme on screen for Pop, Glide, and Point, which the app sets whenever the shown theme changes
        /// (`CompanionManager`, from the theme's `motion.springs`). A theme that sets none, as every bundled theme does,
        /// leaves Clicky's own here. Reduce Motion ignores them, since a move's Reduce Motion form is a fade.
        static var themeSprings = ThemeMoveSprings.standard

        /// This move's curve under the shown theme's springs.
        var curve: MoveCurve { curve(using: Self.themeSprings) }

        /// This move's curve under the given springs. Only Pop, Glide, and Point read them.
        func curve(using springs: ThemeMoveSprings) -> MoveCurve {
            switch self {
            case .send: return .timed(seconds: 0.5, bezier: .smoothstep)
            case .bringBack: return .timed(seconds: 0.6, bezier: .smoothstep)
            case .point:
                return MoveCurve.pacedByDistance(pointsPerSecond: 800, shortestSeconds: 0.6, longestSeconds: 1.4, bezier: .smoothstep)
                    .timeScaled(by: springs.pointFlightTimeFactor)
            case .rise: return .timed(seconds: 1.6, bezier: .cubicEaseInOut)
            case .returnToSource: return .timed(seconds: 0.8, bezier: .cubicEaseInOut)
            case .pop: return .spring(response: springs.pop.response, dampingFraction: springs.pop.dampingFraction)
            case .glide: return .spring(response: springs.glide.response, dampingFraction: springs.glide.dampingFraction)
            case .snap: return .spring(response: 0.18, dampingFraction: 0.86)
            case .recall: return .timed(seconds: 0.18, bezier: .quadraticEaseIn)
            case .shake: return .decayingShake(seconds: 0.45, amplitudePoints: Double(Self.shakeAmplitudePoints), cyclesPerSecond: 3.5, decayPerSecond: 7)
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
        /// - `springs`: the springs to play Pop, Glide, and Point with, for a surface that shows a theme other than the one on
        ///   screen, such as a Theme Studio tile. Nil uses the shown theme's.
        func animation(reduceMotionIsOn: Bool, travelingPoints: Double = 0, springs: ThemeMoveSprings? = nil) -> SwiftUI.Animation? {
            if reduceMotionIsOn {
                switch reduceMotionForm {
                case .crossfade(let seconds), .fadeAtTheTargetLeavingAStillRing(let seconds): return .easeOut(duration: seconds)
                case .none: return nil
                }
            }
            return curve(using: springs ?? Self.themeSprings).animation(travelingPoints: travelingPoints)
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
        /// Point squashes the cursor to this length along its flight on landing, for `pointSquashSeconds`, then Snap springs it back.
        static let pointSquashScale: CGFloat = 0.9
        static let pointSquashSeconds: Double = 0.08
        /// Point leaves a ring this wide (its outer edge) on the target.
        static let pointLandingRingDiameter: CGFloat = 24
        /// The shake's widest swing, to either side.
        static let shakeAmplitudePoints: CGFloat = 7
        /// The tether line's width, in the origin's color.
        static let tetherLineWidth: CGFloat = 1
        /// The tether line fades out over this time after the carried thing lands.
        static let tetherFadeSeconds: Double = 0.25
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

// MARK: - Convenience View Extensions

extension View {
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
}
