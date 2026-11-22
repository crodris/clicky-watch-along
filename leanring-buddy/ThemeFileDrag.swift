//
//  ThemeFileDrag.swift
//  leanring-buddy
//
//  Dragging a theme card out of the menu bar panel makes a `.clickytheme` file where it lands, such as the desktop or a
//  Finder window. The card hands the drag a file promise: the package is written only when a drop asks for it, into a
//  folder of Clicky's under the temporary directory, and the system copies it to the drop's place
//  (`CustomThemeStore.exportPackage` decides what the package holds).
//

import AppKit
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// The exported type in Info.plist, a package with the extension `clickytheme`.
    static let clickyTheme = UTType(exportedAs: "com.crodris.clicky-watch-along.theme", conformingTo: .package)
}

/// Nonisolated, since the item provider runs the load handler on its own queue, and the export touches no main actor state.
nonisolated enum ThemeFileDrag {
    /// Where the promised packages are written before the system copies them. Each drag empties it first, so it never
    /// holds more than the latest drag's package, and the copy at the drop's place is the learner's file.
    static let exportsFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("Clicky theme exports", isDirectory: true)

    /// The item a theme card hands to a drag.
    static func itemProvider(for theme: ClickyTheme) -> NSItemProvider {
        let packageFileName = CustomThemeStore.exportedPackageFileName(forThemeName: theme.name)
        let itemProvider = NSItemProvider()
        itemProvider.suggestedName = (packageFileName as NSString).deletingPathExtension
        itemProvider.registerFileRepresentation(forTypeIdentifier: UTType.clickyTheme.identifier, fileOptions: [], visibility: .all) { completion in
            do {
                completion(try writePromisedPackage(of: theme, named: packageFileName), false, nil)
            } catch {
                print("Theme file: could not write \(packageFileName): \(error)")
                completion(nil, false, error)
            }
            return nil
        }
        return itemProvider
    }

    /// Writes the package into a fresh folder of its own, so its file name can be the theme's name, and returns its URL. A
    /// test passes its own exports folder, since the default one is shared by every app and test run of this user.
    static func writePromisedPackage(of theme: ClickyTheme, named packageFileName: String, exportsFolderURL: URL = exportsFolderURL) throws -> URL {
        try? FileManager.default.removeItem(at: exportsFolderURL)
        let dragFolderURL = exportsFolderURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dragFolderURL, withIntermediateDirectories: true)
        let packageURL = dragFolderURL.appendingPathComponent(packageFileName, isDirectory: true)
        try CustomThemeStore.exportPackage(of: theme, toPackageAt: packageURL)
        print("Theme file: wrote \(packageFileName) for a drag")
        return packageURL
    }
}
