// Draws the Pacer menu off-screen with the app's own views, in light and dark.
//
//   swiftc -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
//       -framework ServiceManagement -o /tmp/pacer-menu \
//       docs/images/main.swift $(ls Sources/*.swift | grep -v PacerApp)
//   /tmp/pacer-menu docs/images && defaults delete pacer-menu
import AppKit
import SwiftUI

enum WindowID { static let picker = "picker" }

/// Off-screen, but drawn as the frontmost window (controls in their active colours).
final class FrontWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

MainActor.assumeIsolated {
    let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
    _ = NSApplication.shared

    let store = TargetStore.shared
    store.setTarget(path: "/usr/bin/java", displayName: "java")
    store.currentMode = .balanced
    store.balancedDutyPercent = 70
    store.autoEnforce = true

    let engine = ThrottleEngine.shared
    engine.matchedPIDs = [4812]
    engine.aggregateCPU = 451
    engine.isRunning = true

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let menu = MenuView()
            .environmentObject(store)
            .environmentObject(engine)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        let host = NSHostingView(rootView: menu)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = FrontWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: out).appendingPathComponent("menu-\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote \(url.path) \(Int(size.width))x\(Int(size.height))")
    }
}
