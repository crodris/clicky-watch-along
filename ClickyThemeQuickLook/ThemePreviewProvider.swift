//
//  ThemePreviewProvider.swift
//  ClickyThemeQuickLook
//
//  Finder's Quick Look preview of a `.clickytheme` file. It reads the package with `CustomThemeStore.previewPackage`, the
//  same read and the same `ClickyTheme.parse` rules an install applies, so a file Clicky would refuse shows Quick Look's
//  plain fallback instead of a theme. It returns `ThemeFilePreviewView` rendered at 2x as a PNG. The target compiles the
//  theme's own source files from leanring-buddy/, listed in the project file, and none of the app's.
//

import AppKit
import QuickLookUI
import UniformTypeIdentifiers

nonisolated final class ThemePreviewProvider: QLPreviewProvider, QLPreviewingController {
    struct PreviewCouldNotBeDrawn: Error {}

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // `previewPackage` reads only the package, so the store's own folder is never touched. The extension's sandbox
        // has no folder of Clicky's, so the store points at its temporary folder.
        let store = CustomThemeStore(themesDirectoryURL: FileManager.default.temporaryDirectory)
        let packagePreview = try store.previewPackage(at: request.fileURL)
        let pictureJPEG = packagePreview.pictureJPEG
        let (pngData, previewSize) = await MainActor.run {
            (themeFilePreviewPNGData(theme: packagePreview.theme, picture: pictureJPEG.flatMap(NSImage.init(data:))), ThemeFilePreviewView.size)
        }
        guard let pngData else { throw PreviewCouldNotBeDrawn() }
        return QLPreviewReply(dataOfContentType: .png, contentSize: previewSize) { _ in pngData }
    }
}
