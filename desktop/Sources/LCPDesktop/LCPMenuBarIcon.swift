import AppKit

enum LCPMenuBarIcon {
    // The Dock mark reduced to two leaves, an open spine and a folded corner.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()

            let left = NSBezierPath()
            left.move(to: NSPoint(x: 1, y: 3))
            left.curve(to: NSPoint(x: 8.25, y: 5.75),
                       controlPoint1: NSPoint(x: 3.75, y: 2.8), controlPoint2: NSPoint(x: 6.4, y: 3.85))
            left.line(to: NSPoint(x: 8.25, y: 15.75))
            left.curve(to: NSPoint(x: 1, y: 13.5),
                       controlPoint1: NSPoint(x: 6.25, y: 14.3), controlPoint2: NSPoint(x: 3.8, y: 13.5))
            left.close()
            left.fill()

            let right = NSBezierPath()
            right.move(to: NSPoint(x: 9.75, y: 5.75))
            right.curve(to: NSPoint(x: 14.6, y: 2),
                        controlPoint1: NSPoint(x: 11, y: 4.05), controlPoint2: NSPoint(x: 13.15, y: 2.55))
            right.line(to: NSPoint(x: 14.2, y: 5.45))
            right.line(to: NSPoint(x: 17, y: 4.1))
            right.line(to: NSPoint(x: 17, y: 12.95))
            right.curve(to: NSPoint(x: 9.75, y: 15.75),
                        controlPoint1: NSPoint(x: 14.25, y: 13.4), controlPoint2: NSPoint(x: 11.8, y: 14.45))
            right.close()
            right.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LCP Desktop"
        return image
    }()
}
