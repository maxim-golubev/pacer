import Foundation
import Darwin
import os.log

/// A thread-safe snapshot of the PIDs the Balanced duty-cycler has currently
/// SIGSTOP'd. It lives outside the `@MainActor` engine on purpose: if Pacer is
/// quitting, `applicationWillTerminate(_:)` runs synchronously on the main
/// thread and must be able to resume the target *without* hopping actors or
/// awaiting. Leaving the target frozen would be the one truly bad failure mode,
/// so this is the belt to the engine's braces.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    private var throttled: Set<pid_t> = []

    func track(_ p: Set<pid_t>) {
        lock.lock(); pids = p; lock.unlock()
    }

    /// Send SIGCONT to every tracked PID and clear the set. Safe to call from
    /// any thread, any number of times; SIGCONT to a running or dead PID is a
    /// harmless no-op.
    func resumeAll() {
        lock.lock(); let p = pids; pids = []; lock.unlock()
        for pid in p { kill(pid, SIGCONT) }
    }

    /// The PIDs Pacer currently holds in Eco (DARWIN_BG set).
    func trackThrottled(_ p: Set<pid_t>) {
        lock.lock(); throttled = p; lock.unlock()
    }

    /// Let go of the target completely: resume anything suspended and clear
    /// DARWIN_BG on anything Pacer put in Eco. Called on quit — a process
    /// nothing manages any more must not stay on E-cores until it restarts.
    /// Synchronous on purpose (see the type comment); taskpolicy returns in
    /// milliseconds. The next launch re-applies the saved mode.
    func releaseAll() {
        resumeAll()
        lock.lock(); let t = throttled; throttled = []; lock.unlock()
        guard !t.isEmpty else { return }
        for pid in t {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: taskpolicyPath)
            task.arguments = ["-B", "-p", "\(pid)"]
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { continue }
            task.waitUntilExit()
        }
        let pidList = t.sorted().map(String.init).joined(separator: ",")
        Logger(subsystem: "dev.maxim.pacer", category: "throttle")
            .notice("quit - set full on [\(pidList, privacy: .public)]")
    }
}

