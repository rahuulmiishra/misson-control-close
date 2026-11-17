// main.swift — entry point. Agent app: no Dock icon, no menu bar of its own.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
