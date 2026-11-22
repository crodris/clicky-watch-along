//
//  ThemeFileExportTests.swift
//  leanring-buddyTests
//
//  Sharing a theme as a file: what an exported `.clickytheme` package holds, that it installs back through the same checks a
//  double-clicked file takes, and the Quick Look preview rendered at 2x.
//

import AppKit
import Foundation
import Testing
@testable import Clicky

struct ThemeFileExportTests {
    private let pictureBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    /// A fresh folder for one test's packages, removed when the test ends.
    private func withAnExportFolder(_ body: (URL) throws -> Void) throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-test-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try body(folderURL)
    }

    private func filesInside(_ packageURL: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: packageURL, includingPropertiesForKeys: [.isRegularFileKey])
        var relativePaths: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard (try fileURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            relativePaths.append(String(fileURL.resolvingSymlinksInPath().path.dropFirst(packageURL.resolvingSymlinksInPath().path.count + 1)))
        }
        return relativePaths.sorted()
    }

    /// The fields a learner sees, which an install keeps while it gives the theme a new id and folder.
    private func sameThemeApartFromWhereItLives(_ firstTheme: ClickyTheme, _ secondTheme: ClickyTheme) -> Bool {
        firstTheme.with(id: "compared", origin: .idea) == secondTheme.with(id: "compared", origin: .idea)
    }

    @Test func aSavedThemeWithAPictureExportsItsThemeFileAndPictureAndInstallsBackTheSame() throws {
        try withATemporaryThemeStore { store in
            let savedTheme = try store.save(try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true), pictureJPEG: pictureBytes)
            try withAnExportFolder { exportFolderURL in
                let packageURL = exportFolderURL.appendingPathComponent("Moonlit.clickytheme", isDirectory: true)
                try CustomThemeStore.exportPackage(of: savedTheme, toPackageAt: packageURL)
                #expect(try filesInside(packageURL) == ["picture.jpg", "theme.json"])
                #expect(try Data(contentsOf: packageURL.appendingPathComponent("picture.jpg")) == pictureBytes)

                let preview = try store.previewPackage(at: packageURL)
                #expect(sameThemeApartFromWhereItLives(preview.theme, savedTheme))
                let installedTheme = try store.install(packageAt: packageURL, expectedPreview: preview)
                #expect(installedTheme.id != savedTheme.id)
                #expect(sameThemeApartFromWhereItLives(installedTheme, savedTheme))
            }
        }
    }

    @Test func aBundledSchoolNeverExportsItsPortraitsButKeepsItsPlayers() throws {
        // The bundled schools' portraits are local wiki art, so the file names every player and the faces show initials.
        let schoolTheme = bundledTheme("school-karasuno")
        guard case .roster(let bundledPlayers) = schoolTheme.agents.faces else {
            Issue.record("Karasuno has a roster")
            return
        }
        #expect(bundledPlayers.contains { $0.portraitFileName != nil })
        try withATemporaryThemeStore { store in
            try withAnExportFolder { exportFolderURL in
                let packageURL = exportFolderURL.appendingPathComponent("Karasuno.clickytheme", isDirectory: true)
                try CustomThemeStore.exportPackage(of: schoolTheme, toPackageAt: packageURL)
                #expect(try filesInside(packageURL) == ["theme.json"])
                let themeFileText = try String(contentsOf: packageURL.appendingPathComponent("theme.json"), encoding: .utf8)
                #expect(!themeFileText.contains("\"portrait\""))

                let installedTheme = try store.install(packageAt: packageURL)
                guard case .roster(let installedPlayers) = installedTheme.agents.faces else {
                    Issue.record("The installed theme keeps its roster")
                    return
                }
                #expect(installedPlayers.map(\.name) == bundledPlayers.map(\.name))
                #expect(installedPlayers.map(\.number) == bundledPlayers.map(\.number))
                #expect(installedPlayers.allSatisfy { $0.portraitFileName == nil })
            }
        }
    }

    @Test func aSavedRosterExportsThePortraitsItShipsAndDropsOneItLacks() throws {
        try withATemporaryThemeStore { store in
            let rosterJSON = replacingField(in: goodVersion2ThemeJSON, at: ["agents"], with: .object([
                "ring": .string("accent"),
                "faces": .object(["kind": .string("roster"), "players": .array([
                    .object(["name": .string("Ada"), "portrait": .string("faces/ada.jpg")]),
                    .object(["name": .string("Grace"), "portrait": .string("faces/grace.jpg")]),
                ])]),
            ]))
            try withAnExportFolder { exportFolderURL in
                // The saved theme as an install leaves it: theme.json and the one portrait the sender had.
                let sentPackageURL = exportFolderURL.appendingPathComponent("Sent.clickytheme", isDirectory: true)
                try FileManager.default.createDirectory(at: sentPackageURL.appendingPathComponent("faces"), withIntermediateDirectories: true)
                try JSONEncoder().encode(rosterJSON).write(to: sentPackageURL.appendingPathComponent("theme.json"))
                try pictureBytes.write(to: sentPackageURL.appendingPathComponent("faces/ada.jpg"))
                let savedTheme = try store.install(packageAt: sentPackageURL)

                let packageURL = exportFolderURL.appendingPathComponent("Moonlit.clickytheme", isDirectory: true)
                try CustomThemeStore.exportPackage(of: savedTheme, toPackageAt: packageURL)
                #expect(try filesInside(packageURL) == ["faces/ada.jpg", "theme.json"])
                let exportedTheme = try store.previewPackage(at: packageURL).theme
                guard case .roster(let exportedPlayers) = exportedTheme.agents.faces else {
                    Issue.record("The exported theme keeps its roster")
                    return
                }
                #expect(exportedPlayers.map(\.portraitFileName) == ["faces/ada.jpg", nil])
            }
        }
    }

    @Test func anIdeaOrAFolderThatIsAlreadyThereIsNotExported() throws {
        let idea = try parsedThemeIdea()
        try withAnExportFolder { exportFolderURL in
            let packageURL = exportFolderURL.appendingPathComponent("Moonlit.clickytheme", isDirectory: true)
            #expect(throws: CustomThemeStoreError.anIdeaCannotBeExported) { try CustomThemeStore.exportPackage(of: idea, toPackageAt: packageURL) }
            #expect(!FileManager.default.fileExists(atPath: packageURL.path))

            // An export never writes into, or cleans up, a folder it did not make.
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: packageURL.appendingPathComponent("notes.txt"))
            #expect(throws: CustomThemeStoreError.exportFolderAlreadyExists) {
                try CustomThemeStore.exportPackage(of: clickyBlueTheme, toPackageAt: packageURL)
            }
            #expect(try filesInside(packageURL) == ["notes.txt"])
        }
    }

    @Test func aSavedThemeWhosePictureIsGoneIsNotExported() throws {
        try withATemporaryThemeStore { store in
            let savedTheme = try store.save(try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true), pictureJPEG: pictureBytes)
            try FileManager.default.removeItem(at: store.pictureURL(forThemeID: savedTheme.id))
            try withAnExportFolder { exportFolderURL in
                let packageURL = exportFolderURL.appendingPathComponent("Moonlit.clickytheme", isDirectory: true)
                #expect(throws: CustomThemeStoreError.themeUsesAPictureButNoneWasGiven) {
                    try CustomThemeStore.exportPackage(of: savedTheme, toPackageAt: packageURL)
                }
            }
        }
    }

    @Test func thePackageIsNamedForTheThemeWithNoCharacterAFileNameCannotHold() {
        #expect(CustomThemeStore.exportedPackageFileName(forThemeName: "Moonlit") == "Moonlit.clickytheme")
        #expect(CustomThemeStore.exportedPackageFileName(forThemeName: "Night/Day: 2") == "Night-Day- 2.clickytheme")
        #expect(CustomThemeStore.exportedPackageFileName(forThemeName: "..hidden") == "-.hidden.clickytheme")
        #expect(CustomThemeStore.exportedPackageFileName(forThemeName: "Tab\there") == "Tab-here.clickytheme")
        // A dot after leading spaces still hides nothing, and an emoji with a zero-width joiner stays whole.
        #expect(CustomThemeStore.exportedPackageFileName(forThemeName: " .x") == "-x.clickytheme")
        #expect(CustomThemeStore.exportedPackageFileName(forThemeName: "Coder 👩‍💻") == "Coder 👩‍💻.clickytheme")
    }

    @Test func aDragWritesTheLatestPackageOnlyAndItInstalls() throws {
        let exportsFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-test-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: exportsFolderURL) }
        let firstPackageURL = try ThemeFileDrag.writePromisedPackage(of: clickyBlueTheme, named: "Clicky blue.clickytheme", exportsFolderURL: exportsFolderURL)
        let secondPackageURL = try ThemeFileDrag.writePromisedPackage(of: bundledTheme("school-karasuno"), named: "Karasuno.clickytheme", exportsFolderURL: exportsFolderURL)
        #expect(secondPackageURL.lastPathComponent == "Karasuno.clickytheme")
        #expect(!FileManager.default.fileExists(atPath: firstPackageURL.path))
        try withATemporaryThemeStore { store in
            let preview = try store.previewPackage(at: secondPackageURL)
            #expect(preview.theme.name == "Karasuno")
        }
    }

    // MARK: - The Quick Look preview

    /// The preview rendered at 2x as Quick Look gets it, read back as a bitmap.
    @MainActor
    private func renderedPreview(of theme: ClickyTheme, picture: NSImage? = nil) throws -> NSBitmapImageRep {
        let pngData = try #require(themeFilePreviewPNGData(theme: theme, picture: picture))
        return try #require(NSBitmapImageRep(data: pngData))
    }

    @MainActor
    @Test func thePreviewRendersEveryBundledThemeAtTwiceItsSizeOnTheCard() throws {
        for theme in bundledThemesForTests {
            let bitmap = try renderedPreview(of: theme)
            #expect(bitmap.pixelsWide == Int(ThemeFilePreviewView.size.width * 2))
            #expect(bitmap.pixelsHigh == Int(ThemeFilePreviewView.size.height * 2))
            // The card's rounded corner is clear apart from its edge's antialiasing, and its right side is the dark card
            // surface, so no text or swatch runs past the card.
            #expect((bitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.2)
            let rightSideColor = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 40, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            #expect(rightSideColor.alphaComponent > 0.95 && rightSideColor.brightnessComponent < 0.2)
        }
    }

    @MainActor
    @Test func thePreviewDrawsTheCursorInTheAccentInTheMiddleOfItsDisc() throws {
        // Clicky blue's triangle fills the disc's middle in the accent color.
        let bitmap = try renderedPreview(of: clickyBlueTheme)
        let discCenterX = (24 + 66) * 2
        let discCenterY = Int(ThemeFilePreviewView.size.height)
        let cursorColor = try #require(bitmap.colorAt(x: discCenterX, y: discCenterY)?.usingColorSpace(.sRGB))
        let accentColor = try #require(NSColor(hex: clickyBlueTheme.accentHex)?.usingColorSpace(.sRGB))
        // The renderer draws in the display's color space, so the accent comes back a little off its sRGB value.
        #expect(abs(cursorColor.redComponent - accentColor.redComponent) < 0.12)
        #expect(abs(cursorColor.greenComponent - accentColor.greenComponent) < 0.12)
        #expect(abs(cursorColor.blueComponent - accentColor.blueComponent) < 0.12)
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        guard let rgbColor = ThemeRGBColor(hex: hex) else { return nil }
        self.init(srgbRed: rgbColor.red, green: rgbColor.green, blue: rgbColor.blue, alpha: 1)
    }
}
