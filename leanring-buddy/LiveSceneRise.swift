//
//  LiveSceneRise.swift
//  leanring-buddy
//
//  Makes a generated live scene rise out of the video or image it was asked about.
//  The bundled scene-rise.js shows the cursor screen screenshot clipped to the
//  media's rect, then lifts the page out of that rect.
//

import Foundation

/// The bundled rise script, or nil when it is missing, in which case the scene plays without a rise.
func liveSceneRiseScriptFromTheBundle() -> String? {
    let scriptURL = Bundle.main.url(forResource: "scene-rise", withExtension: "js", subdirectory: "LiveSceneAssets")
        ?? Bundle.main.url(forResource: "scene-rise", withExtension: "js")
    guard let scriptURL, let riseScript = try? String(contentsOf: scriptURL, encoding: .utf8) else {
        print("Live scene: scene-rise.js is not in the app bundle")
        return nil
    }
    return riseScript
}

/// The generated page with the rise script added right before its last `</body>`,
/// or at the end when it has none. Returns the page unchanged when the rect cannot be encoded.
func liveScenePageThatRisesFromTheSource(
    generatedPageHTML: String,
    screenJPEGBase64: String,
    sourceRectInOverlayPage: [String: Double],
    riseScript: String
) -> String {
    let sceneRiseData: [String: Any] = [
        "screenDataURL": "data:image/jpeg;base64,\(screenJPEGBase64)",
        "sourceRect": sourceRectInOverlayPage,
    ]
    // isValidJSONObject first, because JSONSerialization raises an exception on NaN or infinity.
    // It also escapes "/" as "\/", so the data can never close the script tag.
    guard JSONSerialization.isValidJSONObject(sceneRiseData),
          let sceneRiseJSON = try? JSONSerialization.data(withJSONObject: sceneRiseData),
          let sceneRiseJSONText = String(data: sceneRiseJSON, encoding: .utf8) else {
        return generatedPageHTML
    }
    let riseScripts = "<script>window.__sceneRise = \(sceneRiseJSONText);</script><script>\(riseScript)</script>"
    guard let lastBodyCloseRange = generatedPageHTML.range(of: "</body>", options: [.backwards, .caseInsensitive]) else {
        return generatedPageHTML + riseScripts
    }
    var pageWithRise = generatedPageHTML
    pageWithRise.insert(contentsOf: riseScripts, at: lastBodyCloseRange.lowerBound)
    return pageWithRise
}
