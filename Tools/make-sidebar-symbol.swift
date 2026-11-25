// Generates Finder's sidebar symbol for JottaFS disks,
// HostApp/Assets.xcassets/jottafs.drive.symbolset/jottafs.drive.svg:
// the outline of the system symbol `internaldrive` (font glyph "drive.color",
// without its vent bars) with the Jottacloud logo lying on its top face in
// perspective. The app's Info.plist names it in
// CFBundleIcons > CFBundlePrimaryIcon > CFBundleSymbolName.
//
// Needs the SF Symbols app (its SFSymbolsFallback.otf has the glyph).
// Run from the repository root:  swift Tools/make-sidebar-symbol.swift
//
// Measurements: the drive's top face (the inner trapezoid) and the logo
// size (62 % of the face width, the face 1.4 times as wide as deep) were
// chosen against renderings of `internaldrive` at 120 pt; the logo is the
// two Jottacloud leaves (viewBox 0 0 48 48, corner radius 13).

import AppKit
import CoreText

// Glyph space: 100 pt, origin on the baseline, y up (SVG: y down, negated).

let fontURL = URL(fileURLWithPath: "/Applications/SF Symbols.app/Contents/Resources/Fonts/SFSymbolsFallback.otf")
let cgFont = CGFont(CGDataProvider(url: fontURL as CFURL)!)!
let font100 = CTFontCreateWithGraphicsFont(cgFont, 100, nil, nil)
var glyph = cgFont.getGlyphWithGlyphName(name: "drive.color" as CFString)
let drive100 = CTFontCreatePathForGlyph(font100, glyph, nil)!
var advance = CGSize.zero
CTFontGetAdvancesForGlyphs(font100, .horizontal, &glyph, &advance, 1)

// The logo, computed in the preview's "raster space" (y down, glyph at
// 150 pt placed with its box at x 25, top 21), then mapped back.
let font150 = CTFontCreateWithGraphicsFont(cgFont, 150, nil, nil)
let gb150 = CTFontCreatePathForGlyph(font150, glyph, nil)!.boundingBoxOfPath
func rasterToGlyph(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (p.x - (25 - gb150.minX)) / 1.5, y: -(p.y - (21 + gb150.maxY)) / 1.5)
}
func leaf(_ r: CGRect, roundTopLeft: Bool, radius: CGFloat) -> [CGPoint] {
    func arc(_ c: CGPoint, from a0: CGFloat, to a1: CGFloat) -> [CGPoint] {
        (0...32).map { i in let a = a0 + (a1 - a0) * CGFloat(i) / 32; return CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a)) }
    }
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    if roundTopLeft {
        return arc(CGPoint(x: x0 + radius, y: y0 + radius), from: .pi, to: 1.5 * .pi) + [CGPoint(x: x1, y: y0)]
            + arc(CGPoint(x: x1 - radius, y: y1 - radius), from: 0, to: 0.5 * .pi) + [CGPoint(x: x0, y: y1)]
    }
    return [CGPoint(x: x0, y: y0)] + arc(CGPoint(x: x1 - radius, y: y0 + radius), from: 1.5 * .pi, to: 2 * .pi)
        + [CGPoint(x: x1, y: y1)] + arc(CGPoint(x: x0 + radius, y: y1 - radius), from: 0.5 * .pi, to: .pi)
}
let leaves = [
    leaf(CGRect(x: 26.0556, y: 5.5, width: 16.4444, height: 37), roundTopLeft: true, radius: 13),
    leaf(CGRect(x: 5.5, y: 26.0556, width: 16.4444, height: 16.4444), roundTopLeft: false, radius: 13),
]
let quad = [CGPoint(x: 64, y: 30), CGPoint(x: 124, y: 30), CGPoint(x: 142, y: 67), CGPoint(x: 45, y: 67)]
func homography(_ p: [CGPoint]) -> (CGPoint) -> CGPoint {
    let (x0, y0, x1, y1, x2, y2, x3, y3) = (p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y, p[3].x, p[3].y)
    let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
    let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
    let den = dx1 * dy2 - dx2 * dy1
    let g = (dx3 * dy2 - dx2 * dy3) / den, h = (dx1 * dy3 - dx3 * dy1) / den
    let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
    let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0
    return { q in let w = g * q.x + h * q.y + 1; return CGPoint(x: (a * q.x + b * q.y + c) / w, y: (d * q.x + e * q.y + f) / w) }
}
let toFace = homography(quad)
let faceAspect: CGFloat = 1.4, logoWidth: CGFloat = 0.62
let logoPolys: [[CGPoint]] = leaves.map { l in
    l.map { p in
        let u = 0.5 + ((p.x - 24) / 37) * logoWidth
        let v = 0.5 + ((p.y - 24) / 37) * logoWidth * faceAspect
        return rasterToGlyph(toFace(CGPoint(x: u, y: v)))
    }
}

// SVG path data relative to the symbol's origin (baseline), y negated.
func f(_ v: CGFloat) -> String { String(format: "%.4f", v) }
var d = ""
drive100.applyWithBlock { e in
    let p = e.pointee.points
    func q(_ i: Int) -> String { "\(f(p[i].x)) \(f(-p[i].y))" }
    switch e.pointee.type {
    case .moveToPoint: d += "M\(q(0)) "
    case .addLineToPoint: d += "L\(q(0)) "
    case .addQuadCurveToPoint: d += "Q\(q(0)) \(q(1)) "
    case .addCurveToPoint: d += "C\(q(0)) \(q(1)) \(q(2)) "
    case .closeSubpath: d += "Z "
    @unknown default: break
    }
}
for poly in logoPolys {
    d += "M\(f(poly[0].x)) \(f(-poly[0].y)) "
    for p in poly.dropFirst() { d += "L\(f(p.x)) \(f(-p.y)) " }
    d += "Z "
}

// Template v3 layout (as exported by the SF Symbols app): three weights at
// small scale; the same outline is used for all three.
let baselineS: CGFloat = 696, caplineS: CGFloat = 625.541
let columns: [(String, CGFloat)] = [("Ultralight-S", 559.711), ("Regular-S", 1449.52), ("Black-S", 2339.33)]
var guides = """
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>

"""
var symbols = ""
for (name, x) in columns {
    guides += "  <line id=\"left-margin-\(name)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(f(x))\" x2=\"\(f(x))\" y1=\"600.785\" y2=\"720.121\"/>\n"
    guides += "  <line id=\"right-margin-\(name)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(f(x + advance.width))\" x2=\"\(f(x + advance.width))\" y1=\"600.785\" y2=\"720.121\"/>\n"
    symbols += "  <g id=\"\(name)\" transform=\"matrix(1 0 0 1 \(f(x)) \(f(baselineS)))\">\n   <path d=\"\(d)\"/>\n  </g>\n"
}
let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--JottaFS sidebar symbol: the internaldrive outline with the Jottacloud logo on its top face.-->
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
 </g>
 <g id="Guides">
\(guides) </g>
 <g id="Symbols">
\(symbols) </g>
</svg>
"""
try! svg.write(toFile: "HostApp/Assets.xcassets/jottafs.drive.symbolset/jottafs.drive.svg", atomically: true, encoding: .utf8)
print("advance \(advance.width), path chars \(d.count)")
