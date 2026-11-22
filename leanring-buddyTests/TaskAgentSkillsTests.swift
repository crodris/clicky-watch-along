//
//  TaskAgentSkillsTests.swift
//  leanring-buddyTests
//
//  The skill catalog the voice router lists in start_background_task, and the skill input it passes on. The front
//  matter rules match harness/skills.go, and harness/skills_test.go asserts the same flashcards name and description.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct TaskAgentSkillsTests {
    private func skillFileText(name: String, description: String, body: String = "Steps.") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\(body)"
    }

    /// A folder per call, left to the system's temporary directory cleanup.
    private func makeSkillsDirectory(files: [String: String]) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for (fileName, fileText) in files {
            try fileText.write(to: directoryURL.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }
        return directoryURL
    }

    @Test func theBundledFlashcardsSkillReadsTheSameWayAsInTheHarness() throws {
        // This file sits in leanring-buddyTests, next to leanring-buddy. swift-check links it, so resolve the link first.
        let repositoryRootURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let bundledSkillsURL = repositoryRootURL.appendingPathComponent("leanring-buddy/Skills", isDirectory: true)
        // The catalog skips a file it cannot read, so a read that fails under load would only show as a missing skill.
        // Reading the file here throws the operating system's own error, which names the cause.
        _ = try String(contentsOf: bundledSkillsURL.appendingPathComponent("flashcards.md"), encoding: .utf8)
        let skills = TaskAgentSkillCatalog.skills(inDirectoryURLs: [bundledSkillsURL])
        // harness/skills_test.go asserts these same two strings.
        #expect(skills.first { $0.name == "flashcards" } == TaskAgentSkillSummary(
            name: "flashcards",
            description: "Make flashcards from the video that is playing or the page on screen, and save them as a Notion page."
        ))
    }

    @Test func theCatalogSkipsFilesThatAreNotWholeSkills() throws {
        let directoryURL = try makeSkillsDirectory(files: [
            "good.md": skillFileText(name: "good", description: "Does a good thing."),
            "no-front-matter.md": "Just text.",
            "never-closed.md": "---\nname: never-closed\ndescription: Open.\nSteps.",
            "no-description.md": "---\nname: no-description\n---\nSteps.",
            "no-text.md": "---\nname: no-text\ndescription: Empty.\n---\n",
            "bad-line.md": "---\nname: bad-line\nthis line has no colon\ndescription: x\n---\nSteps.",
            "wrong-name.md": skillFileText(name: "other-name", description: "The name differs from the file."),
            "Upper.md": skillFileText(name: "Upper", description: "Capital letter."),
            "under_score.md": skillFileText(name: "under_score", description: "Underscore."),
            "-leading.md": skillFileText(name: "-leading", description: "Leading hyphen."),
            "notes.txt": "Not a skill file.",
        ])
        #expect(TaskAgentSkillCatalog.skills(inDirectoryURLs: [directoryURL]).map(\.name) == ["good"])
    }

    @Test func aSkillNameIsOneToFortyLowercaseLettersDigitsAndHyphens() {
        #expect(TaskAgentSkillCatalog.isASkillName("flashcards"))
        #expect(TaskAgentSkillCatalog.isASkillName("a"))
        #expect(TaskAgentSkillCatalog.isASkillName("study-cards-2"))
        #expect(TaskAgentSkillCatalog.isASkillName(String(repeating: "a", count: 40)))
        #expect(!TaskAgentSkillCatalog.isASkillName(String(repeating: "a", count: 41)))
        #expect(!TaskAgentSkillCatalog.isASkillName(""))
        #expect(!TaskAgentSkillCatalog.isASkillName("Flashcards"))
        #expect(!TaskAgentSkillCatalog.isASkillName("flash_cards"))
        #expect(!TaskAgentSkillCatalog.isASkillName("flash cards"))
        // An accented letter sorts between a and z, so a plain character range would let it through.
        #expect(!TaskAgentSkillCatalog.isASkillName("caf\u{00E9}"))
        #expect(!TaskAgentSkillCatalog.isASkillName("../secret"))
    }

    @Test func aFileTextWhoseNameIsNotASkillNameReadsAsNoSkill() {
        // The name matches the file name here, so only the name check refuses it.
        #expect(TaskAgentSkillCatalog.summary(fromFileText: skillFileText(name: "Upper", description: "x"), expectedName: "Upper") == nil)
        #expect(TaskAgentSkillCatalog.summary(fromFileText: skillFileText(name: "upper", description: "x"), expectedName: "upper")?.name == "upper")
    }

    @Test func aDescriptionIsCutToTwoHundredCharacters() throws {
        let directoryURL = try makeSkillsDirectory(files: [
            "wordy.md": skillFileText(name: "wordy", description: String(repeating: "x", count: 500)),
        ])
        let skills = TaskAgentSkillCatalog.skills(inDirectoryURLs: [directoryURL])
        #expect(skills.first?.description.count == 200)
    }

    @Test func theLearnersFileWinsOverTheBundledOneOfTheSameName() throws {
        let learnerDirectoryURL = try makeSkillsDirectory(files: [
            "flashcards.md": skillFileText(name: "flashcards", description: "Mine."),
            "mine-only.md": skillFileText(name: "mine-only", description: "Only mine."),
            // A learner's file that is not whole still claims the name, since the harness reads it first and fails the task.
            "broken.md": "not a skill",
        ])
        let bundledDirectoryURL = try makeSkillsDirectory(files: [
            "flashcards.md": skillFileText(name: "flashcards", description: "Bundled."),
            "bundled-only.md": skillFileText(name: "bundled-only", description: "Only bundled."),
            "broken.md": skillFileText(name: "broken", description: "Bundled and whole."),
        ])
        let skills = TaskAgentSkillCatalog.skills(inDirectoryURLs: [learnerDirectoryURL, bundledDirectoryURL])
        #expect(skills == [
            TaskAgentSkillSummary(name: "bundled-only", description: "Only bundled."),
            TaskAgentSkillSummary(name: "flashcards", description: "Mine."),
            TaskAgentSkillSummary(name: "mine-only", description: "Only mine."),
        ])
    }

    @Test func theCatalogListsAtMostTenSkillsSortedByName() throws {
        var skillFiles: [String: String] = [:]
        for skillNumber in 1...12 {
            let skillName = String(format: "skill-%02d", skillNumber)
            skillFiles["\(skillName).md"] = skillFileText(name: skillName, description: "Skill \(skillNumber).")
        }
        let directoryURL = try makeSkillsDirectory(files: skillFiles)
        let skillNames = TaskAgentSkillCatalog.skills(inDirectoryURLs: [directoryURL]).map(\.name)
        #expect(skillNames == (1...10).map { String(format: "skill-%02d", $0) })
    }

    @Test func aMissingFolderListsNoSkills() {
        let missingDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(TaskAgentSkillCatalog.skills(inDirectoryURLs: [missingDirectoryURL]).isEmpty)
    }

    @Test func aNameTheCatalogDoesNotListRunsWithNoSkill() {
        let catalog = [TaskAgentSkillSummary(name: "flashcards", description: "Make cards.")]
        let listedChoice = TaskAgentSkillCatalog.skillNameToRun(requestedName: "flashcards", catalog: catalog)
        #expect(listedChoice.name == "flashcards" && !listedChoice.skillWasDropped)
        let paddedChoice = TaskAgentSkillCatalog.skillNameToRun(requestedName: " flashcards ", catalog: catalog)
        #expect(paddedChoice.name == "flashcards" && !paddedChoice.skillWasDropped)
        for unlistedName in ["../etc", "missing"] {
            let droppedChoice = TaskAgentSkillCatalog.skillNameToRun(requestedName: unlistedName, catalog: catalog)
            #expect(droppedChoice.name == nil && droppedChoice.skillWasDropped)
        }
        let emptyCatalogChoice = TaskAgentSkillCatalog.skillNameToRun(requestedName: "flashcards", catalog: [])
        #expect(emptyCatalogChoice.name == nil && emptyCatalogChoice.skillWasDropped)
        // No skill asked for is not a dropped skill.
        for noRequest in [nil, "", "  "] {
            let noSkillChoice = TaskAgentSkillCatalog.skillNameToRun(requestedName: noRequest, catalog: catalog)
            #expect(noSkillChoice.name == nil && !noSkillChoice.skillWasDropped)
        }
    }

    @Test func startBackgroundTaskTakesASkillOnlyWhenTheCatalogHasSkills() {
        let plainDescriptor = AppVoiceTool.startBackgroundTask.descriptor(skills: [])
        #expect(plainDescriptor.inputSchema["properties"]?["skill"] == nil)
        #expect(!plainDescriptor.description.contains("Skills, each"))

        let skills = [
            TaskAgentSkillSummary(name: "flashcards", description: "Make flashcards from this video."),
            TaskAgentSkillSummary(name: "notes", description: "Take notes."),
        ]
        let skillDescriptor = AppVoiceTool.startBackgroundTask.descriptor(skills: skills)
        #expect(skillDescriptor.inputSchema["properties"]?["skill"]?["enum"]?.arrayValue == [.string("flashcards"), .string("notes")])
        #expect(skillDescriptor.inputSchema["required"]?.arrayValue == [.string("goal")])
        #expect(skillDescriptor.inputSchema["properties"]?["goal"] != nil)
        #expect(skillDescriptor.description.contains("flashcards: Make flashcards from this video."))
        #expect(skillDescriptor.description.contains("notes: Take notes."))
        #expect(skillDescriptor.description.contains("Leave skill out"))

        // Only start_background_task changes, and the router's offered list carries the skills through.
        #expect(AppVoiceTool.hearTaskAnswer.descriptor(skills: skills).inputSchema["properties"]?["skill"] == nil)
        let offeredWithSkills = voiceToolsOfferedToTheModel(pageTools: [], appTools: [.startBackgroundTask], skills: skills)
        #expect(offeredWithSkills.first?.inputSchema["properties"]?["skill"] != nil)
        let offeredWithNoSkills = voiceToolsOfferedToTheModel(pageTools: [], appTools: [.startBackgroundTask])
        #expect(offeredWithNoSkills.first?.inputSchema["properties"]?["skill"] == nil)
    }

    @Test func aSkillTaskShowsWhichSkillRuns() {
        #expect(TaskAgentSkillCatalog.startingStepText(skillName: "flashcards") == "Using the flashcards skill")
    }
}
