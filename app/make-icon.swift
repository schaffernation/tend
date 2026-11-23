// Draw Tend's app icon as a layered Icon Composer icon, app/AppIcon.icon.
// Usage: swift app/make-icon.swift
//
// The icon is a terminal prompt whose cursor is a sprout: a session you tend.
// The package holds icon.json and one SVG for each layer: the chevron and the
// sprout. The background is the document's fill, a dark green-to-charcoal
// gradient, so the system can replace it for the dark, clear, and tinted
// appearances. macOS 26 and later render the layers as Liquid Glass.
//
// After you run this, run app/make-icon-assets.sh, which compiles the
// package into Assets.car and the flat AppIcon.icns that macOS 14 and 15
// use. Open the package in Icon Composer only to look at it: this script
// rewrites it from the geometry below.
//
// The geometry was first drawn for an 824-point tile on a 1024-point canvas
// (the old macOS icon grid). An Icon Composer canvas is the tile itself, so
// every point is scaled from the old tile to the full 1024-point canvas, and
// flipped, since SVG's y axis points down.

import CoreGraphics
import Foundation

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let package = here.appendingPathComponent("AppIcon.icon")
let assets = package.appendingPathComponent("Assets")

/// Scale a point from the old 824-point tile (at 100, 100) to the canvas.
let scale: CGFloat = 1024 / 824
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: (x - 100) * scale, y: (924 - y) * scale)
}

/// A stroke as a filled outline. The glass renderer treats a layer as solid
/// shapes, and draws an open stroked path with a seam where it closes the
/// path, so every layer is a filled outline.
func outline(width: CGFloat, _ build: (CGMutablePath) -> Void) -> CGPath {
    let path = CGMutablePath()
    build(path)
    return path.copy(strokingWithWidth: width * scale, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// SVG path data for a CGPath.
func pathData(_ path: CGPath) -> String {
    var d: [String] = []
    func f(_ p: CGPoint) -> String { String(format: "%.2f %.2f", p.x, p.y) }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: d.append("M \(f(e.points[0]))")
        case .addLineToPoint: d.append("L \(f(e.points[0]))")
        case .addQuadCurveToPoint: d.append("Q \(f(e.points[0])) \(f(e.points[1]))")
        case .addCurveToPoint: d.append("C \(f(e.points[0])) \(f(e.points[1])) \(f(e.points[2]))")
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined(separator: " ")
}

func svg(_ path: CGPath, color: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <path d="\(pathData(path))" fill="\(color)"/>
    </svg>

    """
}

// The prompt chevron.
let chevron = svg(outline(width: 64) { p in
    p.move(to: pt(270, 640))
    p.addLine(to: pt(430, 512))
    p.addLine(to: pt(270, 384))
}, color: "#F5F5F5")

// The sprout in place of the cursor: a soil line, a stem, and two leaves,
// merged into one shape.
func leaf(base: CGPoint, tip: CGPoint, bulge: CGFloat) -> CGPath {
    let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
    let dx = tip.x - base.x, dy = tip.y - base.y
    let len = (dx * dx + dy * dy).squareRoot()
    let nx = -dy / len * bulge, ny = dx / len * bulge
    let p = CGMutablePath()
    p.move(to: pt(base.x, base.y))
    p.addQuadCurve(to: pt(tip.x, tip.y), control: pt(mid.x + nx, mid.y + ny))
    p.addQuadCurve(to: pt(base.x, base.y), control: pt(mid.x - nx, mid.y - ny))
    p.closeSubpath()
    return p
}
let soil = outline(width: 56) { p in
    p.move(to: pt(520, 330))
    p.addLine(to: pt(760, 330))
}
let stem = outline(width: 30) { p in
    p.move(to: pt(640, 340))
    p.addCurve(to: pt(640, 560), control1: pt(632, 420), control2: pt(648, 490))
}
let sprout = svg(soil.union(stem)
    .union(leaf(base: CGPoint(x: 640, y: 500), tip: CGPoint(x: 770, y: 610), bulge: 62))
    .union(leaf(base: CGPoint(x: 636, y: 450), tip: CGPoint(x: 520, y: 540), bulge: 52)),
    color: "#73DB85")  // sRGB 0.45, 0.86, 0.52

/// One group per layer, so each gets its own glass, shadow, and depth.
func group(_ name: String) -> [String: Any] {
    [
        "layers": [["image-name": "\(name).svg", "name": name, "glass": true]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": true, "value": 0.4],
    ]
}

// The old icon's gradient, from green at the top to charcoal at the bottom.
let icon: [String: Any] = [
    "fill": [
        "linear-gradient": [
            "extended-srgb:0.10000,0.30000,0.22000,1.00000",
            "extended-srgb:0.07000,0.11000,0.12000,1.00000",
        ],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ],
    // Groups listed first are drawn on top.
    "groups": [group("sprout"), group("chevron")],
    "supported-platforms": ["squares": "shared"],
]

try? FileManager.default.removeItem(at: package)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try chevron.write(to: assets.appendingPathComponent("chevron.svg"), atomically: true, encoding: .utf8)
try sprout.write(to: assets.appendingPathComponent("sprout.svg"), atomically: true, encoding: .utf8)
let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try json.write(to: package.appendingPathComponent("icon.json"))
print("Wrote \(package.path). Now run app/make-icon-assets.sh.")
