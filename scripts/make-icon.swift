// Renders Support/AppIcon.icns: a rounded gradient tile with a white "click" cursor.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: the tile is 824 pt inside a 1024 pt canvas, leaving room for the shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.36, green: 0.30, blue: 0.98, alpha: 1),
        NSColor(red: 0.62, green: 0.25, blue: 0.93, alpha: 1),
    ])!.draw(in: path, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let origin = NSPoint(x: tile.midX - symbolSize.width / 2 + 10, y: tile.midY - symbolSize.height / 2 - 10)
        symbol.draw(in: NSRect(origin: origin, size: symbolSize))
    }
    return true
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
