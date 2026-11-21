//
//  ThemeIdeasRealReplyTests.swift
//  leanring-buddyTests
//
//  Two replies recorded from the Worker's real POST /theme-ideas route on 2026-11-20 (Sonnet 5.5), one from words alone
//  and one from a picture, so the app's parser is checked against what the route really writes and not only against ideas
//  written by hand. If the route's contract changes, record new replies and update these.
//

import Foundation
import Testing
@testable import Clicky

private let replyFromWords = #"""
{"title":"Cozy Night Cursors","spokenLine":"Here are three cozy night looks for me. Say one, two, or three, or tell me what to change.","ideas":[{"name":"Crescent Moon","accent":"#FFD98A","contrast":"#2A1E0A","agentColors":["#FFD98A","#F4A97B","#B8A3F0","#8EC9F2"],"cursor":{"kind":"shapes","shapes":[{"d":"M15 2 C8 3 4 8 4 13 C4 19 9 23 15 22 C10 20 8 16 9 12 C10 8 12 5 15 2 Z","fill":"#FFD98A","stroke":"#FFFFFF","strokeWidth":1.2}],"picture":null},"motion":{"turnsTowardMovement":false,"trailStreaks":1,"whileThinking":"pulse","whileListening":"pulse"},"sounds":{"done":"Glass","correct":"Hero","needsYourOK":"Tink"},"usesPicture":false},{"name":"Candle Flame","accent":"#FFB86B","contrast":"#2B1500","agentColors":["#FFB86B","#FFD98A","#E59BC1","#A9B8F5","#7FD1C7"],"cursor":{"kind":"shapes","shapes":[{"d":"M12 2 C15 7 19 10 19 15 C19 19 16 22 12 22 C8 22 5 19 5 15 C5 11 9 8 12 2 Z","fill":"#FFB86B","stroke":"#FFF4E0","strokeWidth":1.2},{"d":"M12 11 C14 14 15 15 15 17 C15 19 13.5 20 12 20 C10.5 20 9 19 9 17 C9 15 11 14 12 11 Z","fill":"#FFE9A8","stroke":null,"strokeWidth":0}],"picture":null},"motion":{"turnsTowardMovement":true,"trailStreaks":2,"whileThinking":"wobble","whileListening":"pulse"},"sounds":{"done":"Purr","correct":"Pop","needsYourOK":"Bottle"},"usesPicture":false},{"name":"Sleepy Star","accent":"#B8A3F0","contrast":"#1B1030","agentColors":["#B8A3F0","#8EC9F2","#F2B8D6","#FFD98A"],"cursor":{"kind":"shapes","shapes":[{"d":"M12 2 L14.8 8.6 L22 9.3 L16.6 14 L18.2 21 L12 17.4 L5.8 21 L7.4 14 L2 9.3 L9.2 8.6 Z","fill":"#B8A3F0","stroke":"#F3EEFF","strokeWidth":1.2}],"picture":null},"motion":{"turnsTowardMovement":false,"trailStreaks":0,"whileThinking":"spin","whileListening":"pulse"},"sounds":{"done":"Submarine","correct":"Ping","needsYourOK":"Morse"},"usesPicture":false}]}
"""#

private let replyFromAPicture = #"""
{"title":"Starry Night Cursor Ideas","spokenLine":"Here are three ways to wear your starry night. Say one, two, or three, or tell me what to change.","ideas":[{"name":"Whole Painting","accent":"#7FA8E8","contrast":"#101211","agentColors":["#F2D45C","#8FB4F0","#C9DDF5","#5B7FD1","#E8B04A"],"cursor":{"kind":"picture","shapes":[],"picture":{"fit":"whole","outline":"#F2D45C","tint":null,"tintStrength":0}},"motion":{"turnsTowardMovement":false,"trailStreaks":2,"whileThinking":"wobble","whileListening":"pulse"},"sounds":{"done":"Glass","correct":"Hero","needsYourOK":"Ping"},"usesPicture":true},{"name":"Moon Circle","accent":"#F2D45C","contrast":"#101211","agentColors":["#F2D45C","#8FB4F0","#C9DDF5","#7FA8E8","#E8B04A"],"cursor":{"kind":"picture","shapes":[],"picture":{"fit":"circle","outline":"#FFFFFF","tint":null,"tintStrength":0}},"motion":{"turnsTowardMovement":false,"trailStreaks":0,"whileThinking":"spin","whileListening":"pulse"},"sounds":{"done":"Submarine","correct":"Pop","needsYourOK":"Tink"},"usesPicture":true},{"name":"Night Star","accent":"#A9C4F5","contrast":"#101211","agentColors":["#F2D45C","#A9C4F5","#E8B04A","#6E8FDB","#DDE8F7"],"cursor":{"kind":"shapes","shapes":[{"d":"M12 2 L14.5 9 L22 9.5 L16 14 L18 22 L12 17.5 L6 22 L8 14 L2 9.5 L9.5 9 Z","fill":"#F2D45C","stroke":"#FFFFFF","strokeWidth":1.2},{"d":"M12 8 L13 11 L16 11.3 L13.6 13 L14.4 16 L12 14.2 L9.6 16 L10.4 13 L8 11.3 L11 11 Z","fill":"#3F63B8","stroke":null,"strokeWidth":0}],"picture":null},"motion":{"turnsTowardMovement":true,"trailStreaks":3,"whileThinking":"pulse","whileListening":"pulse"},"sounds":{"done":"Bottle","correct":"Glass","needsYourOK":"Morse"},"usesPicture":false}]}
"""#

struct ThemeIdeasRealReplyTests {
    @Test func theReplyToSomethingCozyForNightParsesIntoThreeShapeIdeas() throws {
        let reply = try ThemeIdeasReply(responseData: Data(replyFromWords.utf8), pictureWasSent: false)
        #expect(reply.title == "Cozy Night Cursors")
        #expect(reply.ideas.map(\.name) == ["Crescent Moon", "Candle Flame", "Sleepy Star"])
        #expect(reply.ideas.map(\.id) == ["idea-1", "idea-2", "idea-3"])
        #expect(reply.ideas.allSatisfy { !$0.usesPicture })
        // The candle flame has two shapes, and its inner one has a fill and no stroke.
        guard case .shapes(let flameShapes) = reply.ideas[1].cursor else {
            Issue.record("expected a shapes cursor")
            return
        }
        #expect(flameShapes.count == 2)
        #expect(flameShapes[1].strokeHex == nil)
        #expect(reply.ideas[1].agentColorsInOrder.count == 5)
    }

    @Test func theReplyToUseThisWholeImageAsMyCursorParsesPictureCursorsAndAShapeIdea() throws {
        let reply = try ThemeIdeasReply(responseData: Data(replyFromAPicture.utf8), pictureWasSent: true)
        #expect(reply.ideas.map(\.name) == ["Whole Painting", "Moon Circle", "Night Star"])
        #expect(reply.ideas[0].cursor == .picture(CustomCursorPictureStyle(fit: .whole, outlineHex: "#F2D45C", tintHex: nil, tintStrength: 0)))
        #expect(reply.ideas[1].cursor == .picture(CustomCursorPictureStyle(fit: .circle, outlineHex: "#FFFFFF", tintHex: nil, tintStrength: 0)))
        #expect(reply.ideas[0].usesPicture && reply.ideas[1].usesPicture)
        #expect(!reply.ideas[2].usesPicture)
    }

    @Test func thePictureReplyIsRefusedWhenNoPictureWasSent() {
        #expect(throws: CustomThemeParseError.self) {
            try ThemeIdeasReply(responseData: Data(replyFromAPicture.utf8), pictureWasSent: false)
        }
    }

    @Test func everyRealIdeaSurvivesTheRoundTripThroughTheSavedFileShape() throws {
        for (replyText, pictureWasSent) in [(replyFromWords, false), (replyFromAPicture, true)] {
            let reply = try ThemeIdeasReply(responseData: Data(replyText.utf8), pictureWasSent: pictureWasSent)
            for idea in reply.ideas {
                #expect(try ClickyTheme.parse(themeJSON: idea.themeJSON, id: idea.id, pictureIsAvailable: pictureWasSent) == idea)
            }
        }
    }
}
