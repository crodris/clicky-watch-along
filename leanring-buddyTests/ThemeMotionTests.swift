//
//  ThemeMotionTests.swift
//  leanring-buddyTests
//
//  Theme Studio designs motion: a theme's optional `motion.springs` for the Pop, Glide, and Point moves, clamped to safe
//  limits the Worker applies too, read by `DS.Move`, ignored by Reduce Motion, and kept off the bundled themes.
//

import Combine
import Foundation
import SwiftUI
import Testing
@testable import Clicky

private func springsJSON(popResponse: Double, popDamping: Double, glideResponse: Double, glideDamping: Double, pointResponse: Double) -> JSONValue {
    .object([
        "pop": .object(["response": .number(popResponse), "dampingFraction": .number(popDamping)]),
        "glide": .object(["response": .number(glideResponse), "dampingFraction": .number(glideDamping)]),
        "point": .object(["response": .number(pointResponse)]),
    ])
}

private func themeWithSprings(_ springs: JSONValue) throws -> ClickyTheme {
    let themeJSON = replacingField(in: goodVersion2ThemeJSON, at: ["motion", "springs"], with: springs)
    return try ClickyTheme.parse(themeJSON: themeJSON, id: "idea-1", pictureIsAvailable: false)
}

private func springs(from jsonValue: JSONValue?) throws -> ThemeMoveSprings {
    let fixtureSprings = try #require(jsonValue)
    return ThemeMoveSprings(
        pop: ThemeSpring(
            response: try #require(fixtureSprings["pop"]?["response"]?.numberValue),
            dampingFraction: try #require(fixtureSprings["pop"]?["dampingFraction"]?.numberValue)
        ),
        glide: ThemeSpring(
            response: try #require(fixtureSprings["glide"]?["response"]?.numberValue),
            dampingFraction: try #require(fixtureSprings["glide"]?["dampingFraction"]?.numberValue)
        ),
        pointResponse: try #require(fixtureSprings["point"]?["response"]?.numberValue)
    )
}

/// The fixture the Worker's tests read too.
private func springLimitsFixture() throws -> JSONValue {
    let fixtureData = try Data(contentsOf: repositoryRootURL.appendingPathComponent("worker/src/testdata/theme-spring-limits.json"))
    return try JSONDecoder().decode(JSONValue.self, from: fixtureData)
}

struct ThemeMotionParsingTests {
    @Test func aThemeWithNoSpringsKeepsClickysOwn() throws {
        let theme = try ClickyTheme.parse(themeJSON: goodVersion2ThemeJSON, id: "idea-1", pictureIsAvailable: false)

        #expect(theme.motion.springs == nil)
        #expect(theme.moveSprings == .standard)
    }

    @Test func nullSpringsReadAsNone() throws {
        #expect(try themeWithSprings(.null).motion.springs == nil)
    }

