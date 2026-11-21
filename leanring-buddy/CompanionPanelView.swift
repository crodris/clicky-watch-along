//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    #if DEBUG
    @AppStorage(CompanionManager.logsVoiceToolCallJSONDefaultsKey) private var logsVoiceToolCallJSON = false
    #endif

    /// The panel card's width, without the shadow margin around it.
    static let contentWidth: CGFloat = 320

    /// Transparent space around the card for its drop shadow (radius 20, 10 points down, so it reaches about 30 below,
    /// 20 to the sides and 10 above). A window clips what it draws, so without this margin the shadow is cut off at the edge.
    /// `MenuBarPanelManager` sizes and places the window with it.
    static let shadowMargin = EdgeInsets(top: 12, leading: 24, bottom: 32, trailing: 24)

    var body: some View {
        panelCard
            .padding(Self.shadowMargin)
    }

    private var panelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)

                TeamThemePickerView(themeSettings: companionManager.themeSettings)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                #if DEBUG
                voiceToolCallLoggingRow
                    .padding(.horizontal, 16)
                #endif
            }

            // Also shown during first run with everything granted, so the optional Chrome row can be reached before Start.
            if !companionManager.allPermissionsGranted || !companionManager.hasCompletedOnboarding {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                reportProblemButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: Self.contentWidth)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .panelControlHoverHighlight()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant the ones listed below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Clicky")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Hold control + option, ask about what's on your screen, and Clicky points at it.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Clicky captures a screenshot of every connected display when you ask a question by holding the shortcut, and again when a quiz or a build you asked for needs a fresh look. It sends the screenshots through Clicky's server to the AI model.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .panelControlHoverHighlight()
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            if companionManager.buddyDictationManager.transcriptionProviderRequiresSpeechRecognitionPermission {
                speechRecognitionPermissionRow
            }

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

            chromeControlPermissionRow
        }
    }

    /// The green dot and "Granted" label every permission row shows once it is done.
    private var grantedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
            Text("Granted")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.success)
        }
    }

    /// The filled capsule button every permission row uses for its main action.
    private func permissionActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .panelControlHoverHighlight()
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                HStack(spacing: 6) {
                    permissionActionButton(title: "Grant") {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                // strokeBorder keeps the line inside the button, so the hover brightness never clips it.
                                Capsule()
                                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .panelControlHoverHighlight()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                permissionActionButton(title: "Grant") {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                permissionActionButton(title: "Grant") {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                permissionActionButton(title: "Grant") {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var speechRecognitionPermissionRow: some View {
        let isGranted = companionManager.hasSpeechRecognitionPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Speech Recognition")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                permissionActionButton(title: "Grant") {
                    companionManager.requestSpeechRecognitionPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Chrome control is optional (only the video features use it), so its icon never turns the warning color.
    /// macOS can report this permission without a prompt only while Chrome runs, so with Chrome closed the row
    /// asks the learner to open it instead of offering an action that could not show the prompt.
    private var chromeControlPermissionRow: some View {
        let chromeAutomationStatus = companionManager.chromeAutomationPermissionStatus
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Chrome control")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(chromeControlCaption(for: chromeAutomationStatus))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            switch chromeAutomationStatus {
            case .granted:
                grantedBadge
            case .notAskedYet:
                permissionActionButton(title: "Allow") {
                    companionManager.requestChromeAutomationPermission()
                }
            case .denied:
                permissionActionButton(title: "Open Settings") {
                    companionManager.requestChromeAutomationPermission()
                }
            case .chromeIsNotRunning:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
    }

    private func chromeControlCaption(for status: ChromeAutomationPermissionStatus) -> String {
        switch status {
        case .granted:
            return "Optional: video quizzes and pop-outs"
        case .notAskedYet:
            return "Optional: video quizzes and pop-outs"
        case .denied:
            return "Turned off for Clicky"
        case .chromeIsNotRunning:
            return "Open Chrome to check or allow"
        }
    }

    #if DEBUG
    /// Prints the full JSON of every voice command reply and tool result to the app log.
    private var voiceToolCallLoggingRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Log tool call JSON")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $logsVoiceToolCallJSON)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .pointerCursor()
        }
        .padding(.vertical, 4)
    }
    #endif

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: ClaudeVoiceModel.sonnetModelID)
                modelOptionButton(label: "Opus", modelID: ClaudeVoiceModel.opusModelID)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return ModelOptionButton(label: label, isSelected: isSelected) {
            companionManager.setSelectedModel(modelID)
        }
    }

    // MARK: - Report a Problem Button

    private var reportProblemButton: some View {
        ReportProblemButton()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Clicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .panelControlHoverHighlight()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .panelControlHoverHighlight()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

// MARK: - Panel control hover

private extension View {
    /// Brightens a panel control while the pointer is over it, so every clickable control answers a hover.
    /// The pointing-hand cursor comes from `pointerCursor()`, which each control also applies.
    func panelControlHoverHighlight() -> some View {
        modifier(PanelControlHoverHighlight())
    }
}

private struct PanelControlHoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? 0.18 : 0)
            .onHover { isHovered = $0 }
    }
}

