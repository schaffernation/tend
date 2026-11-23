// Make the website's images from the app icon and the README screenshots.
// Usage: swift site/make-images.swift
//
// Run it again after you change app/make-icon.swift or rerun
// app/screenshot/make.sh. It writes:
//
//   site/favicon.ico               16 and 32 pixels, for browsers that ask for it
//   site/apple-touch-icon.png      180 pixels, full bleed (iOS rounds the corners)
//   site/images/favicon-32.png     the icon's tile, without the margin
//   site/images/icon-192.png       the app icon, for the Web App Manifest
//   site/images/icon-512.png       the app icon, for the manifest and the page
//   site/images/og.png             1200 by 630, the card that link previews show
//
// The screenshots in site/images come from app/screenshot/make.sh, at 4x.

import AppKit

let site = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repo = site.deletingLastPathComponent()
let images = site.appendingPathComponent("images")
try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

guard let icon = NSImage(contentsOf: repo.appendingPathComponent("app/AppIcon.png")) else {
    fatalError("Can't read app/AppIcon.png. Run swift app/make-icon.swift first.")
}

// The icon's geometry and colors, from app/make-icon.swift: an 824-point
// tile with 185-point corners on a 1024-point canvas, filled with a dark
// green-to-charcoal gradient.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let top = NSColor(srgbRed: 0.10, green: 0.30, blue: 0.22, alpha: 1)
let bottom = NSColor(srgbRed: 0.07, green: 0.11, blue: 0.12, alpha: 1)
let sprout = NSColor(srgbRed: 0.45, green: 0.86, blue: 0.52, alpha: 1)

func render(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) throws {
    try data.write(to: site.appendingPathComponent(path))
    print("Wrote site/\(path)")
}

// The whole icon, margin and shadow included, as macOS shows it.
func wholeIcon(_ size: Int) -> Data {
    render(size, size) { _ in
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    }
}

// Only the tile, scaled to fill the canvas. With fullBleed, the gradient
// fills the corners too, for platforms that round the corners themselves.
func tileIcon(_ size: Int, fullBleed: Bool) -> Data {
    render(size, size) { ctx in
        let s = CGFloat(size)
        let bounds = CGRect(x: 0, y: 0, width: s, height: s)
        if fullBleed {
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s),
                                   end: .zero, options: [])
        }
        let radius = 185 / tile.width * s
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
        ctx.clip()
        icon.draw(in: bounds, from: tile, operation: .sourceOver, fraction: 1)
    }
}

// An .ico file can hold PNG images as they are.
func ico(_ pngs: [(size: Int, data: Data)]) -> Data {
    var out = Data()
    func u16(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16) }
    u16(0); u16(1); u16(pngs.count)
    var offset = 6 + 16 * pngs.count
    for png in pngs {
        out.append(UInt8(png.size)); out.append(UInt8(png.size))
        out.append(0); out.append(0)
        u16(1); u16(32); u32(png.data.count); u32(offset)
        offset += png.data.count
    }
    for png in pngs { out.append(png.data) }
    return out
}

// The link preview card: the icon and the name on a deep green field.
func card() -> Data {
    let width = 1200, height = 630
    return render(width, height) { ctx in
        let w = CGFloat(width), h = CGFloat(height)
        let field = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor(srgbRed: 0.075, green: 0.16, blue: 0.125, alpha: 1).cgColor,
                     NSColor(srgbRed: 0.04, green: 0.065, blue: 0.065, alpha: 1).cgColor]
                as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(field, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0),
                               options: [])
        // A soft sprout-colored glow behind the icon.
        let glow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [sprout.withAlphaComponent(0.20).cgColor,
                     sprout.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1])!
        let center = CGPoint(x: 300, y: h / 2)
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: 330, options: [])

        let iconSize: CGFloat = 400
        icon.draw(in: NSRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2,
                             width: iconSize, height: iconSize))

        func text(_ string: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat,
                  kern: CGFloat = 0) {
            NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: color, .kern: kern,
            ]).draw(at: NSPoint(x: x, y: y))
        }
        let x: CGFloat = 540
        text("Tend", .systemFont(ofSize: 168, weight: .bold),
             NSColor(white: 0.96, alpha: 1), x: x - 6, y: 300, kern: -4)
        text("Your terminal sessions,", .systemFont(ofSize: 44, weight: .medium),
             NSColor(white: 0.96, alpha: 0.85), x: x, y: 230)
        text("back after a restart.", .systemFont(ofSize: 44, weight: .medium),
             NSColor(white: 0.96, alpha: 0.85), x: x, y: 176)
        text("A menu bar app and CLI for macOS", .monospacedSystemFont(ofSize: 26, weight: .medium),
             sprout, x: x, y: 104)
    }
}

try write(ico([(16, tileIcon(16, fullBleed: false)), (32, tileIcon(32, fullBleed: false))]),
          "favicon.ico")
try write(tileIcon(180, fullBleed: true), "apple-touch-icon.png")
try write(tileIcon(32, fullBleed: false), "images/favicon-32.png")
try write(wholeIcon(192), "images/icon-192.png")
try write(wholeIcon(512), "images/icon-512.png")
try write(card(), "images/og.png")