    @Test func springsInsideTheLimitsAreKeptExactly() throws {
        let theme = try themeWithSprings(springsJSON(popResponse: 0.3, popDamping: 0.6, glideResponse: 0.4, glideDamping: 0.8, pointResponse: 0.4))

        #expect(theme.motion.springs == ThemeMoveSprings(
            pop: ThemeSpring(response: 0.3, dampingFraction: 0.6),
            glide: ThemeSpring(response: 0.4, dampingFraction: 0.8),
            pointResponse: 0.4
        ))
    }

    @Test func aMoveTheFileLeavesOutKeepsClickysOwnSpring() throws {
        let theme = try themeWithSprings(.object(["pop": .object(["response": .number(0.3), "dampingFraction": .number(0.6)])]))

        #expect(theme.moveSprings.pop == ThemeSpring(response: 0.3, dampingFraction: 0.6))
        #expect(theme.moveSprings.glide == ThemeMoveSprings.standard.glide)
        #expect(theme.moveSprings.pointResponse == ThemeMoveSprings.standard.pointResponse)
    }

    @Test func everyFixtureCaseClampsTheSameWayTheWorkerDoes() throws {
        let fixture = try springLimitsFixture()
        let fixtureCases = try #require(fixture["cases"]?.arrayValue)
        #expect(!fixtureCases.isEmpty)

        for fixtureCase in fixtureCases {
            let caseName = fixtureCase["name"]?.stringValue ?? "unnamed"
            let theme = try themeWithSprings(try #require(fixtureCase["input"], "\(caseName) has no input"))

            #expect(theme.motion.springs == (try springs(from: fixtureCase["expected"])), "\(caseName)")
        }
    }

    @Test func theLimitsAreTheOnesTheWorkerListsInTheFixture() throws {
        let fixtureLimits = try #require(try springLimitsFixture()["limits"])

        func range(_ move: String, _ field: String) throws -> ClosedRange<Double> {
            let bounds = (fixtureLimits[move]?[field]?.arrayValue ?? []).compactMap { $0.numberValue }
            try #require(bounds.count == 2, "\(move).\(field) needs two bounds")
            return bounds[0]...bounds[1]
        }
        #expect(ThemeMoveSprings.popLimits.response == (try range("pop", "response")))
        #expect(ThemeMoveSprings.popLimits.dampingFraction == (try range("pop", "dampingFraction")))
        #expect(ThemeMoveSprings.glideLimits.response == (try range("glide", "response")))
        #expect(ThemeMoveSprings.glideLimits.dampingFraction == (try range("glide", "dampingFraction")))
        #expect(ThemeMoveSprings.pointResponseLimits == (try range("point", "response")))
    }

    @Test func aSpringThatIsNotANumberIsRefused() {
        let springsWithATextResponse = JSONValue.object(["pop": .object(["response": .string("fast"), "dampingFraction": .number(0.6)])])

        #expect(throws: CustomThemeParseError.self) { try themeWithSprings(springsWithATextResponse) }
    }

    @Test func springsThatAreNotAnObjectAreRefused() {
        #expect(throws: CustomThemeParseError.self) { try themeWithSprings(.string("bouncy")) }
    }

    @Test func springsSurviveTheTripThroughThemeJSON() throws {
        let theme = try themeWithSprings(springsJSON(popResponse: 0.3, popDamping: 0.6, glideResponse: 0.4, glideDamping: 0.8, pointResponse: 0.4))

        let reparsedTheme = try ClickyTheme.parse(themeJSON: theme.themeJSON, id: "idea-1", pictureIsAvailable: false)

        #expect(reparsedTheme.motion.springs == theme.motion.springs)
    }

    @Test func aThemeWithNoSpringsWritesNoSpringsField() throws {
        let theme = try ClickyTheme.parse(themeJSON: goodVersion2ThemeJSON, id: "idea-1", pictureIsAvailable: false)

        #expect(theme.themeJSON["motion"]?["springs"] == nil)
    }

    @Test func everyBundledThemeKeepsTheDefaultSprings() {
        #expect(!bundledThemesForTests.isEmpty)
        for bundledTheme in bundledThemesForTests {
            #expect(bundledTheme.motion.springs == nil, "\(bundledTheme.id)")
        }
    }

    @Test @MainActor func theShownMoveSpringsFollowAPreviewAndItsEndAndASavedThemeWithNoRepeat() throws {
        let bouncyIdea = try themeWithSprings(springsJSON(popResponse: 0.3, popDamping: 0.6, glideResponse: 0.4, glideDamping: 0.8, pointResponse: 0.4))

        let themeSettings = makeThemeSettings()
        var springsReceived: [ThemeMoveSprings] = []
        let subscription = themeSettings.observeShownMoveSprings { springsReceived.append($0) }
        themeSettings.preview(bouncyIdea, picture: nil)
        themeSettings.preview(bouncyIdea, picture: nil)
        themeSettings.clearPreview()
        themeSettings.theme = bouncyIdea
        subscription.cancel()

        #expect(springsReceived == [.standard, bouncyIdea.moveSprings, .standard, bouncyIdea.moveSprings])
    }

    @Test func aTileThatIsNotHighlightedSitsSmallerExceptWithReduceMotion() {
        #expect(themeStudioTileScale(isHighlighted: true, reduceMotionIsOn: false) == 1)
        #expect(themeStudioTileScale(isHighlighted: false, reduceMotionIsOn: false) == 0.92)
        #expect(themeStudioTileScale(isHighlighted: false, reduceMotionIsOn: true) == 1)
    }

    @Test func aThemesFeelIsNamedFromItsPopSpring() throws {
        func feel(_ popResponse: Double, _ popDamping: Double) throws -> String? {
            themeMotionFeel(of: try themeWithSprings(springsJSON(popResponse: popResponse, popDamping: popDamping, glideResponse: 0.4, glideDamping: 0.8, pointResponse: 0.4)).moveSprings)
        }

        #expect(try feel(0.3, 0.55) == "bouncy motion")
        #expect(try feel(0.42, 1) == "calm motion")
        #expect(try feel(0.2, 0.9) == "snappy motion")
        #expect(try feel(0.22, 0.9) == "snappy motion", "the prompt's own snappy example")
        #expect(try feel(0.32, 0.8) == "custom motion")
        #expect(themeMotionFeel(of: .standard) == nil)
    }

    @Test func theStudiosTagsNameABouncyIdeaAndKeepTheSoundsLast() throws {
        let bouncyIdea = try themeWithSprings(springsJSON(popResponse: 0.3, popDamping: 0.55, glideResponse: 0.4, glideDamping: 0.8, pointResponse: 0.4))
        let plainIdea = try ClickyTheme.parse(themeJSON: goodVersion2ThemeJSON, id: "idea-1", pictureIsAvailable: false)

        let bouncyTags = themeStudioTags(for: bouncyIdea)

        #expect(bouncyTags.contains("bouncy motion"))
        #expect(bouncyTags.last?.hasPrefix("sounds:") == true)
        #expect(!themeStudioTags(for: plainIdea).contains { $0.hasSuffix("motion") })
    }

    @Test func anIdeaPreviewedOnTheStudioSetsTheSpringsTheShownThemeCarries() async throws {
        let bouncyIdea = try themeWithSprings(springsJSON(popResponse: 0.3, popDamping: 0.6, glideResponse: 0.4, glideDamping: 0.8, pointResponse: 0.4))

        let shownSprings = await MainActor.run { () -> (ThemeMoveSprings, ThemeMoveSprings) in
            let themeSettings = makeThemeSettings()
            let beforeThePreview = themeSettings.shownTheme.moveSprings
            themeSettings.preview(bouncyIdea, picture: nil)
            return (beforeThePreview, themeSettings.shownTheme.moveSprings)
        }

        #expect(shownSprings.0 == .standard)
        #expect(shownSprings.1 == bouncyIdea.moveSprings)
    }
}

