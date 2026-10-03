import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject var store: TargetStore
    @EnvironmentObject var engine: ThrottleEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider

            if store.hasTarget {
                ForEach(Mode.allCases) { mode in
                    // While Balanced is active, render `BalancedRow`, which
                    // carries the duty ± control inline on the right. It's the
                    // same height as a plain mode row, so switching modes never
                    // resizes the menu window (see the note on `body`).
                    if mode == .balanced && store.currentMode == .balanced {
                        BalancedRow()
                    } else {
                        ModeRowView(mode: mode, isActive: store.currentMode == mode) {
                            select(mode)
                        }
                    }
                }
                divider
            }

            MenuActionRow(
                icon: "rectangle.stack",
                title: store.hasTarget ? "Change Target…" : "Choose a Target…"
            ) {
                openWindow(id: WindowID.picker)
                NSApp.activate(ignoringOtherApps: true)
            }

            if store.hasTarget {
                MenuActionRow(icon: "xmark.circle", title: "Clear Target") {
                    engine.releaseTarget()      // un-throttle before forgetting
                    store.clearTarget()
                }
            }

            divider
            footerToggles
            divider

            MenuActionRow(icon: "info.circle", title: "About Pacer") { showAbout() }
            MenuActionRow(icon: "power", title: "Quit Pacer") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        // The inline BalancedRow keeps every mode row the same height, so the
        // menu window never resizes on a mode switch — that constant height is
        // the real flicker fix. This just belt-and-suspenders the swap between
        // BalancedRow and ModeRowView so it can't pick up a transition.
        .animation(nil, value: store.currentMode)
        .onAppear { engine.menuAppeared() }
        .onDisappear { engine.menuDisappeared() }
    }

    /// Switch modes without an implicit transition on the row swap (see `body`).
    private func select(_ mode: Mode) {
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) { store.currentMode = mode }
        Task { await engine.enforce(mode) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.hasTarget {
                Text(store.targetDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    if engine.isRunning, let pid = engine.matchedPIDs.first {
                        Text(verbatim: "PID \(pid)")   // verbatim: no "56,936" grouping
                            .font(.caption).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                        Text(String(format: "%.0f%% CPU", engine.aggregateCPU))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("Not running")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if engine.isRunning && engine.lastApplyFailed {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Last mode change didn’t apply")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                } else if engine.isRunning && !engine.modeApplied {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.orange)
                        Text("Restarted at full power — click a mode to apply")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            } else {
                Text("Pacer")
                    .font(.headline)
                Text("No target selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Footer toggles

    private var footerToggles: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuToggleRow(
                icon: "pin.fill",
                title: "Keep in the selected mode",
                subtitle: "Re-applied on every restart",
                help: "Pacer watches your target and automatically re-applies the selected mode whenever it starts or restarts — so an overnight run stays in Eco even if it relaunches. Turn off to change modes only by hand.",
                isOn: Binding(get: { store.autoEnforce },
                              set: { store.autoEnforce = $0 })
            )
            MenuToggleRow(
                icon: "sunrise.fill",
                title: "Launch Pacer at login",
                subtitle: "Adds Pacer to your login items",
                help: "Start Pacer automatically when you log in to macOS.",
                isOn: Binding(get: { store.launchAtLogin },
                              set: { store.launchAtLogin = $0 })
            )
        }
    }

    private var divider: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 5)
    }

    // MARK: - About

    private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let alert = NSAlert()
        alert.messageText = "Pacer \(version)"
        alert.informativeText = """
        Pin a chosen process to performance cores (Full power), efficiency \
        cores (Eco), or a quiet duty-capped middle gear (Balanced) on Apple \
        Silicon.

        Uses taskpolicy(8) and process suspend/resume — no sudo, no kernel \
        extensions.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Reusable rows

/// A menu row with a hover highlight, matching native menu feel.
struct MenuActionRow: View {
    let icon: String
    let title: String
    var tint: Color = .secondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

/// A mode row: hover highlight, plus a persistent tinted background and
/// checkmark when active. Always interactive — selecting a mode while the
/// target is stopped just saves the preference for the next launch.
struct ModeRowView: View {
    let mode: Mode
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(isActive ? mode.tint : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.displayName)
                        .foregroundStyle(.primary)
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(mode.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mode.help)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    private var backgroundColor: Color {
        if isActive {
            return mode.tint.opacity(hovering ? 0.26 : 0.16)
        }
        return hovering ? Color.primary.opacity(0.09) : Color.clear
    }
}

/// The Balanced row with its duty `− % +` control inline on the right (where
/// the checkmark sits on the other modes), shown in place of the plain row while
/// Balanced is active. Critically it's the *same height* as any other mode row —
/// so switching modes never resizes the menu window, which is what was causing
/// the collapse flicker. The hint lives in the tooltip. The engine re-reads
/// `balancedDutyPercent` every cycle, so ± retunes the running target live.
struct BalancedRow: View {
    @EnvironmentObject var store: TargetStore
    @EnvironmentObject var engine: ThrottleEngine
    @State private var hovering = false

    private static let minDuty = 10
    private static let maxDuty = 95
    private static let step = 5
    private var duty: Int { store.balancedDutyPercent }

    private func adjust(_ delta: Int) {
        store.balancedDutyPercent = max(Self.minDuty, min(Self.maxDuty, duty + delta))
    }

    private func reselect() {
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) { store.currentMode = .balanced }
        Task { await engine.enforce(.balanced) }
    }

    var body: some View {
        HStack(spacing: 11) {
            // Left: same icon/title/subtitle as a mode row, tappable to re-apply.
            Button(action: reselect) {
                HStack(spacing: 11) {
                    Image(systemName: Mode.balanced.systemImage)
                        .font(.system(size: 15)).frame(width: 22)
                        .foregroundStyle(Mode.balanced.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Mode.balanced.displayName).foregroundStyle(.primary)
                        // Shorter than the inactive row's subtitle, to leave room
                        // for the inline stepper without truncating.
                        Text("Capped for quiet").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Right: the duty stepper — independent buttons (siblings, not nested
            // in the row button), where the checkmark would be on other rows.
            HStack(spacing: 7) {
                stepButton("minus.circle.fill", enabled: duty > Self.minDuty) { adjust(-Self.step) }
                Text("\(duty)%")
                    .font(.callout.weight(.semibold)).monospacedDigit().frame(width: 44)
                stepButton("plus.circle.fill", enabled: duty < Self.maxDuty) { adjust(Self.step) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Mode.balanced.tint.opacity(hovering ? 0.26 : 0.16))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
        .help("Balanced runs the process at full speed but briefly pauses it part of each cycle to cap heat. Duty = the fraction of time it runs — lower for quieter, higher for faster.")
    }

    private func stepButton(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(enabled ? Color.orange : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A toggle row styled to match the mode rows above — leading icon, title +
/// subtitle, trailing switch. The whole row is the hit target and carries a
/// hover highlight; the switch is a non-interactive state indicator, so a
/// click anywhere on the row flips it (and never double-fires). No persistent
/// tint when on — unlike the single-select mode rows, the switch already
/// carries the state — but the icon picks up the accent colour to echo it.
struct MenuToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let help: String
    @Binding var isOn: Bool

    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .allowsHitTesting(false)   // the row is the hit target
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }
}
