import AppKit
import CoreGraphics

// Draws the JottaFS app icon (1024×1024) to the PNG path given as the first
// argument. Build the .icns with sips (all sizes) and iconutil.
let size = 1024
guard CommandLine.arguments.count == 2 else {
    print("Usage: make-app-icon <output.png>")
    exit(2)
}
let out = CommandLine.arguments[1]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
}

// The icon is the drive itself, like the volume icon: Apple's icon grid
// (824 pt body, 100 pt margin) in the volume icon's purple, its grey bottom
// band with a light, and a white cloud.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186).cgPath
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x9E71F8))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
// Volume icon purple: #A274FF at the top to #996DF1 at the bottom.
linear([color(0xA274FF), color(0x996DF1)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 880), startRadius: 0, endCenter: CGPoint(x: 400, y: 880), endRadius: 600, options: [])

// Grey bottom band, as on the volume icon.
let band = CGRect(x: body.minX, y: body.minY, width: body.width, height: 170)
ctx.saveGState()
ctx.clip(to: band)
linear([color(0xDCDCDE), color(0xBDBDC1)], from: CGPoint(x: 512, y: band.maxY), to: CGPoint(x: 512, y: band.minY))
ctx.restoreGState()
ctx.setFillColor(color(0x7E58D0, 0.55))
ctx.fill(CGRect(x: band.minX, y: band.maxY, width: band.width, height: 4))
ctx.restoreGState()

// Light on the band.
let led = CGRect(x: body.maxX - 150, y: body.minY + 70, width: 34, height: 34)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillEllipse(in: led)
ctx.setStrokeColor(color(0x9A9AA0, 0.8))
ctx.setLineWidth(3)
ctx.strokeEllipse(in: led)

// White cloud, wide and low, centred in the purple area.
let cloud = CGMutablePath()
let base = CGRect(x: 302, y: 472, width: 420, height: 104)
cloud.addPath(NSBezierPath(roundedRect: base, xRadius: 52, yRadius: 52).cgPath)
cloud.addEllipse(in: CGRect(x: 340, y: 490, width: 150, height: 150))
cloud.addEllipse(in: CGRect(x: 440, y: 512, width: 196, height: 196))
cloud.addEllipse(in: CGRect(x: 578, y: 494, width: 136, height: 136))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x3B1A8C, 0.30))
ctx.addPath(cloud)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath(using: .winding)
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
