// Lay a rendering of the app icon on the macOS icon grid, at every size an
// .icns needs, and at 1024 pixels for the README. make-icon-assets.sh runs
// this with Icon Composer's rendering of AppIcon.icon.
//
// Usage: swift app/flatten-icon.swift RENDER ICONSET PNG
//
// RENDER is the icon shape alone, edge to edge, as ictool exports it. The
// macOS grid puts that shape in an 824-point square on a 1024-point canvas,
// with a soft shadow under it.

import AppKit

let args = CommandLine.arguments
guard args.count == 4, let render = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("Usage: swift flatten-icon.swift RENDER ICONSET PNG\n".data(using: .utf8)!)
    exit(1)
}

/// The icon at a pixel size, as PNG data.
func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    let k = CGFloat(px) / 1024
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    render.draw(in: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024).write(to: URL(fileURLWithPath: args[3]))
