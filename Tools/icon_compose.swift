// Places a rendered icon tile on Apple's macOS icon grid with the system's drop shadow.
// Usage: icon_compose <tile.png> <output.png> <pixels> <tile-units-of-1024>
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let tile = NSImage(contentsOfFile: args[1]), let pixels = Int(args[3]), let tileUnits = Double(args[4]) else {
    FileHandle.standardError.write("usage: icon_compose tile.png out.png pixels tile-units\n".data(using: .utf8)!)
    exit(2)
}
// Apple's grid: a 1024-unit canvas, the tile 824 units, raised slightly above its shadow
let canvas = 1024.0, lift = 10.0
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: pixels, height: pixels)
let scale = Double(pixels) / canvas
let margin = (canvas - tileUnits) / 2 * scale
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
shadow.shadowOffset = NSSize(width: 0, height: -lift * scale)
shadow.shadowBlurRadius = 24 * scale
shadow.set()
tile.draw(in: NSRect(x: margin, y: margin + lift * scale, width: tileUnits * scale, height: tileUnits * scale),
          from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
