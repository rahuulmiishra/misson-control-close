// MissionControl.swift — reads Mission Control's live layout out of its host process.
//
// Mission Control is private UI with no public API, and Apple has moved it:
//
//   macOS 26 and earlier — owned by the Dock:
//     Dock → mc → mc.display (one per screen) → mc.windows → AXButton per preview
//   macOS 27 — owned by WindowManager:
//     WindowManager → mc.display (one per screen) → AXButton per preview
//                                                 + mc.spaces (Spaces bar, skipped)
//     Each preview's AXIdentifier is "<bundle id>.space.<n>".
//
// Both layouts are checked, so the same build works on either OS.
//
// Each preview button gives us a title and a frame, but no window ID: the
// private _AXUIElementGetWindow returns the host's own backing window for all
// of them. We don't need it. While Mission Control is up the WindowServer moves
// the real windows to the preview positions, so a preview's frame matches its
// real window's bounds exactly — that's our join key, and it yields the PID.

import AppKit
import ApplicationServices

struct WindowPreview {
    let axRect: CGRect        // preview position, AX coords (top-left origin)
    let title: String
    let pid: pid_t
    let windowID: CGWindowID
    let appName: String

    /// Where the ✕ is drawn: the preview's top-left corner, macOS convention.
    var closeButtonAXRect: CGRect {
        let side = Style.buttonSize
        let center = CGPoint(x: axRect.minX + Style.buttonInset, y: axRect.minY + Style.buttonInset)
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Slightly forgiving target so a near-miss still closes.
    var hitAXRect: CGRect { closeButtonAXRect.insetBy(dx: -4, dy: -4) }
}

enum Style {
    static let buttonSize: CGFloat = 22
    static let buttonInset: CGFloat = 9
}

final class MissionControlScanner {
    /// Processes that can host Mission Control, newest layout first.
    private static let hostBundleIDs = ["com.apple.WindowManager", "com.apple.dock"]

    private var hosts: [String: (pid: pid_t, element: AXUIElement)] = [:]

    /// The host's AX application element. Both processes restart often enough
    /// (the Dock especially) that the PID is re-checked on every call.
    private func host(_ bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            hosts[bundleID] = nil
            return nil
        }
        if let cached = hosts[bundleID], cached.pid == app.processIdentifier { return cached.element }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        hosts[bundleID] = (app.processIdentifier, element)
        return element
    }

    /// PIDs of the host processes, so their own surfaces never count as windows.
    private var hostPIDs: Set<pid_t> { Set(hosts.values.map(\.pid)) }

    /// Preview buttons from whichever layout is present right now, or nil when
    /// Mission Control is closed. Costs one or two attribute fetches when closed.
    private func previewButtons() -> [AXUIElement]? {
        // macOS 27: WindowManager → mc.display → AXButton
        if let wm = host("com.apple.WindowManager") {
            let displays = AX.children(wm).filter { AX.identifier($0) == "mc.display" }
            if !displays.isEmpty {
                return displays.flatMap { AX.children($0) }
                    .filter { AX.role($0) == kAXButtonRole as String }
            }
        }
        // macOS 26 and earlier: Dock → mc → mc.display → mc.windows → AXButton
        if let dock = host("com.apple.dock"), let mc = AX.child(of: dock, identifier: "mc") {
            return AX.descendants(of: mc, identifier: "mc.windows")
                .flatMap { AX.children($0) }
                .filter { AX.role($0) == kAXButtonRole as String }
        }
        return nil
    }

    /// Cheap check used by the idle poll — no deep tree walk.
    func isMissionControlActive() -> Bool {
        if let wm = host("com.apple.WindowManager"),
           AX.children(wm).contains(where: { AX.identifier($0) == "mc.display" }) { return true }
        if let dock = host("com.apple.dock"), AX.child(of: dock, identifier: "mc") != nil { return true }
        return false
    }

    /// Frame of every preview tile Mission Control showed at the last scan,
    /// whether or not its window was matched. A closed window's slot is only
    /// worth covering while a tile still sits there: macOS 27 removes the tile
    /// and rearranges the rest within ~200 ms of the window dying.
    private(set) var lastTileFrames: [CGRect] = []

