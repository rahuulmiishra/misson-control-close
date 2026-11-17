// AppDelegate.swift — menu bar item, permission handling, and the poll loop.

import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let scanner = MissionControlScanner()
    private let overlay = OverlayController()
    private let tap = InputTap()

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var isActive = false          // Mission Control currently on screen
    private var isEnabled = true
    private var closedTiles: [ClosedTile] = []   // slots Mission Control won't reclaim

    // Last observed state, for the Diagnostics panel. Sampled during ticks
    // because none of it can be read meaningfully while a menu is open.
    private var lastMissionControlActive = false
    private var lastPreviewCount = 0
    private var lastTapRunning = false
    private var sawTrusted = false

    // Poll fast enough to track the layout while Mission Control is open,
    // slowly enough to be invisible on the CPU while it isn't.
    private let idleInterval: TimeInterval = 0.25
    private let activeInterval: TimeInterval = 0.1

    /// How long to let an app take over quitting before assuming it refused.
    private static let quitGracePeriod: TimeInterval = 4.0

    /// Preview frames drift by sub-pixel amounts, so never compare them exactly.
    private static func roughlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        wireInput()
        requestAccessibilityIfNeeded()
        schedule(interval: idleInterval)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        overlay.hide()
    }

    // MARK: - Permission

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("MissionControlCloser: waiting for Accessibility permission")
        }
    }

    // MARK: - Poll loop

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let trusted = AXIsProcessTrusted()
        if trusted != sawTrusted {
            sawTrusted = trusted
            NSLog("MissionControlCloser: accessibility trusted = \(trusted)")
            updateStatusIcon(trusted: trusted)
        }

        guard isEnabled, trusted else {
            if isActive { deactivate() }
            return
        }

        let nowActive = scanner.isMissionControlActive()

        if nowActive && !isActive {
            isActive = true
            tap.start()
            schedule(interval: activeInterval)
        } else if !nowActive && isActive {
            deactivate()
            return
        }

        guard isActive else { return }

        let previews = scanner.scan()
        lastMissionControlActive = true
        lastPreviewCount = previews.count
        lastTapRunning = tap.isRunning

        // terminate() is asynchronous — the window survives for a few hundred
        // milliseconds after the click. Only after a grace period does a live
        // window in that slot actually mean the app refused to quit (an unsaved
        // -changes sheet, say), which is when the veil should come back off.
        //
        // On macOS 27 Mission Control removes a dead window's tile and slides
        // the others into its place, so a cover left at the old position lands
        // on top of live tiles. Drop the cover as soon as no tile occupies its
        // slot any more. (macOS 26 keeps the empty slot, so the cover stays.)
        let now = Date()
        let tileFrames = scanner.lastTileFrames
        let stillDead = closedTiles.filter { tile in
            guard tileFrames.contains(where: { Self.roughlyEqual($0, tile.axRect) }) else { return false }
            guard now.timeIntervalSince(tile.closedAt) > Self.quitGracePeriod else { return true }
            let refused = previews.contains { preview in
                preview.pid == tile.pid && Self.roughlyEqual(preview.axRect, tile.axRect)
            }
            if refused { NSLog("MissionControlCloser: \(tile.label) — app did not quit, lifting veil") }
            return !refused
        }
        if stillDead.count != closedTiles.count {
            NSLog("MissionControlCloser: covering \(stillDead.count) closed tile(s)")
        }
        closedTiles = stillDead

        // A veiled tile's window can survive for a few hundred milliseconds
        // (kills and close-button presses are both asynchronous), so the scan
        // briefly re-finds it. Don't put a ✕ button back on top of the veil.
        let visible = previews.filter { preview in
            !stillDead.contains { tile in
                tile.pid == preview.pid && Self.roughlyEqual(preview.axRect, tile.axRect)
            }
        }

        if visible.isEmpty && stillDead.isEmpty {
            overlay.hide()
        } else {
            overlay.show(previews: visible, closedTiles: stillDead)
        }
    }

    private func deactivate() {
        isActive = false
        closedTiles = []
        lastMissionControlActive = false
        tap.stop()
        overlay.hide()
        schedule(interval: idleInterval)
    }

    // MARK: - Input

    private func wireInput() {
        tap.onMouseDown = { [weak self] location, flags in
            guard let self else { return false }
            guard let index = self.indexOfButton(at: location) else { return false }

            let preview = self.overlay.previews[index]

            // Plain click force-kills the whole process — every window it owns,
            // Chrome profiles included. ⌥-click closes just the one window.
            let quitting = !flags.contains(.maskAlternate)
            if quitting {
                // Every window of the process goes away, so veil every tile it
                // owns — not just the one that was clicked.
                let doomed = self.overlay.previews.filter { $0.pid == preview.pid }
                self.overlay.removePreviews(pid: preview.pid)

                let verb: String
                if WindowAction.isAutoRelaunched(pid: preview.pid) {
                    // Killing Finder never sticks: macOS brings it back, and the
                    // relaunched Finder restores every window in its saved state
                    // — that state lags reality, so windows reappear even if
                    // they were closed just before the kill. Close the windows
                    // for real and leave the process alone: a window dismissed
                    // by its own close button leaves the restorable state.
                    WindowAction.closeAllWindows(pid: preview.pid)
                    verb = "windows closed"
                } else {
                    WindowAction.quitApp(pid: preview.pid)
                    verb = "killed"
                }

                let now = Date()
                for p in doomed {
                    self.closedTiles.append(ClosedTile(axRect: p.axRect,
                                                       label: "\(p.appName) \(verb)",
                                                       pid: p.pid,
                                                       closedAt: now))
                }
                NSLog("MissionControlCloser: \(verb) \(preview.appName) (pid \(preview.pid), \(doomed.count) tile(s))")
            } else {
                self.overlay.removePreview(at: index)
                WindowAction.closeWindow(pid: preview.pid,
                                         windowID: preview.windowID,
                                         fallbackAXRect: preview.axRect)
                self.closedTiles.append(ClosedTile(axRect: preview.axRect,
                                                   label: "\(preview.appName) closed",
                                                   pid: preview.pid,
                                                   closedAt: Date()))
                NSLog("MissionControlCloser: closed \(preview.appName) (pid \(preview.pid))")
            }
            return true   // swallow, so Mission Control doesn't switch to it
        }

        tap.onMouseMoved = { [weak self] location in
            guard let self else { return }
            self.overlay.setHovered(self.indexOfButton(at: location))
        }
    }

    /// Event-tap locations are already in AX coordinates, so no conversion here.
    private func indexOfButton(at point: CGPoint) -> Int? {
        overlay.previews.firstIndex { $0.hitAXRect.contains(point) }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Mission Control Closer")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)

        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Click ✕ to force-kill an app · ⌥-click to close one window", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let finderHint = NSMenuItem(title: "Finder can't be killed — ✕ closes all its windows instead", action: nil, keyEquivalent: "")
        finderHint.isEnabled = false
        menu.addItem(finderHint)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let diagnostics = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        let accessibility = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)

        // Overlay stacking is the fragile part across macOS releases; expose it
        // rather than requiring a rebuild to test a different level.
        let levelItem = NSMenuItem(title: "Overlay Level", action: nil, keyEquivalent: "")
        let levelMenu = NSMenu()
        for (name, value) in [("Shielding (default)", Int(CGShieldingWindowLevel())),
                              ("Maximum", Int(CGWindowLevelForKey(.maximumWindow))),
                              ("Screen Saver", Int(CGWindowLevelForKey(.screenSaverWindow))),
                              ("Pop-up Menu", Int(CGWindowLevelForKey(.popUpMenuWindow)))] {
            let entry = NSMenuItem(title: "\(name) — \(value)", action: #selector(setOverlayLevel(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = value
            entry.state = (OverlayController.windowLevel == value) ? .on : .off
            levelMenu.addItem(entry)
        }
        levelItem.submenu = levelMenu
        menu.addItem(levelItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mission Control Closer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func updateStatusIcon(trusted: Bool) {
        let name = trusted ? "xmark.circle" : "xmark.circle.badge.questionmark"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Mission Control Closer")
            ?? NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func showDiagnostics() {
        let trusted = AXIsProcessTrusted()
        let bundlePath = Bundle.main.bundlePath

        let alert = NSAlert()
        alert.messageText = trusted ? "Running normally" : "Accessibility permission is missing"
        alert.informativeText = """
        Accessibility trusted:   \(trusted ? "yes" : "NO — nothing can work without this")
        Enabled:                 \(isEnabled ? "yes" : "no")
        Mission Control seen:    \(lastMissionControlActive ? "yes" : "not since launch")
        Previews last matched:   \(lastPreviewCount)
        Closed tiles covered:    \(closedTiles.count)
        Event tap running:       \(lastTapRunning ? "yes" : "no")
        Overlay level:           \(OverlayController.windowLevel)

        Bundle: \(bundlePath)

        If the permission is already ticked but says NO here, macOS is holding a
        stale entry from an earlier build. Remove the app from the Accessibility
        list with the minus button, then add it again.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off
        if !isEnabled { deactivate() }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nThis usually means the app isn't in /Applications yet."
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func setOverlayLevel(_ sender: NSMenuItem) {
        OverlayController.windowLevel = sender.tag
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
