import Cocoa

// Reuse the pet's simple geometry and colors for a native, scalable app icon.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let mint = NSColor(calibratedRed: 0.65, green: 0.94, blue: 0.82, alpha: 1)
        let ink = NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.14, alpha: 1)
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat, _ color: NSColor) {
            color.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
        }
        box(64, 64, 896, 896, 205, ink)
        box(489, 697, 46, 98, 23, mint)
        mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 474, y: 773, width: 76, height: 76)).fill()
        box(218, 398, 72, 143, 36, mint); box(734, 398, 72, 143, 36, mint)
        box(339, 221, 113, 103, 43, mint); box(572, 221, 113, 103, 43, mint)
        box(264, 288, 496, 433, 134, mint)
        box(324, 383, 376, 235, 88, ink)
        box(416, 451, 42, 91, 21, mint); box(566, 451, 42, 91, 21, mint)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
