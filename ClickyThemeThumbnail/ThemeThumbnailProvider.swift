//
//  ThemeThumbnailProvider.swift
//  ClickyThemeThumbnail
//
//  Finder's icon for a `.clickytheme` file: `ThemeFileThumbnailView`, the theme's cursor and colors, drawn at the size and
//  scale Finder asks for. It reads the package with `readThemeFileForQuickLook`, as the preview extension does, so a file
//  Clicky would refuse keeps the plain document icon. The target compiles the theme's own source files from
//  leanring-buddy/, listed in the project file, and none of the app's.
//

import AppKit
import QuickLookThumbnailing

nonisolated final class ThemeThumbnailProvider: QLThumbnailProvider {
    struct ThumbnailCouldNotBeDrawn: Error {}

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let themeFile: ThemeFileForQuickLook
        do {
            themeFile = try readThemeFileForQuickLook(at: request.fileURL)
        } catch {
            handler(nil, error)
            return
        }
        // The icon is square, so it takes the shorter side Finder allows.
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let scale = request.scale
        Task { @MainActor in
            let picture = themeFile.pictureJPEG.flatMap(NSImage.init(data:))
            guard let thumbnailImage = themeFileThumbnailImage(theme: themeFile.theme, picture: picture, side: side, scale: scale) else {
                handler(nil, ThumbnailCouldNotBeDrawn())
                return
            }
            handler(QLThumbnailReply(contextSize: CGSize(width: side, height: side)) { context in
                // The context Quick Look hands over measures in pixels, `side` times the scale, so the image fills the
                // context's own bounds. Drawing it at `side` points filled only the bottom-left quarter at 2x.
                context.draw(thumbnailImage, in: context.boundingBoxOfClipPath)
                return true
            }, nil)
        }
    }
}
