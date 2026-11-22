import AppKit
import SwiftUI

enum WorkspacePalette {
    static let canvas = adaptive(0xF6F7F4, 0x161A1A)
    static let surface = adaptive(0xFDFEFC, 0x202625)
    static let ink = adaptive(0x182526, 0xF2F6F2)
    static let muted = adaptive(0x546560, 0xB1C0B9)
    static let accent = adaptive(0x10695D, 0x85DCC4)
    static let line = adaptive(0xCDD6CF, 0x46534D)
    static let tintSurface = adaptive(0xE0EEE6, 0x293F38)

    private static let covers = [
        Color(red: 0.23, green: 0.26, blue: 0.40),
        Color(red: 0.10, green: 0.29, blue: 0.26),
        Color(red: 0.23, green: 0.28, blue: 0.35),
        Color(red: 0.35, green: 0.24, blue: 0.21)
    ]

    static func cover(for courseCode: String) -> Color {
        let sum = courseCode.utf8.reduce(0) { $0 &+ Int($1) }
        return Self.covers[sum % Self.covers.count]
    }

    private static func adaptive(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

/// Fine page edges on the right-hand side of a course cover.
struct CourseCoverLines: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width, height = size.height
            for page in 0..<22 {
                let offset = CGFloat(page) * 5.2
                var line = Path()
                line.move(to: CGPoint(x: width * 0.15 + offset, y: height + 3))
                line.addCurve(to: CGPoint(x: width + 15, y: -14 + offset * 0.65),
                              control1: CGPoint(x: width * 0.28 + offset, y: height * 0.75),
                              control2: CGPoint(x: width * 0.70 - offset * 0.25, y: height * 0.05 + offset * 0.45))
                context.stroke(line, with: .color(Color.white.opacity(0.20)), lineWidth: 0.8)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
