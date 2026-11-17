// InputTap.swift — CGEventTap for clicks and hover while Mission Control is up.
//
// Only runs while Mission Control is on screen. Clicks that land on one of our
// buttons are swallowed so Mission Control never sees them (otherwise it would
// switch to the window we are trying to close). Everything else passes through
// untouched.

import AppKit
import CoreGraphics

final class InputTap {
    /// Return true to swallow the click.
    var onMouseDown: ((CGPoint, CGEventFlags) -> Bool)?
    var onMouseMoved: ((CGPoint) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowNextMouseUp = false

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask),
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("MissionControlCloser: failed to create event tap (Accessibility permission missing?)")
            return
        }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CFMachPortInvalidate(port)
        runLoopSource = nil
        tap = nil
        swallowNextMouseUp = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved:
            onMouseMoved?(event.location)

        case .leftMouseDown:
            if onMouseDown?(event.location, event.flags) == true {
                swallowNextMouseUp = true
                return nil
            }

        case .leftMouseUp:
            // Swallow the paired up-event too, or Mission Control acts on it.
            if swallowNextMouseUp {
                swallowNextMouseUp = false
                return nil
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}
