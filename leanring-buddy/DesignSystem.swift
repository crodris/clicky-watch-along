//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design tokens for a blue accent palette on dark surfaces:
//  colors, corner radii, animation durations, and the pointer cursor
//  modifier. Every view reads them from here.
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

        static let blue50  = Color(hex: "#eff6ff")
        static let blue200 = Color(hex: "#bfdbfe")
        static let blue400 = Color(hex: "#60a5fa")
        static let blue600 = Color(hex: "#2563eb")
        static let blue700 = Color(hex: "#1d4ed8")
        static let blue800 = Color(hex: "#1e40af")
        static let blue900 = Color(hex: "#1e3a8a")

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
        // The primary fill is Blue 600.

        /// Accent fill — used for solid button backgrounds.
        /// #2563eb → ~5.1:1 contrast with white text (WCAG AA).
        static let accent = blue600

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

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The blue cursor/bubble color used in OverlayWindow.
        /// Kept distinct from the accent since it serves a different purpose
        /// (screen overlay vs in-app UI).
        static let overlayCursorBlue = Color(hex: overlayCursorBlueHex)

        /// The same blue as text, for the frame pop-out page, which cannot read a SwiftUI Color.
        static let overlayCursorBlueHex = "#3380ff"

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
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
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
