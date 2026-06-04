//
//  AppDelegate.swift
//  AlexTranscribeApp
//
//  Created by Alexander Jia on 2026-06-04.
//

import AppKit

// MARK: - Private SkyLight (SLS) space delegation
//
// A window only slides during a Space switch because it belongs to a *user*
// Space that the WindowServer animates. The fix is to take it out of every user
// Space: we create one dedicated SkyLight space at a high absolute level, keep it
// permanently shown, and move the window into it. User Spaces then slide
// underneath while this window stays fixed — the same mechanism the lock screen
// and Notification Center use.
//
// (Window tags like the old "sticky" 0x800 bit only mean "appears on all Spaces"
// — identical to .canJoinAllSpaces — and do nothing to stop the slide.)
//
// SkyLight is the modern successor to CoreGraphics Services. These are private
// SPIs: no sandbox entitlement is required, but they are not guaranteed stable
// across major macOS releases.
private enum SLS {
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    static func sym<T>(_ name: String, _ type: T.Type) -> T {
        unsafeBitCast(dlsym(handle, name), to: type)
    }

    static let mainConnectionID = sym("SLSMainConnectionID", MainConnectionID.self)
    static let spaceCreate = sym("SLSSpaceCreate", SpaceCreate.self)
    static let spaceSetAbsoluteLevel = sym("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self)
    static let showSpaces = sym("SLSShowSpaces", ShowSpaces.self)
    static let addWindowsAndRemoveFromSpaces = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindowsAndRemoveFromSpaces.self)
}

/// A dedicated, always-shown SkyLight space that floats above the user's Spaces.
/// Windows moved into it stay fixed on screen during Space-switch animations.
final class FixedOverlaySpace {
    static let shared = FixedOverlaySpace()

    // Absolute level of the overlay space (higher = covers more system UI):
    //   0 default · 100 setup assistant · 200 security agent · 300 screen lock
    //   400 notif-center-on-lock · 500 boot progress · 600 VoiceOver
    // 300 floats above user Spaces and the menu bar. Lower it to keep the overlay
    // off the lock screen; raise to 400 to show it even when the screen is locked.
    private static let level: Int32 = 300

    private let connection: Int32
    private let space: Int32

    private init() {
        connection = SLS.mainConnectionID()
        space = SLS.spaceCreate(connection, 1, 0)
        _ = SLS.spaceSetAbsoluteLevel(connection, space, Self.level)
        _ = SLS.showSpaces(connection, [space] as CFArray)
    }

    /// Moves `window` into the fixed overlay space. Must be called after the
    /// window is on screen (windowNumber > 0). The trailing `7` is the
    /// all-Spaces selector: remove the window from the user Spaces it was in.
    func adopt(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        _ = SLS.addWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        
        let screen = NSScreen.main!
        let fullFrame = screen.frame
        let width = fullFrame.width
        let height = fullFrame.height
        
        let RectangleWidth: CGFloat = 184
        let windowHeight:CGFloat = RectangleWidth
        
        //32 is the height of the fringe
        window = NSPanel(
            contentRect: NSRect(x: (width-RectangleWidth)/2, y: height-windowHeight, width: RectangleWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.level = .screenSaver
        window.hasShadow = true

        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none
        (window as? NSPanel)?.becomesKeyOnlyIfNeeded = true

        // Move the panel into a dedicated, always-shown SkyLight space so it
        // stays fixed (does not slide) during Space-switch animations. Must run
        // after makeKeyAndOrderFront, when windowNumber > 0.
        FixedOverlaySpace.shared.adopt(window)
        window.orderFrontRegardless()

        let contentView = window.contentView!
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.layer?.cornerRadius = 10
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true

    }
}

/*
class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
 */


extension NSPanel{
    open override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
