//
//  ThemePreviewProvider.swift
//  ClickyThemeQuickLook
//
//  Finder's Quick Look preview of a `.clickytheme` file. It reads the package with `readThemeFileForQuickLook`, the same
//  read the thumbnail extension uses, and returns `ThemeFilePreviewView` rendered at 2x as a PNG. The target compiles the
//  theme's own source files from leanring-buddy/, listed in the project file, and none of the app's.
//

import AppKit
import QuickLookUI
import UniformTypeIdentifiers

nonisolated final class ThemePreviewProvider: QLPreviewProvider, QLPreviewingController {
    struct PreviewCouldNotBeDrawn: Error {}

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let themeFile = try readThemeFileForQuickLook(at: request.fileURL)
        let (pngData, previewSize) = await MainActor.run {
            (themeFilePreviewPNGData(theme: themeFile.theme, picture: themeFile.pictureJPEG.flatMap(NSImage.init(data:))), ThemeFilePreviewView.size)
        }
        guard let pngData else { throw PreviewCouldNotBeDrawn() }
        return QLPreviewReply(dataOfContentType: .png, contentSize: previewSize) { _ in pngData }
    }
}
