// probe.swift — discovery tool.
// Triggers Mission Control, then dumps everything the Dock process exposes to
// the Accessibility API so we can find the window previews and map them back to
// real windows. This is throwaway reconnaissance, not part of the shipping app.

import Foundation
import ApplicationServices
import AppKit

// MARK: - Private API

// _AXUIElementGetWindow maps an AXUIElement to its CGWindowID. Undocumented but
// stable since ~10.6; it is how we would tie a preview back to a real window.
typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let axGetWindow: GetWindowFn? = {
    guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
          let sym = dlsym(h, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: GetWindowFn.self)
}()

// MARK: - AX helpers

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    attr(el, name) as? String
}

func attrNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func actionNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let pv = attr(el, kAXPositionAttribute as String),
          let sv = attr(el, kAXSizeAttribute as String) else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sv as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

func windowID(_ el: AXUIElement) -> CGWindowID? {
    guard let fn = axGetWindow else { return nil }
    var wid: CGWindowID = 0
    return fn(el, &wid) == .success && wid != 0 ? wid : nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    guard let raw = attr(el, kAXChildrenAttribute as String) else { return [] }
    return (raw as? [AXUIElement]) ?? []
}

// MARK: - Tree dump

var nodeCount = 0

func dump(_ el: AXUIElement, depth: Int, maxDepth: Int, path: String) {
    nodeCount += 1
    let pad = String(repeating: "  ", count: depth)

    let role = str(el, kAXRoleAttribute as String) ?? "?"
    let subrole = str(el, kAXSubroleAttribute as String)
    let title = str(el, kAXTitleAttribute as String)
    let desc = str(el, kAXDescriptionAttribute as String)
    let ident = str(el, kAXIdentifierAttribute as String)
    let help = str(el, kAXHelpAttribute as String)
    let value = attr(el, kAXValueAttribute as String)

    var line = "\(pad)[\(path)] \(role)"
    if let subrole { line += "/\(subrole)" }
    if let title, !title.isEmpty { line += "  title=\"\(title)\"" }
    if let desc, !desc.isEmpty { line += "  desc=\"\(desc)\"" }
    if let ident, !ident.isEmpty { line += "  id=\"\(ident)\"" }
    if let help, !help.isEmpty { line += "  help=\"\(help)\"" }
    if let f = frame(el) {
        line += String(format: "  frame=(%.0f,%.0f %.0fx%.0f)", f.origin.x, f.origin.y, f.size.width, f.size.height)
    }
    if let wid = windowID(el) { line += "  *** CGWindowID=\(wid) ***" }
    if let value, !(value is NSArray) {
        let s = "\(value)".replacingOccurrences(of: "\n", with: " ")
        if s.count < 80 { line += "  value=\(s)" }
    }
    print(line)

    // Full attribute/action inventory on interesting nodes: anything that has a
    // window ID, or sits deep enough to plausibly be a preview.
    if windowID(el) != nil || depth >= 2 {
        let attrs = attrNames(el)
        let unusual = attrs.filter { ![
            "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXIdentifier", "AXHelp",
            "AXValue", "AXPosition", "AXSize", "AXChildren", "AXParent", "AXEnabled",
            "AXFocused", "AXWindow", "AXTopLevelUIElement", "AXSelected", "AXFrame"
        ].contains($0) }
        if !unusual.isEmpty { print("\(pad)    attrs+: \(unusual.joined(separator: ", "))") }
        let acts = actionNames(el)
        if !acts.isEmpty { print("\(pad)    actions: \(acts.joined(separator: ", "))") }
    }

    guard depth < maxDepth else {
        let n = children(el).count
        if n > 0 { print("\(pad)  ...(\(n) children, depth limit)") }
        return
    }
    for (i, child) in children(el).enumerated() {
        dump(child, depth: depth + 1, maxDepth: maxDepth, path: "\(path).\(i)")
    }
}

// MARK: - Reference: the real on-screen window list

func dumpCGWindowList() {
    print("\n================ CGWindowList (on-screen, real windows) ================")
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        print("  (unavailable)")
        return
    }
    for w in list {
        let wid = w[kCGWindowNumber as String] as? Int ?? -1
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
        let name = w[kCGWindowName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        var rect = CGRect.zero
        if let b = w[kCGWindowBounds as String] as? [String: Any] {
            CGRectMakeWithDictionaryRepresentation(b as CFDictionary, &rect)
        }
        print(String(format: "  wid=%-8d layer=%-5d pid=%-7d %-28s \"%@\"  (%.0f,%.0f %.0fx%.0f)",
                     wid, layer, pid, (owner as NSString).utf8String!, name,
                     rect.origin.x, rect.origin.y, rect.width, rect.height))
    }
}

// MARK: - Main

let args = CommandLine.arguments
let maxDepth = args.count > 1 ? (Int(args[1]) ?? 8) : 8

guard AXIsProcessTrusted() else {
    print("""
    ✗ NOT TRUSTED for Accessibility.

    This probe inherits the permission of the terminal that launched it. Grant
    Accessibility to your terminal app in:
      System Settings ▸ Privacy & Security ▸ Accessibility
    then re-run. (Toggle it off/on if it is already checked — the entry goes
    stale after app updates.)
    """)
    exit(1)
}
print("✓ Accessibility trusted")
print("✓ _AXUIElementGetWindow: \(axGetWindow != nil ? "available" : "MISSING")")

guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "com.apple.dock").first else {
    print("✗ Dock not found"); exit(1)
}
let dockPID = dock.processIdentifier
print("✓ Dock pid: \(dockPID)")

// Snapshot the tree BEFORE Mission Control, so we can tell what it adds.
let dockEl = AXUIElementCreateApplication(dockPID)
print("\n================ Dock AX tree — BEFORE Mission Control ================")
dump(dockEl, depth: 0, maxDepth: 2, path: "root")

// Trigger Mission Control and give its animation time to settle.
print("\n>>> Launching Mission Control...")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
task.arguments = ["-a", "Mission Control"]
try? task.run()
task.waitUntilExit()
Thread.sleep(forTimeInterval: 1.5)

nodeCount = 0
print("\n================ Dock AX tree — DURING Mission Control (depth \(maxDepth)) ================")
let dockEl2 = AXUIElementCreateApplication(dockPID)
dump(dockEl2, depth: 0, maxDepth: maxDepth, path: "root")
print("\n(\(nodeCount) nodes)")

dumpCGWindowList()

// Dismiss Mission Control with Escape so the machine is left as we found it.
print("\n>>> Dismissing Mission Control (Escape)...")
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
print("Done.")
