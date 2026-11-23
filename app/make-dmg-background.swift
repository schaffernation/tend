// Draw the background of Tend's disk image window as a PNG.
// app/make-dmg.sh runs this script.
// Usage: swift app/make-dmg-background.swift OUT.png
//
// The window's content is 640 by 400 points. Tend.app sits on the left and
// the Applications folder on the right, with an arrow between them whose head
// is the prompt chevron from the app icon. app/make-dmg.sh places the icons at
// the centers below, so change both together. The picture is 40 points taller
// than the window, so a taller title bar never shows an edge, and everything
// that matters sits in the top 340 points, so it stays visible when someone
// has Finder's path bar and status bar turned on.
//
// Finder draws icon labels in black in light mode and in white in dark mode,
// over a picture it can't change. The background is a sage green whose
// relative luminance is about 0.18 behind the labels, which gives black and
// white text about the same contrast (roughly 4.5:1), so the labels stay
// legible in either appearance.
//
// The picture has one resolution, 1 pixel per point. Finder in macOS 27 draws
// a background at 1 point per pixel of its largest version and ignores its
// DPI, so a multi-resolution (@1x and @2x) TIFF from `tiffutil
// -cathidpicheck` shows at double size there. A @1x picture is a little soft
// on a Retina display, but it's the right size on every version of macOS.

import AppKit

let width: CGFloat = 640, height: CGFloat = 440
let appCenter = CGPoint(x: 160, y: 160)          // Finder coordinates: from the top left
let applicationsCenter = CGPoint(x: 480, y: 160)
let textCenterY: CGFloat = 300

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("Usage: swift make-dmg-background.swift OUT.png\n".data(using: .utf8)!)
    exit(2)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Sage green, a lighter tint of the icon's dark green, top to bottom.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(srgbRed: 0.41, green: 0.56, blue: 0.49, alpha: 1).cgColor,
        NSColor(srgbRed: 0.32, green: 0.45, blue: 0.40, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height),
                       end: CGPoint(x: 0, y: 0), options: [])

// Arrow from the app to Applications: a dotted line and the prompt chevron,
// in the icon's rounded strokes.
let light = NSColor(srgbRed: 0.93, green: 0.98, blue: 0.94, alpha: 1)
let y = height - appCenter.y
let start = appCenter.x + 96, end = applicationsCenter.x - 96
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(light.cgColor)
ctx.setLineWidth(6)
ctx.setLineDash(phase: 0, lengths: [0.1, 14])
ctx.move(to: CGPoint(x: start, y: y))
ctx.addLine(to: CGPoint(x: end - 18, y: y))
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])
ctx.setLineWidth(8)
ctx.move(to: CGPoint(x: end - 20, y: y + 20))
ctx.addLine(to: CGPoint(x: end, y: y))
ctx.addLine(to: CGPoint(x: end - 20, y: y - 20))
ctx.strokePath()

// Instruction line.
let style = NSMutableParagraphStyle()
style.alignment = .center
let text = NSAttributedString(
    string: "Drag Tend to Applications to install it.",
    attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
        .foregroundColor: light,
        .paragraphStyle: style,
    ])
let textHeight = text.size().height
text.draw(in: CGRect(x: 0, y: height - textCenterY - textHeight / 2,
                     width: width, height: textHeight))

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
