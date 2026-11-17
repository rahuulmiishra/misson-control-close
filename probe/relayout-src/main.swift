// relayout.swift — does Mission Control reflow its tiles when a window goes away?
//
// Compares two ways of getting rid of a window while Mission Control is open:
//   1. NSRunningApplication.terminate()          (what the ✕ does today)
//   2. pressing the window's AX close button     (what ⌥-click does)
// and reports whether the tile disappears and whether the others move.

import AppKit
import ApplicationServices

func tiles() -> [(title: String, rect: CGRect)] {
    guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
    let dock = AXUIElementCreateApplication(dockApp.processIdentifier)
    guard let mc = AX.child(of: dock, identifier: "mc") else { return [] }
    return AX.descendants(of: mc, identifier: "mc.windows")
        .flatMap { AX.children($0) }
        .filter { AX.role($0) == kAXButtonRole as String }
        .compactMap { el in
            guard let r = AX.frame(el) else { return nil }
            return (AX.title(el) ?? "", r)
        }
}

func report(_ label: String, _ list: [(title: String, rect: CGRect)]) {
    print("\n--- \(label): \(list.count) tiles")
    for t in list {
        print(String(format: "    (%.0f,%.0f %.0fx%.0f)  %@", t.rect.minX, t.rect.minY, t.rect.width, t.rect.height, t.title))
    }
}

func openMissionControl() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Mission Control"]
    try? p.run(); p.waitUntilExit()
    Thread.sleep(forTimeInterval: 1.5)
}

func closeMissionControl() {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 1.2)
}

guard AXIsProcessTrusted() else { print("✗ not trusted"); exit(1) }

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "terminate"

// Disposable subject: a TextEdit window on a temp file, so nothing real is at risk.
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcc-relayout-probe.txt")
try? "probe subject window".write(to: tmp, atomically: true, encoding: .utf8)
let openIt = Process()
openIt.executableURL = URL(fileURLWithPath: "/usr/bin/open")
openIt.arguments = ["-a", "TextEdit", tmp.path]
try? openIt.run(); openIt.waitUntilExit()
Thread.sleep(forTimeInterval: 2.0)

guard let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
    print("✗ TextEdit did not start"); exit(1)
}
print("✓ TextEdit pid \(textEdit.processIdentifier), mode = \(mode)")

openMissionControl()
let before = tiles()
report("BEFORE", before)

guard before.contains(where: { $0.title.contains("mcc-relayout-probe") }) else {
    print("✗ probe window not visible in Mission Control; aborting")
    closeMissionControl()
    exit(1)
}

print("\n>>> removing the window via: \(mode)")
switch mode {
case "close":
    // Press the AX close button on the window itself.
    let app = AXUIElementCreateApplication(textEdit.processIdentifier)
    for w in AX.children(app) where AX.title(w)?.contains("mcc-relayout-probe") == true {
        if let btn = AX.value(w, kAXCloseButtonAttribute as String) {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }
default:
    textEdit.terminate()
}

for delay in [0.4, 1.0, 2.5] {
    Thread.sleep(forTimeInterval: delay)
    report("AFTER +\(delay)s", tiles())
}

print("\n>>> TextEdit still running: \(!textEdit.isTerminated)")
closeMissionControl()
textEdit.forceTerminate()
try? FileManager.default.removeItem(at: tmp)
print("Done.")
