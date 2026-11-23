//
//  RoomArtPhoto.swift
//  leanring-buddy
//
//  Saving what the room art panel shows: the painted shirt still, or the room with its placed items. The Save photo button
//  or "save this photo" writes the frame as the panel last drew it, at the camera's own resolution, as a JPEG in
//  ~/Pictures/Clicky. This file holds the pure rules (when a photo can be saved, the phrase, the file name) and the write.
//

import CoreGraphics
import Foundation

extension RoomArtPlacedItem {
    /// The store page's title for the item.
    nonisolated var title: String {
        switch self {
        case .wallArt(let artwork): return artwork.title
        case .furniture(let furniture): return furniture.title
        }
    }
}

extension RoomArtPhase {
    /// What a saved photo is named after when the panel shows a result worth keeping, and nil otherwise: the painted shirt
    /// still, an item on its surface, or a kept room whose newest item failed, which still shows the items placed before it.
    /// A live preview, a ghost, or a painting still on its way shows nothing that is a result yet.
    nonisolated var photoTitleToSave: String? {
        switch self {
        case .showingThePaintedShirt(let title, _): return title
        case .showing(let item, _, _): return item.title
        case .roomKeptAfterAFailedItem: return "room"
        default: return nil
        }
    }
}

/// The longest item title a photo's file name keeps, in UTF-8 bytes. A file name may be 255 bytes, and the prefix, the
/// date, a " 99" copy suffix, and the extension take about 45 of them, so 150 leaves room to spare for any title.
nonisolated let roomArtPhotoTitleLongestUTF8Bytes = 150

/// The file name of a saved photo: "Clicky try-on <item title> <yyyy-MM-dd HH.mm.ss>.jpg", with the title cut to
/// `roomArtPhotoTitleLongestUTF8Bytes` at a character boundary, so an emoji or an accented letter is never split. A slash,
/// a colon, a control character, or a bidirectional control in the title becomes a hyphen and a leading dot is dropped, so
/// a store's title can never name a folder, a hidden file, or a file that reads backward. The time is in `timeZone`, the learner's own by default.
nonisolated func roomArtPhotoFileName(itemTitle: String, savedAt date: Date, timeZone: TimeZone = .current) -> String {
    // Only true control characters (the Cc category) and the bidirectional controls. `CharacterSet.controlCharacters` also
    // holds every format character, such as the zero-width joiner inside a family emoji or the tags of a flag emoji, which
    // are safe in a file name and would split the emoji into hyphens.
    let unsafeScalars = CharacterSet(charactersIn: "/:\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
    var safeTitle = String(String.UnicodeScalarView(itemTitle.unicodeScalars.map {
        unsafeScalars.contains($0) || $0.properties.generalCategory == .control ? "-" : $0
    }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while safeTitle.hasPrefix(".") { safeTitle.removeFirst() }
    var bytesKept = 0
    safeTitle = String(safeTitle.prefix { character in
        bytesKept += character.utf8.count
        return bytesKept <= roomArtPhotoTitleLongestUTF8Bytes
    }).trimmingCharacters(in: .whitespaces)
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = timeZone
    dateFormatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let stamp = dateFormatter.string(from: date)
    return safeTitle.isEmpty ? "Clicky try-on \(stamp).jpg" : "Clicky try-on \(safeTitle) \(stamp).jpg"
}

/// Whether the learner asked to save the panel's photo, as the whole utterance: "save this photo", "save the photo",
/// "save photo" (the button's own label), or the same with "picture" or "pic", with a few words of agreement before and
/// please after. "Save it" is left to the Theme Studio's `save_theme`, and a longer request goes to the router.
nonisolated func asksToSaveTheRoomArtPhoto(_ transcript: String) -> Bool {
    let words = transcript.lowercased()
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
        .split(separator: " ")
        .map(String.init)
    let wordsBeforeTheRequest: Set<String> = ["hey", "clicky", "okay", "ok", "yeah", "yes", "perfect", "great", "nice", "cool", "um", "so", "and", "now", "please", "can", "you", "could"]
    let wordsAfterTheRequest: Set<String> = ["please", "clicky", "thanks", "now", "for", "me"]
    var requestWords = Array(words.drop { wordsBeforeTheRequest.contains($0) })
    while let lastWord = requestWords.last, wordsAfterTheRequest.contains(lastWord) { requestWords.removeLast() }
    guard requestWords.first == "save", let photoWord = requestWords.last, ["photo", "picture", "pic"].contains(photoWord) else { return false }
    switch requestWords.count {
    case 2: return true
    case 3: return ["this", "the", "that", "a"].contains(requestWords[1])
    default: return false
    }
}

/// Whether "save this photo" runs ahead of the router: only while the panel shows something to save, with no quiz question
/// open and the Theme Studio card, which holds every spoken word, closed.
nonisolated func roomArtSavePhraseRunsAheadOfTheRouter(asksToSave: Bool, aPhotoCanBeSaved: Bool, quizQuestionIsOpen: Bool, themeStudioIsOpen: Bool) -> Bool {
    asksToSave && aPhotoCanBeSaved && !quizQuestionIsOpen && !themeStudioIsOpen
}

/// The chip after a save that worked, and after one that failed.
nonisolated let roomArtPhotoSavedChip = "Saved to Pictures · Clicky folder"
nonisolated let roomArtPhotoNotSavedChip = "Couldn't save the photo"

nonisolated enum RoomArtPhotoSaving {
    /// ~/Pictures/Clicky.
    static var standardFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("Clicky", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Clicky", isDirectory: true)
    }

    enum SaveError: Error, Equatable {
        case imageCouldNotBeEncoded
        /// The panel has drawn no frame yet.
        case nothingDrawnYet
    }

    /// Writes `image` as a JPEG named by `roomArtPhotoFileName` into `folder`, which it creates, and returns the file. A
    /// name already taken in the same second gets " 2", " 3", and so on before its extension, so a save never replaces one.
    static func save(_ image: CGImage, itemTitle: String, savedAt date: Date, in folder: URL) throws -> URL {
        guard let photoData = jpegData(of: image, quality: 0.92) else { throw SaveError.imageCouldNotBeEncoded }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = roomArtPhotoFileName(itemTitle: itemTitle, savedAt: date)
        let baseName = (fileName as NSString).deletingPathExtension
        var fileURL = folder.appendingPathComponent(fileName)
        var copyNumber = 2
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = folder.appendingPathComponent("\(baseName) \(copyNumber).jpg")
            copyNumber += 1
        }
        try photoData.write(to: fileURL, options: .withoutOverwriting)
        return fileURL
    }
}