/// One side of the Sonnet and Opus switch. The hovered option gets a faint fill, like the theme buttons.
private struct ModelOptionButton: View {
    let label: String
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected || isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(isSelected ? 0.1 : (isHovered ? 0.06 : 0)))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

/// Opens a new issue on this fork's GitHub repository.
private struct ReportProblemButton: View {
    static let newIssueURLString = "https://github.com/crodris/clicky-watch-along/issues/new"

    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if let newIssueURL = URL(string: Self.newIssueURLString) {
                NSWorkspace.shared.open(newIssueURL)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Report a problem")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Opens a new issue on GitHub.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

// MARK: - Team Theme Picker

/// The "Team theme" section: Clicky blue, the ten Haikyu!! schools, and Random in two columns, then the learner's saved custom
/// themes as full-width rows that can be renamed or deleted (`SavedThemeRow`).
/// Picking one recolors the cursor now, and gives each agent that starts afterward a player of that team.
private struct TeamThemePickerView: View {
    @ObservedObject var themeSettings: CompanionThemeSettings

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Team theme")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(CompanionTheme.allChoices, id: \.rawValue) { theme in
                    TeamThemeOptionButton(
                        theme: theme,
                        isSelected: themeSettings.theme == theme,
                        select: { themeSettings.theme = theme }
                    )
                }
            }

            // Full width, since a row holds the theme's name and, on hover, two buttons, or a field for a new name.
            if !themeSettings.savedCustomThemes.isEmpty {
                VStack(spacing: 6) {
                    ForEach(themeSettings.savedCustomThemes, id: \.id) { customTheme in
                        SavedThemeRow(
                            customTheme: customTheme,
                            isSelected: themeSettings.theme == .custom(customTheme),
                            select: { themeSettings.theme = .custom(customTheme) },
                            rename: { typedName in try themeSettings.renameSavedTheme(themeID: customTheme.id, to: typedName) },
                            delete: { try themeSettings.deleteSavedTheme(themeID: customTheme.id) }
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TeamThemeOptionButton: View {
    let theme: CompanionTheme
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    /// The selected button's border: the theme's own color, which for Random is Clicky blue.
    private var selectionColor: Color {
        theme.cursorColor
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                TeamThemeSwatch(theme: theme)
                    .frame(width: 18, height: 18)
                Text(theme.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? selectionColor : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

/// A small round swatch: solid blue for Clicky blue, the team's two colors for a school, and four teams' colors for Random.
/// A saved theme's row draws it too.
struct TeamThemeSwatch: View {
    let theme: CompanionTheme

    var body: some View {
        Group {
            switch theme {
            case .clickyBlue:
                DS.Colors.overlayCursorBlue
            case .school(let school):
                HStack(spacing: 0) {
                    school.accentColor
                    school.contrastColor
                }
            case .custom(let customTheme):
                HStack(spacing: 0) {
                    Color(hex: customTheme.accentHex)
                    Color(hex: customTheme.contrastHex)
                }
            case .random:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        HaikyuSchool.karasuno.accentColor
                        HaikyuSchool.nekoma.accentColor
                    }
                    HStack(spacing: 0) {
                        HaikyuSchool.aobaJohsai.accentColor
                        HaikyuSchool.fukurodani.accentColor
                    }
                }
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}
