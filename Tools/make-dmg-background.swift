import AppKit
import CoreGraphics

// Draws the background of the JottaFS installer window (the DMG): a light
// purple surface, an arrow from the app to the Applications folder and a
// short instruction. Usage: make-dmg-background <output.png> <scale>
// Render scale 1 and 2, then combine with `tiffutil -cathidpicheck`.
// The layout must match the icon positions in scripts/build-release.sh.

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]) else {
    print("Usage: make-dmg-background <output.png> <scale>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let width = 660.0, height = 400.0

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("Could not create the drawing context.")
    exit(1)
}
ctx.scaleBy(x: scale, y: scale)

// Background: very light purple, slightly darker at the bottom.
let gradient = CGGradient(colorsSpace: space, colors: [color(0xFBF9FF), color(0xEFE8FF)] as CFArray, locations: nil)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// Arrow between the icons (app at x 165, Applications at x 495, icon centre y 190 from the top).
let arrowY = height - 190
ctx.setStrokeColor(color(0x9E71F8))
ctx.setLineWidth(6)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: arrowY))
ctx.addLine(to: CGPoint(x: 392, y: arrowY))
ctx.strokePath()
ctx.move(to: CGPoint(x: 370, y: arrowY + 20))
ctx.addLine(to: CGPoint(x: 396, y: arrowY))
ctx.addLine(to: CGPoint(x: 370, y: arrowY - 20))
ctx.strokePath()

// Instruction under the icons.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let text = NSAttributedString(
    string: "Drag JottaFS to Applications to install it",
    attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.33, green: 0.25, blue: 0.52, alpha: 1),
        .paragraphStyle: paragraph,
    ]
)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
text.draw(in: CGRect(x: 0, y: 62, width: width, height: 24))
NSGraphicsContext.restoreGraphicsState()

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else {
    print("Could not render the background.")
    exit(1)
}
do {
    try data.write(to: output)
} catch {
    print("Could not write \(output.path): \(error.localizedDescription)")
    exit(1)
}
