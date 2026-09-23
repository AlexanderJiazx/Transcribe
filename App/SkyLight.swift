//
//  SkyLight.swift
//  AlexTranscribeApp
//
//  Created by Alexander Jia on 2026-06-06.
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
    static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    // Private SPIs can vanish in a new macOS release — resolve each once and
    // degrade to normal window behavior instead of crashing at launch.
    static let available: Bool = {
        guard handle != nil,
              sym("SLSMainConnectionID", MainConnectionID.self) != nil,
              sym("SLSSpaceCreate", SpaceCreate.self) != nil,
              sym("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self) != nil,
              sym("SLSShowSpaces", ShowSpaces.self) != nil,
              sym("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindowsAndRemoveFromSpaces.self) != nil
        else { return false }
        return true
    }()
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

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private let ready: Bool

    private init() {
        guard SLS.available,
              let conn = SLS.mainConnectionID,
              let create = SLS.spaceCreate,
              let setLevel = SLS.spaceSetAbsoluteLevel,
              let show = SLS.showSpaces else {
            print("[skylight] private symbols unavailable — overlay space disabled")
            ready = false
            return
        }
        let c = conn()
        connection = c
        let s = create(c, 1, 0)
        space = s
        _ = setLevel(c, s, Self.level)
        _ = show(c, [s] as CFArray)
        ready = true
    }

    /// Moves `window` into the fixed overlay space. Must be called after the
    /// window is on screen (windowNumber > 0). The trailing `7` is the
    /// all-Spaces selector: remove the window from the user Spaces it was in.
    func adopt(_ window: NSWindow) {
        guard ready, window.windowNumber > 0,
              let add = SLS.addWindowsAndRemoveFromSpaces else { return }
        _ = add(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
