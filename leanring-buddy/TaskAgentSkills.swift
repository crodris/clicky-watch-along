//
//  TaskAgentSkills.swift
//  leanring-buddy
//
//  The catalog of skills the voice router can start. A skill is a Markdown file, <name>.md, with front matter that the
//  Go harness reads in full (harness/skills.go). The app reads only the name and the description, so the router can
//  list each skill in the start_background_task tool.
//

import Foundation

/// One skill as the router sees it: a name to pass back and a line that says when to use it.
nonisolated struct TaskAgentSkillSummary: Equatable, Sendable {
    let name: String
    let description: String
}

nonisolated enum TaskAgentSkillCatalog {
    /// A description is the learner's own text, but it goes into a prompt, so it is cut to a line.
    static let longestDescriptionLength = 200

    /// The router reads every listed description, so the list is capped. Ten skills fit the Worker's tool description limit.
    static let mostSkillsListed = 10

    /// The harness accepts any lowercase letters, digits, and hyphens, since the name becomes part of a path. The
    /// catalog also caps the length, so a name the router offers stays short. A name never starts with a hyphen.
    static func isASkillName(_ candidateName: String) -> Bool {
        guard (1...40).contains(candidateName.count), candidateName.first != "-" else { return false }
        // asciiValue is nil for "é" and other characters that a Character range would let through.
        return candidateName.allSatisfy { character in
            guard let asciiValue = character.asciiValue else { return false }
            return (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(asciiValue)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(asciiValue)
                || asciiValue == UInt8(ascii: "-")
        }
    }

    /// Reads the front matter the way `parseSkill` in harness/skills.go does: it opens and closes with a "---" line,
    /// every other line is key: value, and a skill needs a name that matches its file, a description, and some text
    /// after the front matter. Nil for a file that is not whole or whose name is not a valid skill name.
    static func summary(fromFileText fileText: String, expectedName: String) -> TaskAgentSkillSummary? {
        guard isASkillName(expectedName) else { return nil }
        let lines = fileText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closingLineIndex = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }

        var skillName = ""
        var skillDescription = ""
        for line in lines[1..<closingLineIndex] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let colonIndex = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "name": skillName = value
            case "description": skillDescription = value
            default: break
            }
        }

        let skillText = lines[(closingLineIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard skillName == expectedName, !skillDescription.isEmpty, !skillText.isEmpty else { return nil }
        return TaskAgentSkillSummary(name: skillName, description: String(skillDescription.prefix(longestDescriptionLength)))
    }

    /// Reads every <name>.md in the folders, which are in priority order, so the learner's folder comes first. The
    /// harness takes the first folder that has <name>.md and fails the task when that file is malformed, so a file
    /// that claims a name keeps the name from a later folder even when it is not whole. The result is sorted by name.
    static func skills(inDirectoryURLs skillsDirectoryURLs: [URL], fileManager: FileManager = .default) -> [TaskAgentSkillSummary] {
        var claimedNames: Set<String> = []
        var skills: [TaskAgentSkillSummary] = []
        for skillsDirectoryURL in skillsDirectoryURLs {
            let fileNames = (try? fileManager.contentsOfDirectory(atPath: skillsDirectoryURL.path)) ?? []
            for fileName in fileNames.sorted() where fileName.hasSuffix(".md") {
                let skillName = String(fileName.dropLast(".md".count))
                guard isASkillName(skillName), claimedNames.insert(skillName).inserted else { continue }
                let fileURL = skillsDirectoryURL.appendingPathComponent(fileName)
                guard let fileText = try? String(contentsOf: fileURL, encoding: .utf8),
                      let skill = summary(fromFileText: fileText, expectedName: skillName) else {
                    print("Skills: skipping \(fileURL.path), which is not a whole skill file")
                    continue
                }
                skills.append(skill)
            }
        }
        return Array(skills.sorted { $0.name < $1.name }.prefix(mostSkillsListed))
    }

    /// The skills on disk right now. The folders are tiny, so each call reads them again and a skill added later shows
    /// up with no relaunch.
    static func currentSkills() -> [TaskAgentSkillSummary] {
        skills(inDirectoryURLs: TaskAgentFolders.skillsDirectoryURLs(bundleResourceURL: Bundle.main.resourceURL))
    }

    /// The skill a start_background_task call may run. A name the catalog does not list gets no skill, since the harness
    /// would fail the task for it. `skillWasDropped` tells the caller to log the name.
    static func skillNameToRun(requestedName: String?, catalog: [TaskAgentSkillSummary]) -> (name: String?, skillWasDropped: Bool) {
        guard let requestedName = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedName.isEmpty else {
            return (nil, false)
        }
        guard catalog.contains(where: { $0.name == requestedName }) else { return (nil, true) }
        return (requestedName, false)
    }

    /// The step line a skill task shows before the agent reports its first step.
    static func startingStepText(skillName: String) -> String {
        "Using the \(skillName) skill"
    }
}
