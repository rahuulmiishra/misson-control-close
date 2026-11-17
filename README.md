# Mission Control Closer

Adds a ✕ button to every window preview in Mission Control. Click it to kill
that app without leaving the three-finger-swipe view.

- **Click ✕** — force-kills the whole process, immediately and unconditionally.
  Every window the app owns dies with it — all Chrome profiles, every document —
  and unsaved-changes dialogs are skipped, so unsaved work is lost. A SIGKILL
  backstop lands 2 s later if anything survives; the Dock dot always goes away.
- **⌥-click ✕** — closes just that one window, leaving the app (and its other
  windows) running
- **Finder is the exception.** macOS auto-relaunches Finder after any kill, and
  the relaunched Finder restores every window that was open — so killing it
  would bring the windows straight back. Clicking ✕ on a Finder tile instead
  closes all of Finder's windows in the current Space through their real close
  buttons (closed windows are never restored); Finder itself stays running, as
  macOS requires.
- Menu bar icon for enable/disable and Launch at Login
- macOS 13+, universal (Apple Silicon + Intel)

## Build

```bash
./build.sh          # → build/MissionControlCloser.app
./package.sh        # → build/MissionControlCloser.zip + INSTALL.txt
```

No Xcode project and no dependencies — `swiftc` plus a hand-written bundle.
Command Line Tools are enough.

## How it works

Mission Control is private UI with no public API. Everything here rests on
what its host process exposes through the Accessibility API. macOS 27 moved
Mission Control from the Dock to WindowManager; the app checks both:

```
macOS 27 — WindowManager (AXApplication)
└── AXGroup  id="mc.display"            ← one per screen, present only while Mission Control is open
    ├── AXButton × N                    ← one per preview, id "<bundle id>.space.<n>"
    └── AXGroup  id="mc.spaces"

macOS 26 and earlier — Dock (AXApplication)
└── AXGroup  id="mc"
    └── AXGroup  id="mc.display"
        ├── AXGroup  id="mc.windows"
        │   └── AXButton × N
        └── AXGroup  id="mc.spaces"
```

A preview carries no window ID — the private `_AXUIElementGetWindow` returns the
host's own backing window for all of them. It doesn't need to. While Mission
Control is open the WindowServer moves the **real** windows to the preview
positions, so a preview's frame matches its window's bounds exactly. That
geometry match is the join key, and it yields the owning PID.

Input goes through a `CGEventTap` rather than the overlay window. Mission
Control owns the event stream while it is up, so the overlay is
`ignoresMouseEvents = true` and clicks landing on a ✕ are swallowed before
Mission Control ever sees them — otherwise it would switch to the window being
closed.

`probe/` holds the discovery tools used to work this out. `probe/probe.swift`
dumps the Dock's Accessibility tree (pass a bundle id as the second
argument, e.g. `com.apple.WindowManager`, to dump another process) before and during Mission Control;
`probe/relayout-src/` tests whether tiles reflow. If a macOS update breaks the
app, re-run the probe — it shows exactly what changed.

## Known limitations

**On macOS 26, closing a window leaves an empty slot.** Mission Control there
lays out its tiles once when it opens and never rearranges them, so the dead
tile is painted over with a "quit" marker; exiting and re-entering Mission
Control gives a clean layout. macOS 27 removes the dead tile and rearranges the
rest within about 200 ms, so the marker is dropped as soon as the tile is gone.

**Undocumented foundations.** The `mc` / `mc.windows` identifiers are Apple's
private UI. A macOS update can rename or restructure them and break the app.
Verified on macOS 26.2 (Dock layout) and macOS 27.2 (WindowManager layout).

**Ad-hoc signature.** Accessibility permission is tied to the code signature, so
rebuilding may require re-granting it in System Settings.

## Sharing it

`./package.sh` produces a zip plus install instructions. Because the app is
ad-hoc signed rather than notarized, whoever installs it has to approve it once
in System Settings ▸ Privacy & Security ("Open Anyway"). To skip that step for
your users, the app needs a Developer ID certificate and notarization, which
requires the Apple Developer Program.
