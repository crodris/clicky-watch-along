//
//  EscapeOrder.swift
//  leanring-buddy
//
//  Which surface one Escape reaches. CompanionManager reads what is open and runs the step this returns, so the order is
//  a pure rule a test can pin.
//

/// What is open or under way when Escape arrives, read by `CompanionManager.closeLiveSceneOnEscape`.
nonisolated struct EscapeFacts: Equatable, Sendable {
    /// A text field in Clicky's own window, such as a saved theme's rename field, is being edited.
    var aTextFieldIsBeingEdited = false
    /// The menu bar panel holds the keyboard, or closed on this Escape a moment ago (`menuPanelTookTheEscape`).
    var theMenuPanelTookTheEscape = false
    var theSettingsDialIsOpen = false
    var theAgentListIsOpen = false
    var theThemeStudioIsOpen = false
    var anAddThemeCardIsOpen = false
    /// The room art panel is open, or its request still reads the page and its picture (`RoomArtPreviewController.takesEscape`).
    var theRoomArtPanelTakesEscape = false
    var theRecapIsGatheringTheDiscs = false
    var theQuizSummaryIsShowing = false
    var anInstantReplayIsOpen = false
    var aPopOutIsReturningToSource = false
    var aVideoQuizQuestionIsOpen = false
    /// `liveScenePhase` is `.idle`: no scene is building or on screen.
    var noSceneIsUp = false
    /// `liveScenePhase` is `.allLabelsShowing`: a finished scene with no question waiting on it.
    var aFinishedSceneShowsAllItsLabels = false
}

/// What one Escape does.
nonisolated enum EscapeStep: Equatable, Sendable {
    /// The text field takes Escape as its cancel, so nothing else closes.
    case leaveItToTheTextField
    /// The menu bar panel takes Escape as its own close, so no quiz question is skipped and no scene is cleared.
    case leaveItToTheMenuPanel
    /// The settings dial's own cancel runs after this, so the dial is still open here.
    case leaveItToTheSettingsDial
    case closeTheAgentList
    /// Closes the Theme Studio card and keeps the old theme.
    case closeTheThemeStudio
    /// Answers the "Add theme?" card with a no.
    case declineTheAddThemeCard
    /// Closes the room art panel or stops its page read, which stops the camera and ends its spoken line.
    case closeTheRoomArtPanel
    /// Stops a recap's disc gather, and the discs go back.
    case stopTheRecapGather
    case closeTheQuizSummary
    /// Ends an open instant replay with the pop-out still on screen, so a second Escape sends the pop-out back.
    case endTheInstantReplay
    /// A second Escape while a pop-out lands in its frame hides it at once.
    case hideThePopOutAtOnce
    /// Skips the video quiz question and plays the video on.
    case skipTheQuizQuestion
    /// With no scene up, stops the answer Clicky is giving, when it has one (`escapeHasAnAnswerToStop`).
    case stopTheReply
    /// Clears a finished scene and anything Clicky is still saying about it.
    case clearTheFinishedScene
    case nothing
}

/// The Escape order: a text field being edited, the menu bar panel, the settings dial, the agent list, the Theme Studio card,
/// an "Add theme?" card, the room art panel, a recap's disc gather, the quiz summary Card, an instant replay, a pop-out
/// landing in its frame, a video quiz question, and then the answer or the scene. Each surface ahead of the scene takes the
/// Escape alone, so one Escape never closes two things.
nonisolated func escapeStep(for facts: EscapeFacts) -> EscapeStep {
    if facts.aTextFieldIsBeingEdited { return .leaveItToTheTextField }
    if facts.theMenuPanelTookTheEscape { return .leaveItToTheMenuPanel }
    if facts.theSettingsDialIsOpen { return .leaveItToTheSettingsDial }
    if facts.theAgentListIsOpen { return .closeTheAgentList }
    if facts.theThemeStudioIsOpen { return .closeTheThemeStudio }
    if facts.anAddThemeCardIsOpen { return .declineTheAddThemeCard }
    if facts.theRoomArtPanelTakesEscape { return .closeTheRoomArtPanel }
    if facts.theRecapIsGatheringTheDiscs { return .stopTheRecapGather }
    if facts.theQuizSummaryIsShowing { return .closeTheQuizSummary }
    if facts.anInstantReplayIsOpen { return .endTheInstantReplay }
    if facts.aPopOutIsReturningToSource { return .hideThePopOutAtOnce }
    if facts.aVideoQuizQuestionIsOpen { return .skipTheQuizQuestion }
    if facts.noSceneIsUp { return .stopTheReply }
    if facts.aFinishedSceneShowsAllItsLabels { return .clearTheFinishedScene }
    return .nothing
}
