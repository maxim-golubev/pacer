// Draws the README's menu animation off-screen with the app's own views: one
// frame per state, in light and dark, on GitHub's page colour.
//
//   swiftc -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
//       -framework ServiceManagement -o "$TMPDIR/pacer-menu" \
//       docs/images/main.swift $(ls Sources/*.swift | grep -v PacerApp)
//   "$TMPDIR/pacer-menu" "$TMPDIR/frames" && defaults delete pacer-menu
//   for t in light dark; do ffmpeg -y -framerate 10/13 -i "$TMPDIR/frames/$t-%02d.png" -filter_complex \
//       "split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=none" -loop 0 docs/images/menu-$t.gif; done
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
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    _ = NSApplication.shared

    let store = TargetStore.shared
    store.setTarget(path: "/usr/bin/java", displayName: "java")
    store.autoEnforce = true
    let engine = ThrottleEngine.shared
    engine.matchedPIDs = [4812]
    engine.isRunning = true

    // The states one tuning session walks through, with the CPU use measured
    // for each on an M3 Pro (see the README's table).
    let steps: [(Mode, Int, Double)] = [
        (.full, 70, 1012), (.balanced, 70, 451), (.balanced, 65, 381),
        (.balanced, 70, 451), (.eco, 70, 340),
    ]
    let themes: [(String, NSAppearance.Name, NSColor)] = [
        ("light", .aqua, .white),
        ("dark", .darkAqua, NSColor(srgbRed: 0x0d / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1)),
    ]

    for (theme, appearance, page) in themes {
        for (i, (mode, duty, cpu)) in steps.enumerated() {
            store.currentMode = mode
            store.balancedDutyPercent = duty
            engine.aggregateCPU = cpu

            let menu = MenuView()
                .environmentObject(store)
                .environmentObject(engine)
                .environment(\.controlActiveState, .key)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                .padding(14)
                .background(Color(nsColor: page))
            let host = NSHostingView(rootView: menu)
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            let window = FrontWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: out).appendingPathComponent(String(format: "%@-%02d.png", theme, i))
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
        }
    }
    print("wrote \(themes.count * steps.count) frames to \(out)")
}
