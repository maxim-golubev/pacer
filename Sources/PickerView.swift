import SwiftUI
import AppKit

struct PickerView: View {
    @EnvironmentObject var store: TargetStore
    @EnvironmentObject var engine: ThrottleEngine
    @Environment(\.dismiss) private var dismiss

    @State private var processes: [RunningProcess] = []
    @State private var search: String = ""
    @State private var selection: RunningProcess.ID?
    @State private var sortOrder: [KeyPathComparator<RunningProcess>] = [
        KeyPathComparator(\RunningProcess.cpu, order: .reverse)
    ]
    @State private var onlyUser: Bool = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = displayed
        VStack(spacing: 0) {
            toolbar
            Divider()
            table(rows)
            Divider()
            actionBar(rows)
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 360, idealHeight: 500)
        .task {
            // Bound to the window's lifetime — cancels automatically on close.
            NSApp.activate(ignoringOtherApps: true)
            searchFocused = true
            while !Task.isCancelled {
                processes = await ProcessLister.listAllAsync()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by name or path", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 16)
            Toggle("My processes only", isOn: $onlyUser)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Table

    private func table(_ rows: [RunningProcess]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { p in
                HStack(spacing: 6) {
                    Image(nsImage: icon(for: p))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(p.name).lineLimit(1)
                }
            }
            .width(min: 150, ideal: 220)

            TableColumn("PID", value: \.pid) { p in
                Text("\(p.pid)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(56)

            TableColumn("CPU %", value: \.cpu) { p in
                Text(String(format: "%.1f", p.cpu))
                    .monospacedDigit()
                    .foregroundStyle(cpuColor(p.cpu))
            }
            .width(66)

            TableColumn("Path", value: \.path) { p in
                Text(p.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: RunningProcess.ID.self) { ids in
            if let id = ids.first, let p = processes.first(where: { $0.id == id }) {
                Button("Set “\(p.name)” as Target") { commit(p) }
            }
        } primaryAction: { ids in
            // Double-clicking a row commits it.
            if let id = ids.first, let p = processes.first(where: { $0.id == id }) {
                commit(p)
            }
        }
    }

    // MARK: - Action bar

    private func actionBar(_ rows: [RunningProcess]) -> some View {
        HStack(spacing: 8) {
            Text("\(rows.count) process\(rows.count == 1 ? "" : "es")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let p = selectedProcess {
                Text("·").foregroundStyle(.secondary)
                Text("Selected: \(p.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Set as Target") {
                if let p = selectedProcess { commit(p) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedProcess == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Data

    private var displayed: [RunningProcess] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return processes
            .filter { p in
                if onlyUser, !p.isOwn { return false }
                if q.isEmpty { return true }
                return p.name.lowercased().contains(q)
                    || p.path.lowercased().contains(q)
            }
            .sorted(using: sortOrder)
    }

    private var selectedProcess: RunningProcess? {
        guard let id = selection else { return nil }
        return processes.first { $0.id == id }
    }

    private func commit(_ p: RunningProcess) {
        // Switching away? Release the old target first (resume + un-throttle)
        // so it isn't left in Eco / suspended with nothing tracking it.
        if store.hasTarget && store.targetPath != p.path {
            engine.releaseTarget()
        }
        store.setTarget(path: p.path, displayName: p.name)
        // Reuse the already-loaded list — no extra process scan needed.
        let pids = processes.filter { $0.path == p.path }.map(\.pid)
        engine.enforce(store.currentMode, on: pids)
        dismiss()
    }

    private func cpuColor(_ v: Double) -> Color {
        if v >= 100 { return .red }
        if v >= 25 { return .orange }
        return .secondary
    }

    /// Prefer the enclosing .app bundle icon; fall back to the file's own icon.
    private func icon(for p: RunningProcess) -> NSImage {
        var cursor = p.path
        while cursor != "/" && !cursor.isEmpty {
            if cursor.hasSuffix(".app") {
                return NSWorkspace.shared.icon(forFile: cursor)
            }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        return NSWorkspace.shared.icon(forFile: p.path)
    }
}
