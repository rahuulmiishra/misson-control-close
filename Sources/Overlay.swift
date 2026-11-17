// Overlay.swift — the transparent panel that draws ✕ buttons over Mission Control.
//
// The panel never receives mouse events (ignoresMouseEvents = true); all input
// comes from the event tap. Mission Control aggressively owns the event stream
// while it is up, so competing with it for clicks is a losing game — we let it
// have the events and intercept the ones over our buttons before they arrive.

import AppKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    private var panel: OverlayPanel?
    private let view = OverlayView()

    /// Mission Control's own surfaces sit at CGWindowLevel 18–20, so anything
    /// above that wins. Overridable at runtime because this is the part most
    /// likely to need tuning on a future macOS.
    static var windowLevel: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "OverlayWindowLevel")
            return stored != 0 ? stored : Int(CGShieldingWindowLevel())
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "OverlayWindowLevel")
        }
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: Coords.screensUnion,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: OverlayController.windowLevel)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        return panel
    }

    func show(previews: [WindowPreview], closedTiles: [ClosedTile] = []) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Displays can change between invocations.
        panel.setFrame(Coords.screensUnion, display: false)
        panel.level = NSWindow.Level(rawValue: OverlayController.windowLevel)

        view.panelOrigin = panel.frame.origin
        view.previews = previews
        view.closedTiles = closedTiles
        view.needsDisplay = true

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        view.previews = []
        view.closedTiles = []
        view.hoveredIndex = nil
        panel?.orderOut(nil)
    }

    func setHovered(_ index: Int?) {
        guard view.hoveredIndex != index else { return }
        view.hoveredIndex = index
        view.needsDisplay = true
    }

    /// Drop a preview the moment it is clicked, so the button disappears
    /// immediately instead of lingering until the next poll.
    func removePreview(at index: Int) {
        guard view.previews.indices.contains(index) else { return }
        view.previews.remove(at: index)
        view.hoveredIndex = nil
        view.needsDisplay = true
    }

    /// Drop every preview owned by a process whose windows are all going away.
    func removePreviews(pid: pid_t) {
        view.previews.removeAll { $0.pid == pid }
        view.hoveredIndex = nil
        view.needsDisplay = true
    }

    var previews: [WindowPreview] { view.previews }
}

/// A tile whose window is gone. Mission Control never reclaims the space, so we
/// paint over the empty slot to make it read as "closed" instead of "broken".
struct ClosedTile {
    let axRect: CGRect
    let label: String
    let pid: pid_t
    let closedAt: Date
}

final class OverlayView: NSView {
    var previews: [WindowPreview] = []
    var closedTiles: [ClosedTile] = []
    var hoveredIndex: Int?
    var panelOrigin: CGPoint = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        for tile in closedTiles {
            drawClosedTile(tile, context: ctx)
        }

        for (index, preview) in previews.enumerated() {
            let hovered = (index == hoveredIndex)
            let rect = viewRect(for: preview)
            drawCloseButton(in: rect, hovered: hovered, context: ctx)
        }
    }

    /// AX coords (top-left origin, global) → Cocoa coords → this view's coords.
    private func viewRect(for preview: WindowPreview) -> CGRect {
        let cocoa = Coords.axToCocoa(preview.closeButtonAXRect)
        return cocoa.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
    }

    private func drawClosedTile(_ tile: ClosedTile, context ctx: CGContext) {
        let cocoa = Coords.axToCocoa(tile.axRect)
        let rect = cocoa.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y).insetBy(dx: -3, dy: -3)
        guard rect.width > 8, rect.height > 8 else { return }

        ctx.saveGState()

        // Opaque enough to hide the dead snapshot and Mission Control's selection ring.
        let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 0.94).cgColor)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let text = tile.label as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let size = text.size(withAttributes: attributes)
        if size.width < rect.width - 16 {
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                      withAttributes: attributes)
        }

        ctx.restoreGState()
    }

    private func drawCloseButton(in rect: CGRect, hovered: Bool, context ctx: CGContext) {
        let body = hovered ? rect.insetBy(dx: -1.5, dy: -1.5) : rect

        ctx.saveGState()

        // Drop shadow keeps the button readable over light window content.
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)

        let fill = hovered
            ? NSColor(srgbRed: 1.0, green: 0.31, blue: 0.29, alpha: 1.0)   // macOS close-button red
            : NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 0.88)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: body)

        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(hovered ? 0.9 : 0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: body.insetBy(dx: 0.5, dy: 0.5))

        // The ✕ glyph.
        let arm = body.width * 0.26
        let center = CGPoint(x: body.midX, y: body.midY)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(hovered ? 1.0 : 0.85).cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
        ctx.addLine(to: CGPoint(x: center.x + arm, y: center.y + arm))
        ctx.move(to: CGPoint(x: center.x - arm, y: center.y + arm))
        ctx.addLine(to: CGPoint(x: center.x + arm, y: center.y - arm))
        ctx.strokePath()

        ctx.restoreGState()
    }
}
