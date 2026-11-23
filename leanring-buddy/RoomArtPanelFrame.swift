//
//  RoomArtPanelFrame.swift
//  leanring-buddy
//
//  Where the room art panel sits and how large it is. The learner drags it by its handle and resizes it by its corner grip,
//  always at the camera's 16:9, so the video fills it and every point on it maps to one camera pixel the same way at any
//  size (`RoomArtVideoFit`). Its last frame is kept in UserDefaults, so it opens where the learner left it.
//

import CoreGraphics
import Foundation

/// The panel's shape, the camera's 1280 by 720.
nonisolated let roomArtPanelAspectRatio = 16.0 / 9.0
/// The size it opens at the first time.
nonisolated let roomArtPanelDefaultSize = CGSize(width: 960, height: 540)
/// The smallest size, which still fits the Close button, the status line, and the Save photo, Place, and Paint it buttons.
nonisolated let roomArtPanelSmallestSize = CGSize(width: 480, height: 270)
/// The UserDefaults key of the panel's last frame, as `NSStringFromRect` writes it.
nonisolated let roomArtPanelFrameDefaultsKey = "roomArtPanelFrame"

/// The frame the panel opens at: the saved one when its middle is on a screen, kept inside that screen's visible frame
/// and at least the smallest size, or else the default size in the middle of the screen under the mouse. A saved frame
/// whose screen was unplugged opens on the mouse's screen.
nonisolated func roomArtPanelFrameToShow(savedFrame: CGRect?, visibleFrames: [CGRect], visibleFrameUnderTheMouse: CGRect) -> CGRect {
    if let savedFrame, savedFrame.width > 0, savedFrame.height > 0,
       let visibleFrame = visibleFrames.first(where: { $0.contains(CGPoint(x: savedFrame.midX, y: savedFrame.midY)) }) {
        let width = roomArtPanelWidthAllowed(savedFrame.width, in: visibleFrame)
        let size = CGSize(width: width, height: width / roomArtPanelAspectRatio)
        return CGRect(origin: roomArtPanelOriginKeptInside(visibleFrame, origin: savedFrame.origin, size: size), size: size)
    }
    let width = roomArtPanelWidthAllowed(roomArtPanelDefaultSize.width, in: visibleFrameUnderTheMouse)
    let size = CGSize(width: width, height: width / roomArtPanelAspectRatio)
    return CGRect(
        x: visibleFrameUnderTheMouse.midX - size.width / 2, y: visibleFrameUnderTheMouse.midY - size.height / 2,
        width: size.width, height: size.height
    )
}

/// The frame while the learner drags the corner grip, which sits at the bottom right: the top left stays where it was, the
/// size follows whichever way the pointer moved further at 16:9, and it never passes the screen's visible frame or drops
/// under the smallest size. `pointerMovedBy` is in screen points, y up, so a drag down is negative.
nonisolated func roomArtPanelResizedFrame(startFrame: CGRect, pointerMovedBy: CGSize, visibleFrame: CGRect) -> CGRect {
    // Each way the pointer moved, as a change of width: right and down grow the panel.
    let widthChangeFromTheSideways = pointerMovedBy.width
    let widthChangeFromTheDownward = -pointerMovedBy.height * roomArtPanelAspectRatio
    let widthChange = abs(widthChangeFromTheSideways) >= abs(widthChangeFromTheDownward) ? widthChangeFromTheSideways : widthChangeFromTheDownward
    let room = CGSize(width: visibleFrame.maxX - startFrame.minX, height: startFrame.maxY - visibleFrame.minY)
    let widestAllowed = max(roomArtPanelSmallestSize.width, min(room.width, room.height * roomArtPanelAspectRatio))
    let width = min(max(startFrame.width + widthChange, roomArtPanelSmallestSize.width), widestAllowed)
    let height = width / roomArtPanelAspectRatio
    return CGRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height)
}

/// A width between the smallest and the widest the visible frame holds at 16:9.
private nonisolated func roomArtPanelWidthAllowed(_ width: CGFloat, in visibleFrame: CGRect) -> CGFloat {
    let widest = max(roomArtPanelSmallestSize.width, min(visibleFrame.width, visibleFrame.height * roomArtPanelAspectRatio))
    return min(max(width, roomArtPanelSmallestSize.width), widest)
}

/// The origin moved just enough that a panel of `size` lies inside the visible frame.
private nonisolated func roomArtPanelOriginKeptInside(_ visibleFrame: CGRect, origin: CGPoint, size: CGSize) -> CGPoint {
    CGPoint(
        x: min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width)),
        y: min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
    )
}