/// Absolute path to taskpolicy(8). It is a section-8 admin tool and lives
/// in /usr/sbin — /usr/bin is wrong. `Process` needs the literal path
/// (unlike the shell, it does not search $PATH). Resolved once.
private let taskpolicyPath: String = {
    ["/usr/sbin/taskpolicy", "/usr/bin/taskpolicy"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        ?? "/usr/sbin/taskpolicy"
}()

/// Shared instance — read by `AppDelegate.applicationWillTerminate`.
let pacerResumeGuard = ResumeGuard()

@MainActor
final class ThrottleEngine: ObservableObject {
    /// Unified-log channel for Pacer's apply events.
    /// View with: `log show --predicate 'subsystem == "dev.maxim.pacer"' --last 1h`
    private static let log = Logger(subsystem: "dev.maxim.pacer", category: "throttle")

    static let shared = ThrottleEngine()

    @Published var matchedPIDs: [pid_t] = []
    @Published var aggregateCPU: Double = 0
    @Published var isRunning: Bool = false
    @Published var lastApplyFailed: Bool = false
    /// False when the selected mode is *not* in effect on the running target:
    /// "Keep in the selected mode" is off and the target (re)started since the
    /// last manual apply. The menu says so rather than showing a mode that
    /// isn't actually applied.
    @Published var modeApplied: Bool = true

    private var watcher: Task<Void, Never>?
    private var menuOpenCount = 0
    private var ticking = false

    // Balanced-mode duty cycler. Non-nil only while Balanced is the active mode
    // and the target is running. `suspendedPIDs` mirrors `pacerResumeGuard` and
    // tracks which PIDs are currently SIGSTOP'd, so any exit path can resume
    // them. `didLaunchResume` makes the one-time, defensive launch resume fire
    // just once (in case a previous Pacer was killed mid-suspend).
    private var dutyCycler: Task<Void, Never>?
    private var suspendedPIDs: Set<pid_t> = []
    private var didLaunchResume = false
    /// Bumped on every duty-cycle start. A cancelled cycler's tail (its
    /// post-loop resume block) checks it and stands down if a newer cycler
    /// has taken over — otherwise it could SIGCONT mid-OFF-phase and wipe
    /// `suspendedPIDs` tracking that now belongs to its successor.
    private var cycleGen = 0

    // What the watcher has already enforced — so taskpolicy is only invoked
    // again when something actually changed (target restart, or mode change).
    private var enforcedMode: Mode?
    private var enforcedPIDs: Set<pid_t> = []

    // MARK: - Watcher lifecycle

    /// Start the background watcher. Safe to call once, at launch.
    func startWatching() {
        guard watcher == nil else { return }
        spawnWatcher()
    }

    /// The menu opened — switch to a fast cadence and refresh immediately.
    func menuAppeared() {
        menuOpenCount += 1
        Task { @MainActor [weak self] in await self?.tick() }
    }

    /// The menu closed.
    func menuDisappeared() {
        menuOpenCount = max(0, menuOpenCount - 1)
    }

    private func spawnWatcher() {
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // 1.5 s cadence while the menu is open, ~6 s otherwise. The
                // slow wait is chunked so an opening menu is noticed quickly.
                let chunks = (self?.menuOpenCount ?? 0) > 0 ? 1 : 4
                for _ in 0..<chunks {
                    try? await Task.sleep(for: .milliseconds(1500))
                    if Task.isCancelled { break }
                    if (self?.menuOpenCount ?? 0) > 0 { break }
                }
            }
        }
    }

    // MARK: - Manual mode application

    /// Apply a mode immediately (user-initiated) and record it as enforced.
    /// Surfaces failure via `lastApplyFailed` — a manual apply that fails
    /// usually means the chosen process can't be controlled (e.g. not ours).
    @discardableResult
    func enforce(_ mode: Mode, on pids: [pid_t]) -> Bool {
        let ok = apply(mode, to: pids, reason: "manual")
        lastApplyFailed = !pids.isEmpty && !ok
        enforcedMode = mode
        enforcedPIDs = Set(pids)
        // Adopt the PID set right away (don't wait up to a watcher period):
        // the duty cycler reads `matchedPIDs` live, so after a target switch
        // it must cycle the *new* target from the very next period.
        matchedPIDs = pids
        isRunning = !pids.isEmpty
        modeApplied = true
        reconcileDutyCycle(mode: mode, pids: pids)
        return ok
    }

    /// Stop managing the current target entirely: halt the duty cycle (which
    /// resumes anything suspended) and clear DARWIN_BG so the process isn't
    /// left throttled after Pacer lets go. Called when the user clears the
    /// target or switches to a different one — without this, an Eco'd old
    /// target would stay on E-cores forever with nothing tracking it.
    func releaseTarget() {
        stopDutyCycle()
        if !matchedPIDs.isEmpty {
            apply(.full, to: matchedPIDs, reason: "release")
        }
        enforcedMode = nil
        enforcedPIDs = []
        lastApplyFailed = false
        modeApplied = true
    }

    /// Apply a mode using a *fresh* PID scan. Use this from the menu — the
    /// watcher's cached `matchedPIDs` can be up to ~6 s stale, which would
    /// otherwise make a click against a just-restarted target a silent no-op.
    func enforce(_ mode: Mode) async {
        let path = TargetStore.shared.targetPath
        guard !path.isEmpty else {
            enforce(mode, on: [])
            return
        }
        let matches = await ProcessLister.listAllAsync().filter { $0.path == path }
        // The scan runs off the main actor, so the user can act while it's in
        // flight. If they've since picked another mode or target, this click
        // is stale — applying it now could land *after* the newer one.
        let store = TargetStore.shared
        guard store.targetPath == path, store.currentMode == mode else { return }
        let pids = matches.map(\.pid)
        matchedPIDs = pids
        aggregateCPU = matches.reduce(0.0) { $0 + $1.cpu }
        isRunning = !matches.isEmpty
        enforce(mode, on: pids)
    }

    // MARK: - Watcher tick

    private func tick() async {
        guard !ticking else { return }      // never overlap two scans
        ticking = true
        defer { ticking = false }

        let store = TargetStore.shared
        let path = store.targetPath
        guard !path.isEmpty else {
            matchedPIDs = []
            aggregateCPU = 0
            isRunning = false
            lastApplyFailed = false
            modeApplied = true
            enforcedMode = nil
            enforcedPIDs = []
            stopDutyCycle()                         // nothing to cycle
            return
        }

        let matches = await ProcessLister.listAllAsync().filter { $0.path == path }
        // The target can be cleared or switched while the scan is in flight.
        // These matches are then for the *old* target, which `releaseTarget()`
        // has just let go of — enforcing on them would throttle (or start
        // duty-cycling) a process nothing tracks any more. Drop the scan; the
        // next tick reads the new target.
        guard store.targetPath == path else { return }
        let pids = matches.map(\.pid)
        matchedPIDs = pids
        aggregateCPU = matches.reduce(0.0) { $0 + $1.cpu }
        isRunning = !matches.isEmpty
        if !isRunning {
            lastApplyFailed = false
            pacerResumeGuard.trackThrottled([])     // dead PIDs — nothing to restore
        }

        let mode = store.currentMode

        // Auto-enforcement: keep the target in the selected mode.
        if store.autoEnforce {
            let current = Set(pids)
            if mode != enforcedMode {
                enforcedPIDs = []                       // mode changed — re-apply
            }
            if !current.isEmpty, !current.subtracting(enforcedPIDs).isEmpty {
                // New (or first-seen) PIDs — the target just (re)started.
                let ok = apply(mode, to: pids, reason: "watcher")
                lastApplyFailed = !ok
                enforcedMode = mode
                enforcedPIDs = current
            } else {
                enforcedPIDs.formIntersection(current) // forget dead PIDs
            }
        }

        // Is the selected mode actually in effect? Always, with auto-enforce
        // on. With it off, a target that (re)started since the last manual
        // apply runs unmanaged — in *every* mode, Balanced included — until
        // the user clicks a mode. (Full needs no apply: it's the default.)
        let applied = pids.isEmpty || mode == .full
            || (enforcedMode == mode && Set(pids).isSubset(of: enforcedPIDs))
        modeApplied = applied

        // One-time defensive resume: a previous Pacer instance may have been
        // killed mid-suspend, leaving the target SIGSTOP'd. If we aren't the
        // one cycling it now, make sure it's actually running.
        if !didLaunchResume {
            didLaunchResume = true
            if !(mode == .balanced && applied) { signalAll(pids, SIGCONT) }
        }

        // Keep the Balanced duty-cycler in sync with the current mode and the
        // live PID set (picks up a relaunched target's new PID automatically).
        reconcileDutyCycle(mode: mode, pids: applied ? pids : [])
    }

    // MARK: - taskpolicy

    @discardableResult
    private func apply(_ mode: Mode, to pids: [pid_t], reason: String) -> Bool {
        guard !pids.isEmpty else { return false }
        // Eco demotes to E-cores; Full *and* Balanced both clear DARWIN_BG so
        // the process runs on performance cores at full clock. Balanced then
        // caps throughput on top of that by duty-cycling (see below), not via
        // taskpolicy — taskpolicy has no "use fewer cores" knob.
        let flag = (mode == .eco) ? "-b" : "-B"
        var failures: [pid_t] = []
        for pid in pids {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: taskpolicyPath)
            task.arguments = [flag, "-p", "\(pid)"]
            let errPipe = Pipe()
            task.standardError = errPipe
            do {
                try task.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    failures.append(pid)
                    let msg = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    Self.log.error("taskpolicy exited \(task.terminationStatus, privacy: .public) for pid \(pid, privacy: .public): \(msg, privacy: .public)")
                }
            } catch {
                failures.append(pid)
                Self.log.error("could not run taskpolicy for pid \(pid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Remember what's in Eco so quitting can restore it.
        pacerResumeGuard.trackThrottled(mode == .eco ? Set(pids).subtracting(failures) : [])
        let pidList = pids.map(String.init).joined(separator: ",")
        if failures.isEmpty {
            Self.log.notice("\(reason, privacy: .public) - set \(mode.rawValue, privacy: .public) on [\(pidList, privacy: .public)]")
        } else {
            let failList = failures.map(String.init).joined(separator: ",")
            Self.log.error("\(reason, privacy: .public) - set \(mode.rawValue, privacy: .public) on [\(pidList, privacy: .public)] FAILED for [\(failList, privacy: .public)]")
        }
        return failures.isEmpty
    }

    // MARK: - Balanced mode (duty cycle)
    //
    // taskpolicy can move work to E-cores (Eco) or clear that (Full), but it
    // cannot cap a process to "N cores at full clock" — and Apple Silicon has
    // no usable CPU-affinity API. So Balanced caps *average* CPU the only way
    // available to a live PID without root: run the process at full P-core
    // speed, but SIGSTOP/SIGCONT it on a fast cycle so it's only active for a
    // tunable fraction of each period. The die's thermal mass averages the
    // bursts, so the fans track the average — quiet, but every active slice is
    // full-speed P-core work (far more throughput per watt-second than Eco's
    // clock-locked E-cores).

    private func signalAll(_ pids: [pid_t], _ sig: Int32) {
        for pid in pids { kill(pid, sig) }
    }

    /// Record which PIDs are currently suspended, mirroring the set into the
    /// thread-safe `pacerResumeGuard` so app termination can resume them.
    private func setSuspended(_ pids: Set<pid_t>) {
        suspendedPIDs = pids
        pacerResumeGuard.track(pids)
    }

    /// Start or stop the duty cycler to match the active mode and PID set.
    private func reconcileDutyCycle(mode: Mode, pids: [pid_t]) {
        if mode == .balanced && !pids.isEmpty {
            startDutyCycle()
        } else {
            stopDutyCycle()
        }
    }

    /// Begin duty-cycling. The loop re-reads the live PID set and the duty /
    /// period settings every cycle, so a relaunched target or a tweaked duty
    /// knob is picked up within one period — no restart. Idempotent.
    private func startDutyCycle() {
        guard dutyCycler == nil else { return }
        Self.log.notice("balanced - duty cycle start")
        cycleGen += 1
        let gen = cycleGen
        dutyCycler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.cycleGen == gen else { return }
                let store = TargetStore.shared
                let pids = self.matchedPIDs
                let duty = max(5, min(95, store.balancedDutyPercent))
                let period = max(60, min(2000, store.balancedPeriodMillis))
                let onMs = max(1, Int((Double(period) * Double(duty) / 100.0).rounded()))
                let offMs = max(0, period - onMs)

                // ON phase: ensure the target is running at full speed. Resume
                // the union of the live set and whatever the previous OFF phase
                // suspended — if the PID set changed mid-cycle (target switch),
                // resuming only `pids` would orphan the old PID frozen.
                self.signalAll(Array(Set(pids).union(self.suspendedPIDs)), SIGCONT)
                self.setSuspended([])
                try? await Task.sleep(for: .milliseconds(onMs))
                // A cancellation lands here; never issue a fresh SIGSTOP after it.
                if Task.isCancelled { break }

                // OFF phase: suspend the whole process (draws ~no power).
                if offMs > 0 {
                    self.signalAll(pids, SIGSTOP)
                    self.setSuspended(Set(pids))
                    try? await Task.sleep(for: .milliseconds(offMs))
                }
            }
            // However the loop ends, never leave the target frozen — unless a
            // newer cycler owns the tracking now (it resumes on its first ON).
            if let self, self.cycleGen == gen {
                self.signalAll(Array(Set(self.matchedPIDs).union(self.suspendedPIDs)), SIGCONT)
                self.setSuspended([])
            }
        }
    }

    /// Stop duty-cycling and guarantee the target is resumed. Idempotent.
    private func stopDutyCycle() {
        let wasCycling = dutyCycler != nil
        dutyCycler?.cancel()
        dutyCycler = nil
        guard wasCycling || !suspendedPIDs.isEmpty else { return }
        let resume = Set(matchedPIDs).union(suspendedPIDs)
        for pid in resume { kill(pid, SIGCONT) }
        setSuspended([])
        if wasCycling { Self.log.notice("balanced - duty cycle stop") }
    }
}
