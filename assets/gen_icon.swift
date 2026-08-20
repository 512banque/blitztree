import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let S = CGFloat(px)
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
squircle.addClip()
NSColor(calibratedWhite: 0.085, alpha: 1).setFill()
rect.fill()

func tile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
          _ hue: CGFloat, _ sat: CGFloat, _ bri: CGFloat) {
    let g: CGFloat = 9
    let r = CGRect(x: rect.minX + x*rect.width + g, y: rect.minY + y*rect.height + g,
                   width: w*rect.width - 2*g, height: h*rect.height - 2*g)
    let base = NSColor(calibratedHue: hue, saturation: sat, brightness: bri, alpha: 1)
    let grad = NSGradient(colors: [
        base.blended(withFraction: 0.38, of: .white)!,
        base,
        base.blended(withFraction: 0.36, of: .black)!,
    ])!
    let p = NSBezierPath(roundedRect: r, xRadius: 30, yRadius: 30)
    grad.draw(in: p, angle: -55)
}

// mini squarified map, our palette
tile(0.00, 0.42, 0.58, 0.58, 0.055, 0.78, 0.98) // orange (big)
tile(0.58, 0.42, 0.42, 0.58, 0.80, 0.55, 0.92)  // purple
tile(0.00, 0.00, 0.36, 0.42, 0.60, 0.62, 0.92)  // blue
tile(0.36, 0.00, 0.34, 0.42, 0.34, 0.63, 0.85)  // green
tile(0.70, 0.21, 0.30, 0.21, 0.125, 0.72, 0.95) // amber
tile(0.70, 0.00, 0.30, 0.21, 0.47, 0.60, 0.84)  // teal

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
