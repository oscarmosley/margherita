// Stock AppKit renderer. Logical canvas matches Finder's 800 x 440 content area.
// Icon wells are deliberately empty: Finder supplies the only draggable icons.
import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("DMG artwork: \(message)\n", stderr)
    exit(1)
}
let args = CommandLine.arguments
guard args.count == 3 else { fail("expected output directory, or --volume-icon mountpoint") }
if args[1] == "--volume-icon" {
    let root = URL(fileURLWithPath: args[2], isDirectory: true)
    guard let icon = NSImage(contentsOf: root.appendingPathComponent(".VolumeIcon.icns")),
          NSWorkspace.shared.setIcon(icon, forFile: root.path, options: []) else {
        fail("could not set the volume's custom icon")
    }
    exit(0)
}
let output = URL(fileURLWithPath: args[1], isDirectory: true)
let version = args[2]
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let cream = color(0.98, 0.94, 0.85)
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 24, y: y, width: 752, height: size * 1.7),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                         .foregroundColor: cream.withAlphaComponent(alpha),
                         .paragraphStyle: paragraph])
}
for scale in [1, 2] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800 * scale,
        pixelsHigh: 440 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fail("cannot allocate bitmap") }
    bitmap.size = NSSize(width: 800, height: 440)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // Top-down artwork coordinates agree with Finder icon positions.
    context.cgContext.translateBy(x: 0, y: 440)
    context.cgContext.scaleBy(x: 1, y: -1)
    let canvas = NSRect(x: 0, y: 0, width: 800, height: 440)
    NSGradient(colors: [color(0.75, 0.22, 0.17), color(0.38, 0.14, 0.12),
                        color(0.13, 0.10, 0.09)])!.draw(in: canvas, angle: 90)
    NSGradient(starting: color(0.98, 0.86, 0.64, 0.30),
               ending: color(0.98, 0.86, 0.64, 0))!.draw(
        fromCenter: NSPoint(x: 390, y: 400), radius: 0,
        toCenter: NSPoint(x: 390, y: 400), radius: 460, options: [.drawsAfterEndingLocation])
    NSGradient(starting: color(0.27, 0.43, 0.30, 0.52),
               ending: color(0.27, 0.43, 0.30, 0))!.draw(
        fromCenter: NSPoint(x: 790, y: 10), radius: 0,
        toCenter: NSPoint(x: 790, y: 10), radius: 340, options: [.drawsAfterEndingLocation])
    // Glass panel, subtle rim, and two landing wells, not illustration icons.
    let panel = NSBezierPath(roundedRect: NSRect(x: 92, y: 157, width: 616, height: 183),
                             xRadius: 32, yRadius: 32)
    color(1, 0.96, 0.88, 0.065).setFill(); panel.fill()
    color(1, 0.96, 0.88, 0.17).setStroke(); panel.lineWidth = 1; panel.stroke()
    for x in [CGFloat(220), CGFloat(580)] {
        let well = NSBezierPath(roundedRect: NSRect(x: x - 76, y: 174, width: 152, height: 134),
                                xRadius: 26, yRadius: 26)
        color(0.10, 0.07, 0.05, 0.13).setFill(); well.fill()
        color(1, 0.96, 0.88, 0.10).setStroke(); well.stroke()
    }
    // Cream arrow, intentionally the only pictogram in the background.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 365, y: 240)); arrow.line(to: NSPoint(x: 435, y: 240))
    arrow.move(to: NSPoint(x: 420, y: 225)); arrow.line(to: NSPoint(x: 435, y: 240))
    arrow.line(to: NSPoint(x: 420, y: 255))
    cream.withAlphaComponent(0.75).setStroke()
    arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    // NSString uses AppKit's flipped drawing flag for upright typography.
    context.cgContext.saveGState()
    context.cgContext.translateBy(x: 0, y: 440)
    context.cgContext.scaleBy(x: 1, y: -1)
    text("Welcome to", y: 440 - 45 - 25, size: 20, weight: .medium, alpha: 0.78)
    text("Margherita", y: 440 - 75 - 66, size: 54, weight: .bold)
    text("Drag Margherita into Applications", y: 440 - 365 - 26, size: 16, weight: .medium, alpha: 0.90)
    text("VERSION " + version + "  ·  MADE FOR YOUR MAC", y: 440 - 401 - 18, size: 10, weight: .medium, alpha: 0.48)
    context.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
    do { try png.write(to: output.appendingPathComponent(name), options: .atomic) }
    catch { fail(error.localizedDescription) }
}