    /// Every window preview currently on screen, matched to its owning process.
    func scan() -> [WindowPreview] {
        lastTileFrames = []
        guard let previewButtons = previewButtons(), !previewButtons.isEmpty else { return [] }
        lastTileFrames = previewButtons.compactMap { AX.frame($0) }

        var candidates = realWindows()
        var results: [WindowPreview] = []

        for button in previewButtons {
            guard let rect = AX.frame(button), rect.width > 1, rect.height > 1 else { continue }
            let title = AX.title(button) ?? ""

            guard let index = matchIndex(for: rect, title: title, in: candidates) else { continue }
            let win = candidates.remove(at: index)   // one real window per preview

            results.append(WindowPreview(axRect: rect,
                                         title: title.isEmpty ? win.appName : title,
                                         pid: win.pid,
                                         windowID: win.id,
                                         appName: win.appName))
        }
        return results
    }

    // MARK: - Matching

    private struct RealWindow {
        let id: CGWindowID
        let pid: pid_t
        let rect: CGRect
        let appName: String
        let title: String
    }

    private func matchIndex(for rect: CGRect, title: String, in windows: [RealWindow]) -> Int? {
        // Primary: exact geometry. Tolerance absorbs sub-pixel scaling.
        if let i = windows.firstIndex(where: { close($0.rect, rect) }) { return i }
        // Fallback for the brief window where a preview is still animating and
        // its frame hasn't converged on the real window's bounds yet.
        if !title.isEmpty, let i = windows.firstIndex(where: { $0.title == title }) { return i }
        return nil
    }

    private func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func realWindows() -> [RealWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        return list.compactMap { entry in
            // Normal application windows only: layer 0 and below excludes Mission
            // Control's own surfaces, the menu bar and Control Centre. Some apps
            // (Claude on macOS 27) sit at layer -1 and still get a preview.
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer <= 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  !hostPIDs.contains(pid),
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) else { return nil }

            return RealWindow(id: id,
                              pid: pid,
                              rect: rect,
                              appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                              title: entry[kCGWindowName as String] as? String ?? "")
        }
    }
}

// MARK: - Actions

enum WindowAction {
    /// Apps macOS won't let stay dead. Killing them is worse than useless: the
    /// relaunched process restores the very windows the user was trying to get
    /// rid of. Finder is the canonical case — Apple's own Force Quit dialog
    /// labels its button "Relaunch".
    private static let autoRelaunchBundleIDs: Set<String> = ["com.apple.finder"]

    static func isAutoRelaunched(pid: pid_t) -> Bool {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return autoRelaunchBundleIDs.contains(bundleID)
    }

    /// Kill the whole application, no questions asked. The entire process dies —
    /// every window it owns (all Chrome profiles, every document), background
    /// mode or not. forceTerminate() skips unsaved-changes dialogs and quit
    /// handlers entirely; SIGKILL is the backstop nothing can ignore.
    static func quitApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            NSLog("MissionControlCloser: \(app.localizedName ?? "pid \(pid)") survived force terminate — SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    /// Close every window the app currently has, via each window's own close
    /// button, leaving the process running. This is the "kill" gesture for
    /// auto-relaunched apps: a window dismissed by its close button is removed
    /// from the app's restorable state, so unlike a kill-and-relaunch cycle,
    /// nothing comes back. Windows with no close button (Finder's desktop) are
    /// skipped.
    static func closeAllWindows(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        for window in AX.children(app) where AX.role(window) == kAXWindowRole as String {
            if let button = AX.value(window, kAXCloseButtonAttribute as String) {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }

    /// Close just this one window, leaving the app running.
    /// Finds the AXWindow whose window ID matches, then presses its close button.
    /// `fallbackAXRect` is the preview's frame — while Mission Control is up the
    /// real window sits at that exact position, so it identifies the window when
    /// the private window-ID symbol is unavailable. Never quits the app.
    static func closeWindow(pid: pid_t, windowID: CGWindowID, fallbackAXRect: CGRect? = nil) {
        let app = AXUIElementCreateApplication(pid)
        for window in AX.children(app) {
            if let getWindowID = PrivateAX.getWindowID {
                var id: CGWindowID = 0
                guard getWindowID(window, &id) == .success, id == windowID else { continue }
            } else {
                guard let rect = fallbackAXRect, let frame = AX.frame(window),
                      abs(frame.minX - rect.minX) <= 2, abs(frame.minY - rect.minY) <= 2 else { continue }
            }
            if let button = AX.value(window, kAXCloseButtonAttribute as String) {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
            return
        }
        NSLog("MissionControlCloser: could not find window \(windowID) of pid \(pid) to close")
    }
}

enum PrivateAX {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Undocumented but long-stable: maps an AXUIElement to its CGWindowID.
    static let getWindowID: GetWindowFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()
}
