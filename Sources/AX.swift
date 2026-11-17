// AX.swift — thin, crash-safe wrappers over the Accessibility C API.

import AppKit
import ApplicationServices

enum AX {
    static func value(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        value(el, attribute) as? String
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func identifier(_ el: AXUIElement) -> String? {
        string(el, kAXIdentifierAttribute as String)
    }

    static func role(_ el: AXUIElement) -> String? {
        string(el, kAXRoleAttribute as String)
    }

    static func title(_ el: AXUIElement) -> String? {
        string(el, kAXTitleAttribute as String)
    }

    /// Global frame in AX coordinates: origin top-left of the primary display, Y increasing downward.
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posValue = value(el, kAXPositionAttribute as String),
              let sizeValue = value(el, kAXSizeAttribute as String),
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// First direct child carrying the given AXIdentifier.
    static func child(of el: AXUIElement, identifier wanted: String) -> AXUIElement? {
        children(el).first { identifier($0) == wanted }
    }

    /// All descendants carrying the given AXIdentifier, breadth-first.
    static func descendants(of el: AXUIElement, identifier wanted: String, maxDepth: Int = 6) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var frontier = [(el, 0)]
        while let (node, depth) = frontier.first {
            frontier.removeFirst()
            if identifier(node) == wanted { found.append(node) }
            if depth < maxDepth {
                frontier.append(contentsOf: children(node).map { ($0, depth + 1) })
            }
        }
        return found
    }
}

// MARK: - Coordinate conversion

enum Coords {
    /// Cocoa's global origin is the bottom-left of the primary screen; AX's is the top-left.
    /// Flipping needs the primary screen's height, not the focused screen's.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func axToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Union of every attached display, in Cocoa coordinates.
    static var screensUnion: CGRect {
        guard let first = NSScreen.screens.first else { return .zero }
        return NSScreen.screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }
}
