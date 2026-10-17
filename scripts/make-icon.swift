// Draws Wheelie's app icon (a wheel of format petals) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square background with an indigo gradient.
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.addPath(bg)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.45, green: 0.50, blue: 1.0, alpha: 1),
                                       CGColor(red: 0.20, green: 0.22, blue: 0.75, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])

    let c = CGPoint(x: s / 2, y: s / 2)
    let ring = rect.width * 0.30
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
    ctx.setLineWidth(rect.width * 0.025)
    ctx.strokeEllipse(in: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2))

    let petal = rect.width * 0.105
    for i in 0..<6 {
        let a = Double.pi / 2 + Double(i) * .pi / 3
        let p = CGPoint(x: c.x + cos(a) * ring, y: c.y + sin(a) * ring)
        ctx.setFillColor(CGColor(gray: 1, alpha: i == 0 ? 1 : 0.85))
        ctx.fillEllipse(in: CGRect(x: p.x - petal, y: p.y - petal, width: petal * 2, height: petal * 2))
    }
    let hub = rect.width * 0.14
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
    ctx.setFillColor(CGColor(red: 0.30, green: 0.34, blue: 0.9, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - hub * 0.4, y: c.y - hub * 0.4, width: hub * 0.8, height: hub * 0.8))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
