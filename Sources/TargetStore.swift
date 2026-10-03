import Foundation
import SwiftUI
import ServiceManagement

enum Mode: String, CaseIterable, Identifiable {
    case full
    case balanced
    case eco

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .full:     return "Full power"
        case .balanced: return "Balanced"
        case .eco:      return "Eco (E-cores)"
        }
    }
    var systemImage: String {
        switch self {
        case .full:     return "bolt.fill"
        case .balanced: return "speedometer"
        case .eco:      return "leaf.fill"
        }
    }
    var tint: Color {
        switch self {
        case .full:     return .yellow
        case .balanced: return .orange
        case .eco:      return .green
        }
    }
    var subtitle: String {
        switch self {
        case .full:     return "Performance cores, normal speed"
        case .balanced: return "Full-speed bursts, capped for quiet"
        case .eco:      return "Efficiency cores, cooler & quieter"
        }
    }
    var help: String {
        switch self {
        case .full:     return "Normal scheduling — the process runs on performance cores at full speed."
        case .balanced: return "Performance cores at full speed, but the process is rapidly suspended and resumed to cap its average CPU. Quieter than Full power and much faster than Eco for the same fan noise. Use the duty control to trade speed against quiet."
        case .eco:      return "Background QoS — macOS moves the process onto efficiency cores. Slower, but much cooler and quieter."
        }
    }
}

@MainActor
final class TargetStore: ObservableObject {
    static let shared = TargetStore()

    @AppStorage("targetPath") var targetPath: String = ""
    @AppStorage("targetDisplayName") var targetDisplayName: String = ""
    @AppStorage("currentModeRaw") private var modeRaw: String = Mode.full.rawValue
    @AppStorage("autoEnforce") var autoEnforce: Bool = true

    // Balanced-mode duty cycle. `balancedDutyPercent` is the fraction of each
    // period the target is allowed to run (the rest it's SIGSTOP'd, drawing
    // ~no power). The duty cycler re-reads these every cycle, so the in-app
    // ± stepper retunes a running target within one period. (An external
    // `defaults write` is NOT reliably picked up by the running app — treat it
    // as a launch-time value, not a live knob; use the stepper to tune live.)
    // Default 70 % ≈ ~25 W / ~2000 RPM on an M3 Pro under a ~10-core Java
    // batch: quiet across the room. The fan curve is steep just above it.
    @AppStorage("balancedDutyPercent") var balancedDutyPercent: Int = 70
    @AppStorage("balancedPeriodMillis") var balancedPeriodMillis: Int = 250

    var hasTarget: Bool { !targetPath.isEmpty }

    var currentMode: Mode {
        get { Mode(rawValue: modeRaw) ?? .full }
        set { modeRaw = newValue.rawValue; objectWillChange.send() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                objectWillChange.send()
            } catch {
                NSLog("Pacer: launch-at-login toggle failed: \(error)")
            }
        }
    }

    func setTarget(path: String, displayName: String) {
        targetPath = path
        targetDisplayName = displayName
        objectWillChange.send()
    }

    func clearTarget() {
        targetPath = ""
        targetDisplayName = ""
        objectWillChange.send()
    }
}
