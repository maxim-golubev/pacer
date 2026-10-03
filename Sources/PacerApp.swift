import SwiftUI
import AppKit

enum WindowID {
    static let picker = "picker"
}

@main
struct PacerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TargetStore.shared
    @StateObject private var engine = ThrottleEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
                .environmentObject(engine)
        } label: {
            Image(nsImage: Self.menuBarIcon(for: store.currentMode))
        }
        .menuBarExtraStyle(.window)

        Window("Choose a Target Process", id: WindowID.picker) {
            PickerView()
                .environmentObject(store)
                .environmentObject(engine)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 500)
        .defaultPosition(.center)
    }

    /// One gauge template per mode — the needle position is the mode
    /// indicator (Full ≈ 97 %, Balanced 70 %, Eco 20 %). The label closure
    /// reads `store.currentMode`, so a mode change re-renders the label and
    /// swaps the image. Main-thread only (SwiftUI scene body).
    private static var menuBarIcons: [Mode: NSImage] = [:]
    private static func menuBarIcon(for mode: Mode) -> NSImage {
        if let cached = menuBarIcons[mode] { return cached }
        let img = NSImage(named: "MenuBarIcon\(mode.rawValue.capitalized)Template")
            ?? NSImage(systemSymbolName: "gauge.high", accessibilityDescription: "Pacer")!
        img.isTemplate = true
        img.size = NSSize(width: 20, height: 20)
        menuBarIcons[mode] = img
        return img
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The watcher keeps the target in its mode and re-applies on the
        // target's (re)start — including one that's already running now.
        Task { @MainActor in
            ThrottleEngine.shared.startWatching()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting lets go of the target: resume it if Balanced had it
        // SIGSTOP'd mid-cycle, and lift Eco — synchronously, on the main
        // thread, no actor hop — so it's never left frozen or stuck on
        // E-cores with nothing managing it. Harmless no-op otherwise.
        pacerResumeGuard.releaseAll()
    }
}
