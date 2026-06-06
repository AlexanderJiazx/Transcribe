//
//  AppDelegate.swift
//  AlexTranscribeApp
//
//  Created by Alexander Jia on 2026-06-04.
//

import AppKit



enum WindowState {
    case expanded
    case hidden
}

struct ScreenInfo{
    var width: CGFloat
    var height: CGFloat
    var fringeWidth: CGFloat
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var windowState: WindowState = .hidden
    
    //screen info
    var screenInfo: ScreenInfo = ScreenInfo(width: 0,
                                           height: 0,
                                           fringeWidth: 0)
    
    private func initScreeninfo(){
        let screen = NSScreen.main!
        let fullFrame = screen.frame
        
        screenInfo = ScreenInfo(width: fullFrame.width,
                                height: fullFrame.height,
                                fringeWidth: 184)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        
        initScreeninfo()
        
        //32 is the height of the fringe
        window = NSPanel(
            contentRect: NSRect(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height, width: screenInfo.fringeWidth, height: screenInfo.fringeWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        windowState = .hidden

        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.level = .screenSaver
        window.hasShadow = false

        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none
        (window as? NSPanel)?.becomesKeyOnlyIfNeeded = true

        // Move the panel into a dedicated, always-shown SkyLight space so it
        // stays fixed (does not slide) during Space-switch animations. Must run
        // after makeKeyAndOrderFront, when windowNumber > 0.
        FixedOverlaySpace.shared.adopt(window)
        window.orderFrontRegardless()

        keyPressInterception()
        /*
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
              guard let self else { return }
              self.moveWindow(to: NSPoint(x: (width-RectangleWidth)/2, y: height-windowHeight))
          }
         */

        let contentView = window.contentView!
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.layer?.cornerRadius = 10
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true

    }

    private func switchWindowState(){
        switch windowState {
            case .hidden:
            moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height - screenInfo.fringeWidth))
            windowState = .expanded
                return
            case .expanded:
            moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height))
            windowState = .hidden
                return
            }
    }
    
    private func switchWindowState(to target: WindowState){
        switch target {
            case .hidden:
                moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height))
                windowState = .hidden
            case .expanded:
                moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height - screenInfo.fringeWidth))
                windowState = .expanded
            }
    }
    //Written by Claude, I don't know how it works
    private func keyPressInterception() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        print("[tap] Accessibility trusted: \(trusted)")
        guard trusted else {
            print("[tap] Grant Accessibility permission then restart the app")
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Mask covers keyDown + systemDefined (media keys sent by F-keys on MacBooks)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
                   CGEventMask(1 << 14) // 14 = systemDefined (media/function keys)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                print("[tap] event type: \(type.rawValue)  keyCode: \(keyCode)")
                guard keyCode == 176 else {
                    return Unmanaged.passRetained(event)
                }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.switchWindowState()
                }
                return nil
            },
            userInfo: selfPtr
        ) else {
            print("[tap] CGEvent.tapCreate failed")
            return
        }

        print("[tap] tap created successfully")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    
    
    private func moveWindow(to origin: NSPoint) {
          let newFrame = NSRect(origin: origin, size: window.frame.size)
          NSAnimationContext.runAnimationGroup { context in
              context.duration = 0.4
              context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
              window.animator().setFrame(newFrame, display: true)
          }
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
