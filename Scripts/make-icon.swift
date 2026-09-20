import AppKit

// Product icon built from Apple's system symbol, without external image assets.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/FreeHand.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels).insetBy(dx: CGFloat(pixels) * 0.06, dy: CGFloat(pixels) * 0.06)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: CGFloat(pixels) * 0.2, yRadius: CGFloat(pixels) * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.62, blue: 0.48, alpha: 1),
                   ending: NSColor(calibratedRed: 0.08, green: 0.31, blue: 0.25, alpha: 1))!.draw(in: shape, angle: -60)
        if let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.50, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.white])) {
            symbol.draw(in: CGRect(x: CGFloat(pixels) * 0.23, y: CGFloat(pixels) * 0.22, width: CGFloat(pixels) * 0.54, height: CGFloat(pixels) * 0.56))
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
