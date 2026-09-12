import AppKit
import Foundation

@main
struct DMGArtwork {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      fputs("usage: render-dmg-background.swift <input> <output>\n", stderr)
      exit(64)
    }

    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let source = NSImage(contentsOf: inputURL),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1280,
        pixelsHigh: 800,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      fputs("could not create the DMG background\n", stderr)
      exit(1)
    }

    let size = NSSize(width: 640, height: 400)
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let context = graphics.cgContext
    context.scaleBy(x: 2, y: 2)

    let bounds = NSRect(origin: .zero, size: size)
    let sourceRatio = source.size.width / source.size.height
    let targetRatio = size.width / size.height
    let drawRect: NSRect
    if sourceRatio > targetRatio {
      let width = size.height * sourceRatio
      drawRect = NSRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    } else {
      let height = size.width / sourceRatio
      drawRect = NSRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
    source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)

    NSGradient(
      colorsAndLocations: (NSColor.black.withAlphaComponent(0.38), 0),
      (NSColor.black.withAlphaComponent(0.08), 0.48),
      (NSColor.black.withAlphaComponent(0.32), 1)
    )?.draw(in: bounds, angle: -90)

    let panel = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 14, dy: 14),
      xRadius: 24,
      yRadius: 24
    )
    NSColor.white.withAlphaComponent(0.12).setStroke()
    panel.lineWidth = 1
    panel.stroke()

    func drawCentered(_ value: String, y: CGFloat, font: NSFont, color: NSColor) {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
      ]
      let text = NSAttributedString(string: value, attributes: attributes)
      let textSize = text.size()
      text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: y))
    }

    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
      .foregroundColor: NSColor.white,
    ]
    let title = NSAttributedString(string: "Install Quodex", attributes: titleAttributes)
    let titleX = (size.width - title.size().width - 41) / 2
    context.saveGState()
    context.translateBy(x: titleX, y: 369)
    context.scaleBy(x: 1, y: -1)
    context.addPath(QuodexMarkGeometry.path(in: CGRect(x: 0, y: 0, width: 30, height: 30)))
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    context.setLineWidth(3.2)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()
    title.draw(at: NSPoint(x: titleX + 41, y: 341))

    for centerX: CGFloat in [180, 460] {
      let label = NSBezierPath(
        roundedRect: NSRect(x: centerX - 66, y: 103, width: 132, height: 27), xRadius: 13.5,
        yRadius: 13.5)
      NSColor.white.withAlphaComponent(0.86).setFill()
      label.fill()
    }

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 273, y: 196))
    arrow.line(to: NSPoint(x: 367, y: 196))
    arrow.move(to: NSPoint(x: 351, y: 208))
    arrow.line(to: NSPoint(x: 367, y: 196))
    arrow.line(to: NSPoint(x: 351, y: 184))
    NSColor.white.withAlphaComponent(0.78).setStroke()
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()

    drawCentered(
      "Drag Quodex to Applications",
      y: 72,
      font: .systemFont(ofSize: 20, weight: .semibold),
      color: .white
    )
    drawCentered(
      "Then eject Quodex and delete the downloaded DMG.",
      y: 43,
      font: .systemFont(ofSize: 12, weight: .medium),
      color: .white.withAlphaComponent(0.66)
    )

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      fputs("could not encode the DMG background\n", stderr)
      exit(1)
    }
    try data.write(to: outputURL, options: .atomic)
  }
}
