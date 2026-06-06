import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) -> NSRect {
    NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
}

func point(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat) -> NSPoint {
    NSPoint(x: x * scale, y: y * scale)
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func withShadow(color: NSColor, blur: CGFloat, x: CGFloat = 0, y: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: x, height: y)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawFileCard(originX: CGFloat, originY: CGFloat, rotation: CGFloat, scale: CGFloat, alpha: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: originX * scale, yBy: originY * scale)
    transform.rotate(byDegrees: rotation)
    transform.concat()

    let card = rect(0, 0, 232, 284, scale)
    withShadow(color: color(0.10, 0.19, 0.36, 0.18), blur: 22 * scale, y: -12 * scale) {
        color(1, 1, 1, alpha).setFill()
        rounded(card, 42 * scale).fill()
    }

    color(0.77, 0.89, 1.0, 0.9).setFill()
    rounded(rect(38, 180, 156, 28, scale), 14 * scale).fill()
    color(0.86, 0.94, 1.0, 0.9).setFill()
    rounded(rect(38, 128, 116, 26, scale), 13 * scale).fill()
    rounded(rect(38, 78, 148, 26, scale), 13 * scale).fill()

    NSGraphicsContext.restoreGraphicsState()
}

func drawArrow(scale: CGFloat) {
    let path = NSBezierPath()
    path.move(to: point(344, 520, scale))
    path.curve(
        to: point(642, 520, scale),
        controlPoint1: point(440, 618, scale),
        controlPoint2: point(552, 610, scale)
    )
    path.lineWidth = 62 * scale
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    withShadow(color: color(0.03, 0.22, 0.44, 0.24), blur: 18 * scale, y: -8 * scale) {
        color(0.03, 0.57, 0.90).setStroke()
        path.stroke()
    }

    let head = NSBezierPath()
    head.move(to: point(704, 520, scale))
    head.line(to: point(594, 616, scale))
    head.line(to: point(594, 424, scale))
    head.close()
    color(0.03, 0.57, 0.90).setFill()
    head.fill()

    color(0.88, 0.98, 1.0, 0.42).setStroke()
    let highlight = NSBezierPath()
    highlight.move(to: point(364, 548, scale))
    highlight.curve(
        to: point(610, 556, scale),
        controlPoint1: point(454, 620, scale),
        controlPoint2: point(550, 602, scale)
    )
    highlight.lineWidth = 14 * scale
    highlight.lineCapStyle = .round
    highlight.stroke()
}

func drawDrive(scale: CGFloat) {
    let body = rect(570, 178, 318, 480, scale)

    withShadow(color: color(0.04, 0.13, 0.28, 0.28), blur: 34 * scale, y: -18 * scale) {
        NSGradient(
            starting: color(1, 1, 1),
            ending: color(0.89, 0.93, 0.98)
        )?.draw(in: rounded(body, 86 * scale), angle: -90)
    }

    color(0.70, 0.78, 0.88).setStroke()
    let stroke = rounded(body.insetBy(dx: 22 * scale, dy: 22 * scale), 64 * scale)
    stroke.lineWidth = 12 * scale
    stroke.stroke()

    color(0.18, 0.28, 0.43, 0.12).setFill()
    rounded(rect(638, 524, 182, 18, scale), 9 * scale).fill()

    color(0.93, 0.96, 0.99).setFill()
    rounded(rect(628, 276, 202, 116, scale), 40 * scale).fill()

    withShadow(color: color(0.02, 0.34, 0.20, 0.22), blur: 14 * scale, y: -3 * scale) {
        color(0.10, 0.76, 0.45).setFill()
        NSBezierPath(ovalIn: rect(694, 306, 70, 70, scale)).fill()
    }

    color(1, 1, 1, 0.56).setFill()
    rounded(rect(622, 604, 210, 26, scale), 13 * scale).fill()
}

func appIcon(size: CGFloat) -> NSImage {
    let scale = size / 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let background = rounded(NSRect(x: 0, y: 0, width: size, height: size), 220 * scale)
    background.setClip()

    NSGradient(
        colors: [
            color(0.94, 0.98, 1.0),
            color(0.73, 0.89, 1.0),
            color(0.18, 0.45, 0.94)
        ]
    )?.draw(in: background, angle: -38)

    color(1, 1, 1, 0.34).setFill()
    rounded(rect(104, 744, 608, 94, scale), 47 * scale).fill()
    color(0.02, 0.20, 0.45, 0.10).setFill()
    rounded(rect(-96, -104, 1220, 332, scale), 166 * scale).fill()

    drawFileCard(originX: 160, originY: 440, rotation: -8, scale: scale, alpha: 0.72)
    drawFileCard(originX: 212, originY: 504, rotation: 5, scale: scale, alpha: 0.92)
    drawDrive(scale: scale)
    drawArrow(scale: scale)

    color(1, 1, 1, 0.34).setStroke()
    let border = rounded(NSRect(x: 9 * scale, y: 9 * scale, width: size - 18 * scale, height: size - 18 * scale), 205 * scale)
    border.lineWidth = 10 * scale
    border.stroke()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    try data.write(to: url, options: .atomic)
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (name, size) in variants {
    try writePNG(appIcon(size: size), to: iconsetURL.appendingPathComponent(name))
}

try? FileManager.default.removeItem(at: icnsURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw CocoaError(.fileWriteUnknown)
}

print("Generated \(icnsURL.lastPathComponent)")
