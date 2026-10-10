import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.07, green: 0.36, blue: 0.33, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.04, y: p * 0.04, width: p * 0.92, height: p * 0.92), xRadius: p * 0.21, yRadius: p * 0.21).fill()
        for index in 0..<3 {
            let y = p * (0.31 + CGFloat(index) * 0.18)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: p * 0.19, y: y))
            path.curve(to: NSPoint(x: p * 0.81, y: y), controlPoint1: NSPoint(x: p * 0.39, y: y + p * 0.24), controlPoint2: NSPoint(x: p * 0.61, y: y - p * 0.24))
            path.lineWidth = p * 0.065; path.lineCapStyle = .round
            NSColor(calibratedRed: 0.77, green: 0.96, blue: 0.88, alpha: 1 - CGFloat(index) * 0.17).setStroke()
            path.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