struct ThemeMoveCurveTests {
    private let bouncySprings = ThemeMoveSprings(
        pop: ThemeSpring(response: 0.3, dampingFraction: 0.6),
        glide: ThemeSpring(response: 0.4, dampingFraction: 0.8),
        pointResponse: 0.4
    )

    @Test @MainActor func clickysOwnSpringsGiveTheSpecsNumbers() {
        #expect(DS.Move.pop.curve(using: .standard) == .spring(response: 0.32, dampingFraction: 0.68))
        #expect(DS.Move.glide.curve(using: .standard) == .spring(response: 0.42, dampingFraction: 0.9))
        #expect(DS.Move.point.curve(using: .standard) == .pacedByDistance(pointsPerSecond: 800, shortestSeconds: 0.6, longestSeconds: 1.4, bezier: .smoothstep))
    }

    @Test @MainActor func aThemesSpringsChangeOnlyPopGlideAndPoint() {
        for move in DS.Move.allCases {
            let changed = move.curve(using: bouncySprings) != move.curve(using: .standard)
            #expect(changed == [DS.Move.pop, .glide, .point].contains(move), "\(move)")
        }
    }

    @Test @MainActor func aThemesPopAndGlideSpringsReachTheCurves() {
        #expect(DS.Move.pop.curve(using: bouncySprings) == .spring(response: 0.3, dampingFraction: 0.6))
        #expect(DS.Move.glide.curve(using: bouncySprings) == .spring(response: 0.4, dampingFraction: 0.8))
    }

    @Test @MainActor func aPointResponseOfFourTenthsMakesTheFlightEightTenthsAsLong() {
        let standardSeconds = DS.Move.point.curve(using: .standard).seconds(travelingPoints: 800)
        let quickerSeconds = DS.Move.point.curve(using: bouncySprings).seconds(travelingPoints: 800)

        #expect(abs(quickerSeconds - standardSeconds * 0.8) < 1e-9)
    }

    @Test @MainActor func aTilePlaysPopWithItsOwnIdeasSpringsNotTheShownThemes() {
        let playedWithTheIdeasSprings = DS.Move.pop.animation(reduceMotionIsOn: false, springs: bouncySprings)

        #expect(playedWithTheIdeasSprings == .spring(response: 0.3, dampingFraction: 0.6))
        #expect(playedWithTheIdeasSprings != DS.Move.pop.animation(reduceMotionIsOn: false, springs: .standard))
    }

    @Test @MainActor func reduceMotionIgnoresTheThemesSprings() {
        for move in [DS.Move.pop, .glide, .point] {
            #expect(move.animation(reduceMotionIsOn: true, springs: bouncySprings) == move.animation(reduceMotionIsOn: true, springs: .standard))
            #expect(move.animation(reduceMotionIsOn: true, springs: bouncySprings) == .easeOut(duration: move.reduceMotionForm.fadeSeconds))
        }
    }

    @Test @MainActor func theSlowestAndBounciestSpringsStillSettleQuicklyAndStayInsideTheirFrame() {
        let slowestAndBounciest = ThemeMoveSprings(
            pop: ThemeSpring(response: ThemeMoveSprings.popLimits.response.upperBound, dampingFraction: ThemeMoveSprings.popLimits.dampingFraction.lowerBound),
            glide: ThemeSpring(response: ThemeMoveSprings.glideLimits.response.upperBound, dampingFraction: ThemeMoveSprings.glideLimits.dampingFraction.lowerBound),
            pointResponse: ThemeMoveSprings.pointResponseLimits.upperBound
        )
        let popCurve = DS.Move.pop.curve(using: slowestAndBounciest)
        let glideCurve = DS.Move.glide.curve(using: slowestAndBounciest)

        // No surface feels stuck: every spring settles in under 0.85 s, and a flight takes under 1.7 s at its longest.
        #expect(popCurve.seconds() < 0.85)
        #expect(glideCurve.seconds() < 0.85)
        #expect(DS.Move.point.curve(using: slowestAndBounciest).seconds(travelingPoints: 100_000) < 1.7)

        // No surface leaves its frame: a Pop overshoots by at most 13 percent and a Glide by at most 3 percent.
        func highestProgress(of curve: MoveCurve) -> Double {
            stride(from: 0.0, through: curve.seconds(), by: 0.002).map { curve.progress(atSeconds: $0) }.max() ?? 0
        }
        #expect(highestProgress(of: popCurve) < 1.13)
        #expect(highestProgress(of: glideCurve) < 1.03)
    }
}
