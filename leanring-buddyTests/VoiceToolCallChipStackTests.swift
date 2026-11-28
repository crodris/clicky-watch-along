//
//  VoiceToolCallChipStackTests.swift
//  leanring-buddyTests
//
//  What the learner sees when voice tool chips stack: a new chip pushes the one on screen up one step, the same chip updates
//  in place, a third chip sends the oldest away, a press recalls every chip that does not wait for an answer, and a hide
//  finds the chip in either slot. The stacked chips are also drawn at 2x.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct VoiceToolCallChipStackTests {
    private func chip(
        _ chipText: String,
        sender: VoiceToolCallChipSender = .voiceToolCall,
        survivesARecall: Bool = false
    ) -> VoiceToolCallChipStack.Chip {
        VoiceToolCallChipStack.Chip(identity: VoiceToolCallChipIdentity(chipText: chipText, sender: sender), survivesARecall: survivesARecall)
    }

    // MARK: - Stacking

    @Test func aSecondChipWithOtherWordsPushesTheFirstOneUpAndPopsBelowIt() {
        var chipStack = VoiceToolCallChipStack()
        let firstStep = chipStack.show(chip("Turning it left"))
        #expect(firstStep.bottomChipStep == .popTheNewChip)
        #expect(!firstStep.visibleBottomChipRisesToTheUpperSlot)

        let secondStep = chipStack.show(chip("Zooming in"))
        #expect(secondStep.bottomChipStep == .popTheNewChip)
        #expect(secondStep.visibleBottomChipRisesToTheUpperSlot)
        #expect(!secondStep.upperChipIsSentAway)
        #expect(chipStack.bottomChip?.identity.chipText == "Zooming in")
        #expect(chipStack.upperChip?.identity.chipText == "Turning it left")
    }

    @Test func theSameChipShownAgainUpdatesInPlaceAndLeavesTheUpperChipAlone() {
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Turning it left"))
        _ = chipStack.show(chip("Zooming in"))
        let repeatedStep = chipStack.show(chip("Zooming in"))
        #expect(repeatedStep.bottomChipStep == .updateInPlace)
        #expect(!repeatedStep.visibleBottomChipRisesToTheUpperSlot)
        #expect(!repeatedStep.upperChipIsSentAway)
        #expect(chipStack.upperChip?.identity.chipText == "Turning it left")
    }

    @Test func theSameWordsFromAnotherSenderAreAnotherChipAndStack() {
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Couldn't build that one"))
        let stackingStep = chipStack.show(chip("Couldn't build that one", sender: .failure))
        #expect(stackingStep.visibleBottomChipRisesToTheUpperSlot)
        #expect(chipStack.upperChip?.identity.sender == .voiceToolCall)
    }

    @Test func aThirdChipSendsTheOldestAwayAndAtMostTwoChipsShow() {
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Turning it left"))
        _ = chipStack.show(chip("Zooming in"))
        let thirdStep = chipStack.show(chip("Going back 10 seconds"))
        #expect(thirdStep.visibleBottomChipRisesToTheUpperSlot)
        #expect(thirdStep.upperChipIsSentAway)
        #expect(chipStack.bottomChip?.identity.chipText == "Going back 10 seconds")
        #expect(chipStack.upperChip?.identity.chipText == "Zooming in")
    }

    @Test func aChipShownWhileTheBottomSlotIsEmptyDoesNotPushTheUpperChipAway() {
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Turning it left"))
        _ = chipStack.show(chip("Zooming in"))
        // The bottom chip's time ends first, and the upper one stays where it is.
        chipStack.leave(.bottom)
        #expect(chipStack.upperChip?.identity.chipText == "Turning it left")
        #expect(chipStack.bottomChip == nil)

        let stackingStep = chipStack.show(chip("Going back 10 seconds"))
        #expect(stackingStep.bottomChipStep == .popTheNewChip)
        #expect(!stackingStep.visibleBottomChipRisesToTheUpperSlot)
        #expect(!stackingStep.upperChipIsSentAway)
        #expect(chipStack.upperChip?.identity.chipText == "Turning it left")
    }

    @Test func aChipWaitingForAnAnswerAboveIsNeverSentAwayByANewChip() {
        // The review of PR 112 found that one command's two chips sent an agent's waiting request away.
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Teal needs your OK", survivesARecall: true))
        _ = chipStack.show(chip("Turning it left"))
        let thirdStep = chipStack.show(chip("Zooming in"))
        #expect(thirdStep.bottomChipStep == .popTheNewChip)
        #expect(!thirdStep.visibleBottomChipRisesToTheUpperSlot)
        #expect(!thirdStep.upperChipIsSentAway)
        #expect(chipStack.upperChip?.identity.chipText == "Teal needs your OK")
        #expect(chipStack.bottomChip?.identity.chipText == "Zooming in")
    }

    @Test func theSameWordsAsTheChipAboveShowOnceAtTheBottom() {
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Couldn't finish the task", sender: .failure))
        _ = chipStack.show(chip("Turning it left"))
        chipStack.leave(.bottom)
        let repeatedStep = chipStack.show(chip("Couldn't finish the task", sender: .failure))
        #expect(repeatedStep.upperChipIsSentAway)
        #expect(!repeatedStep.visibleBottomChipRisesToTheUpperSlot)
        #expect(chipStack.upperChip == nil)
        #expect(chipStack.bottomChip?.identity.chipText == "Couldn't finish the task")
    }

    @Test func theUpperChipLeavingLeavesTheBottomChipWhereItIs() {
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Turning it left"))
        _ = chipStack.show(chip("Zooming in"))
        chipStack.leave(.upper)
        #expect(chipStack.upperChip == nil)
        #expect(chipStack.bottomChip?.identity.chipText == "Zooming in")
        #expect(!chipStack.isEmpty)
        chipStack.leave(.bottom)
        #expect(chipStack.isEmpty)
    }

    // MARK: - Recall and hide

    @Test func aPressRecallsEveryChipExceptOneThatWaitsForAnAnswer() {
        var plainChips = VoiceToolCallChipStack()
        _ = plainChips.show(chip("Turning it left"))
        _ = plainChips.show(chip("Zooming in"))
        #expect(plainChips.recall() == [.bottom, .upper])
        #expect(plainChips.isEmpty)

        var survivorBelow = VoiceToolCallChipStack()
        _ = survivorBelow.show(chip("Turning it left"))
        _ = survivorBelow.show(chip("Teal needs your OK", survivesARecall: true))
        #expect(survivorBelow.recall() == [.upper])
        #expect(survivorBelow.bottomChip?.identity.chipText == "Teal needs your OK")
        #expect(survivorBelow.upperChip == nil)

        var survivorAbove = VoiceToolCallChipStack()
        _ = survivorAbove.show(chip("Teal needs your OK", survivesARecall: true))
        _ = survivorAbove.show(chip("Zooming in"))
        #expect(survivorAbove.recall() == [.bottom])
        #expect(survivorAbove.upperChip?.identity.chipText == "Teal needs your OK")
        #expect(survivorAbove.bottomChip == nil)
    }

    @Test func aHideFindsTheChipInEitherSlotAndNeverCutsANewerChipShort() {
        var chipStack = VoiceToolCallChipStack()
        _ = chipStack.show(chip("Teal needs your OK", survivesARecall: true))
        _ = chipStack.show(chip("Zooming in"))
        #expect(chipStack.hide(ifShowing: "Teal needs your OK") == [.upper])
        #expect(chipStack.upperChip == nil)
        #expect(chipStack.bottomChip?.identity.chipText == "Zooming in")

        // Words no chip shows hide nothing.
        #expect(chipStack.hide(ifShowing: "Teal needs your OK").isEmpty)
        #expect(chipStack.hide(ifShowing: "Zooming in") == [.bottom])
        #expect(chipStack.isEmpty)
    }

    // MARK: - Placement

    @Test func theRiseIsTheHeightOfTheChipBelowPlusAGapAndThePanelHasRoomForTheGreatestRise() {
        #expect(voiceToolCallChipRise(overTheBottomChipSentBy: .voiceToolCall) == tetherSingleLineCalloutHeight + 4)
        #expect(voiceToolCallChipRise(overTheBottomChipSentBy: .failure) == tetherSingleLineCalloutHeight + 4)
        #expect(voiceToolCallChipRise(overTheBottomChipSentBy: .backgroundAgent(color: .teal, face: .triangle)) == tetherSingleLineCalloutHeight + 4)
        #expect(voiceToolCallChipRise(overTheBottomChipSentBy: .photoReceipt) == PaperPhotoReceipt.height + 4)
        #expect(VoiceToolCallChip.greatestRiseOverTheBottomChip == PaperPhotoReceipt.height + 4)
        // The panel is also tall enough for the Save photo receipt, which is taller than a one line Callout, with the chip above it.
        #expect(VoiceToolCallChip.panelSize.height == max(tetherSingleLineCalloutHeight, PaperPhotoReceipt.greatestHeight) + 2 * tetherCalloutPanelMargin + VoiceToolCallChip.greatestRiseOverTheBottomChip)
        // A receipt below a receipt: the upper receipt's top edge is rise plus its own height above the bottom tip.
        #expect(voiceToolCallChipRise(overTheBottomChipSentBy: .photoReceipt) + PaperPhotoReceipt.height <= VoiceToolCallChip.panelSize.height - 2 * tetherCalloutPanelMargin)
    }

    @Test func bothChipPanelsStayInsideTheScreenWhateverTheirWidthsAndTheMouseSits() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let panelSize = VoiceToolCallChip.panelSize
        for mouseLocation in [CGPoint(x: 1700, y: 500), CGPoint(x: 500, y: 1100), CGPoint(x: 5, y: 5), CGPoint(x: 1000, y: 600)] {
            for calloutWidth in [CGFloat(120), 260] {
                let panelOrigin = voiceToolCallChipOrigin(mouseLocation: mouseLocation, screenFrame: screenFrame, calloutWidth: calloutWidth)
                // The upper chip's top edge is the panel's top edge less the margin, so it is inside when the panel is.
                #expect(panelOrigin.y + panelSize.height <= screenFrame.maxY)
                #expect(panelOrigin.y >= screenFrame.minY)
                #expect(panelOrigin.x + tetherCalloutPanelMargin + calloutWidth <= screenFrame.maxX)
                #expect(panelOrigin.x + tetherCalloutPanelMargin >= screenFrame.minX)
            }
        }
    }

    // MARK: - Drawn at 2x

    private func renderedPixels(of view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.padding(30).background(Color.white))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    private func size(of view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { CGSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2) } ?? .zero
    }

    /// Whether a pixel is within 3 of a `#rrggbb` color in every channel, so a color space conversion does not fail a render.
    private func pixel(_ color: NSColor?, isCloseTo expectedHex: String) -> Bool {
        guard let color, let expected = ThemeRGBColor(hex: expectedHex) else { return false }
        let pairs: [(CGFloat, Double)] = [(color.redComponent, expected.red), (color.greenComponent, expected.green), (color.blueComponent, expected.blue)]
        return pairs.allSatisfy { abs(Int(($0.0 * 255).rounded()) - Int(($0.1 * 255).rounded())) <= 3 }
    }

    /// Whether a pixel is the light page, which a Callout's shadow darkens a little but never below this.
    private func pixelIsLightPage(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return min(color.redComponent, color.greenComponent, color.blueComponent) >= 0.7
    }

    @Test func twoStackedChipsRenderOneStepApartEachWithItsWordsInsideItsBackground() throws {
        let accentHex = "#F2B53A"
        let accent = Color(hex: accentHex)
        let step = voiceToolCallChipRise(overTheBottomChipSentBy: .failure)
        let upperCallout = VoiceToolCallChipCallout(chipText: "Turning it left", sender: .voiceToolCall, themeAccent: accent)
        let bottomCallout = VoiceToolCallChipCallout(chipText: "Zooming in", sender: .failure, themeAccent: accent)
        let upperSize = size(of: upperCallout)
        let bottomSize = size(of: bottomCallout)
        #expect(upperSize.height == tetherSingleLineCalloutHeight)
        #expect(bottomSize.height == tetherSingleLineCalloutHeight)

        // The panel's layout: bottom aligned, with the upper chip offset one step.
        let stacked = ZStack(alignment: .bottomLeading) {
            upperCallout.offset(y: -step)
            bottomCallout
        }
        .frame(width: 300, height: tetherSingleLineCalloutHeight + step, alignment: .bottomLeading)
        let pixels = try renderedPixels(of: stacked)

        if let pngPath = ProcessInfo.processInfo.environment["CLICKY_CHIP_STACK_PNG"], let pngData = pixels.representation(using: .png, properties: [:]) {
            try pngData.write(to: URL(fileURLWithPath: pngPath))
        }

        let padding = 30
        let upperBodyMiddleRow = Int((CGFloat(padding) + 20) * 2)
        let bottomBodyMiddleRow = Int((CGFloat(padding) + step + 20) * 2)
        let surfaceColumn = Int(CGFloat(padding + 7 + 26 + 4) * 2)
        // Each chip's own surface at the same column, one step apart, and the page between them.
        #expect(pixel(pixels.colorAt(x: surfaceColumn, y: upperBodyMiddleRow), isCloseTo: "#14171e"))
        #expect(pixel(pixels.colorAt(x: surfaceColumn, y: bottomBodyMiddleRow), isCloseTo: "#14171e"))
        let gapRow = Int((CGFloat(padding) + tetherSingleLineCalloutHeight + 2) * 2)
        #expect(pixelIsLightPage(pixels.colorAt(x: surfaceColumn, y: gapRow)))

        // The upper chip's disc is the theme accent, and the bottom failure chip's disc is red.
        let discColumn = Int(CGFloat(padding + 7 + 3) * 2)
        #expect(pixel(pixels.colorAt(x: discColumn, y: Int((CGFloat(padding) + 7 + 13) * 2)), isCloseTo: accentHex))
        #expect(pixel(pixels.colorAt(x: discColumn, y: Int((CGFloat(padding) + step + 7 + 13) * 2)), isCloseTo: "#ff6369"))

        // Inside each chip's right edge is its own surface, and just outside it is the page, so the words stay in the background.
        for (calloutWidth, bodyMiddleRow) in [(upperSize.width, upperBodyMiddleRow), (bottomSize.width, bottomBodyMiddleRow)] {
            #expect(pixel(pixels.colorAt(x: Int((CGFloat(padding) + calloutWidth - 6) * 2), y: bodyMiddleRow), isCloseTo: "#14171e"))
            #expect(pixelIsLightPage(pixels.colorAt(x: Int((CGFloat(padding) + calloutWidth + 3) * 2), y: bodyMiddleRow)))
        }
    }

    // MARK: - Chips of different heights

    private func chipView(for sender: VoiceToolCallChipSender, words: String) -> AnyView {
        switch sender {
        case .photoReceipt:
            return AnyView(PaperPhotoReceipt(thumbnail: nil, locationLine: "Clicky folder · \(words).jpg", accent: Color(hex: "#F2B53A")))
        default:
            return AnyView(VoiceToolCallChipCallout(chipText: words, sender: sender, themeAccent: Color(hex: "#F2B53A")))
        }
    }

    @Test func theRiseOfEachKindOfChipIsItsDrawnHeightPlusTheGap() {
        for sender in [VoiceToolCallChipSender.voiceToolCall, .failure, .photoReceipt, .backgroundAgent(color: .teal, face: .triangle)] {
            let drawnHeight = size(of: chipView(for: sender, words: "Zooming in")).height
            #expect(abs(voiceToolCallChipRise(overTheBottomChipSentBy: sender) - (drawnHeight + VoiceToolCallChip.gapBetweenStackedChips)) <= 0.5, "\(sender) is drawn \(drawnHeight) tall")
        }
    }

    /// Draws `upper` pushed up over `bottom` the way the chip panel lays them out, and reports whether the 2 points just above
    /// the bottom chip are bare page across its whole width, which an overlap by the upper chip's tail would break.
    private func theUpperChipClearsTheBottomChip(upper: VoiceToolCallChipSender, bottom: VoiceToolCallChipSender) throws -> Bool {
        let rise = voiceToolCallChipRise(overTheBottomChipSentBy: bottom)
        let bottomHeight = size(of: chipView(for: bottom, words: "Zooming in")).height
        let bottomWidth = size(of: chipView(for: bottom, words: "Zooming in")).width
        let panelHeight: CGFloat = 150
        let stacked = ZStack(alignment: .bottomLeading) {
            chipView(for: upper, words: "Turning it left").offset(y: -rise)
            chipView(for: bottom, words: "Zooming in")
        }
        .frame(width: 400, height: panelHeight, alignment: .bottomLeading)
        let pixels = try pixelsOnAMagentaPage(of: stacked)
        let padding: CGFloat = 30
        let bareRow = Int((padding + panelHeight - bottomHeight - 2) * 2)
        let columns = stride(from: Int((padding + 2) * 2), to: Int((padding + bottomWidth - 2) * 2), by: 2)
        return columns.allSatisfy { pixelIsMagentaPage(pixels.colorAt(x: $0, y: bareRow)) }
    }

    /// Magenta is in neither a dark Callout nor warm paper, so a pixel that is still magenta is bare page, shadow or not.
    private func pixelsOnAMagentaPage(of view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.padding(30).background(Color(red: 1, green: 0, blue: 1)))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    private func pixelIsMagentaPage(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent >= 0.7 && color.blueComponent >= 0.7 && color.greenComponent <= 0.2
    }

    @Test(arguments: [
        (VoiceToolCallChipSender.voiceToolCall, VoiceToolCallChipSender.photoReceipt),
        (.failure, .photoReceipt),
        (.photoReceipt, .voiceToolCall),
        (.photoReceipt, .failure),
        (.photoReceipt, .photoReceipt),
        (.voiceToolCall, .failure),
    ])
    func aChipPushedUpClearsTheChipBelowItWhateverTheirHeights(upper: VoiceToolCallChipSender, bottom: VoiceToolCallChipSender) throws {
        #expect(try theUpperChipClearsTheBottomChip(upper: upper, bottom: bottom), "\(upper) over \(bottom) overlaps")
    }

    @Test func aReceiptBelowAChipWouldOverlapItAtTheOldFixedStep() throws {
        // The old step was one Callout plus the gap (53), which is 5 points less than a receipt and its gap.
        let oldStep = tetherSingleLineCalloutHeight + VoiceToolCallChip.gapBetweenStackedChips
        #expect(oldStep < voiceToolCallChipRise(overTheBottomChipSentBy: .photoReceipt))
        let upper = chipView(for: .voiceToolCall, words: "Turning it left")
        let bottom = chipView(for: .photoReceipt, words: "Zooming in")
        let bottomHeight = size(of: bottom).height
        let panelHeight: CGFloat = 150
        let pixels = try pixelsOnAMagentaPage(of: ZStack(alignment: .bottomLeading) { upper.offset(y: -oldStep); bottom }.frame(width: 400, height: panelHeight, alignment: .bottomLeading))
        let bareRow = Int((30 + panelHeight - bottomHeight - 2) * 2)
        let columns = stride(from: 64, to: 560, by: 2)
        #expect(!columns.allSatisfy { pixelIsMagentaPage(pixels.colorAt(x: $0, y: bareRow)) }, "the old step cleared the receipt, so the test pins nothing")
    }
}
