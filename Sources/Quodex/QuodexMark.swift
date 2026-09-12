import AppKit
import SwiftUI

enum QuodexMarkGeometry {
    static func path(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: side * 0.39,
            startAngle: degrees(210),
            endAngle: degrees(510),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: side * 0.24,
            startAngle: degrees(90),
            endAngle: degrees(390),
            clockwise: false
        )
        return path
    }

    private static func degrees(_ value: CGFloat) -> CGFloat {
        value * .pi / 180
    }
}

struct QuodexMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path(QuodexMarkGeometry.path(in: rect))
    }
}

enum QuodexMarkImage {
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
            context.addPath(QuodexMarkGeometry.path(in: rect.insetBy(dx: 3, dy: 3)))
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(2.5)
            context.setLineCap(.round)
            context.strokePath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Quodex"
        return image
    }
}
