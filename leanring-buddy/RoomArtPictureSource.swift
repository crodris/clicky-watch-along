//
//  RoomArtPictureSource.swift
//  leanring-buddy
//
//  Where room art gets the picture it hangs and sends to `POST /try-it-item`. A screen capture of the largest picture in
//  Chrome's front tab also captures whatever sits over it, such as a cookie banner, and that hung on the wall with the art
//  on 2026-11-21. So room art prefers the image file the page names, downloaded the same safe way an animated page image is
//  (`PageImageAnimation.downloadedImageData`), and captures the screen only when there is no file to use.
//

import Foundation
import ImageIO
import AppKit

enum RoomArtPictureSource {
    /// The long side of the picture room art keeps, the same size the screen capture is cut to.
    nonisolated static let longestSide = 1280
    /// The page names the URL, so a small file that claims a huge canvas is refused before it is decoded.
    nonisolated static let largestSideBeforeDecoding = PageImageAnimation.largestFrameSide
    nonisolated static let downloadTimeoutSeconds: TimeInterval = 5

    /// The picture room art uses: the page's image file when the front tab's largest picture names an https URL that
    /// downloads and decodes, else the screen capture, else nil. The log says which one was used.
    static func picture(
        imageFileURL: URL?,
        session: URLSession = PageImageAnimation.downloadSession,
        captureTheScreen: () async -> RoomArtPicture?
    ) async -> RoomArtPicture? {
        if let imageFileURL {
            if let downloadedPicture = await downloadedPicture(atImageURL: imageFileURL, session: session) {
                print("Room art: used the page's image file (\(downloadedPicture.width)x\(downloadedPicture.height)) from \(imageFileURL.host ?? "its page")")
                return downloadedPicture
            }
            print("Room art: could not use the page's image file, so the picture is a screen capture")
        } else {
            print("Room art: the largest picture names no https image file, so the picture is a screen capture")
        }
        return await captureTheScreen()
    }

    /// The image file scaled so its long side is at most `longestSide`, as a JPEG. Nil when the URL is not https (a
    /// redirect too), the reply is not a 200, the file passes 8 MB, a side passes `largestSideBeforeDecoding` before any
    /// decoding, or the bytes are not an image ImageIO reads.
    @concurrent nonisolated static func downloadedPicture(atImageURL imageURL: URL, session: URLSession) async -> RoomArtPicture? {
        guard let imageData = await PageImageAnimation.downloadedImageData(
            atImageURL: imageURL,
            timeoutSeconds: downloadTimeoutSeconds,
            session: session
        ) else {
            return nil
        }
        return picture(ofImageData: imageData)
    }

    nonisolated static func picture(ofImageData imageData: Data) -> RoomArtPicture? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        guard let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= largestSideBeforeDecoding, pixelHeight <= largestSideBeforeDecoding else {
            return nil
        }
        // A thumbnail at the smaller of the file's long side and `longestSide` never scales a small file up, and it
        // applies the file's orientation, which decoding the full image would leave out.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(pixelWidth, pixelHeight), longestSide),
        ]
        guard let scaledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let drawingContext = CGContext(
                  data: nil,
                  width: scaledImage.width,
                  height: scaledImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        // A product photo on a transparent background would turn black as a JPEG, so it is drawn over white.
        let wholePicture = CGRect(x: 0, y: 0, width: scaledImage.width, height: scaledImage.height)
        drawingContext.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        drawingContext.fill(wholePicture)
        drawingContext.draw(scaledImage, in: wholePicture)
        guard let drawnImage = drawingContext.makeImage(),
              let jpegData = NSBitmapImageRep(cgImage: drawnImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return RoomArtPicture(jpegData: jpegData, width: scaledImage.width, height: scaledImage.height)
    }
}
