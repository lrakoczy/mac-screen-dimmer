import CoreGraphics
import Foundation
import os

/// Snapshot of the actual display state.
///
/// Measured macOS behavior: a built-in panel turned off with `CGSConfigureDisplayEnabled`
/// **stays online** (`CGGetOnlineDisplayList`) but reports `CGDisplayIsActive == false`.
/// With the lid closed the panel disappears from the online list entirely.
struct DisplaySnapshot: Equatable {
    /// ID of the built-in display if it is online (on, or turned off programmatically).
    let builtinID: CGDirectDisplayID?
    /// Whether the built-in display is active (showing an image).
    let builtinActive: Bool
    /// Active displays other than the built-in one.
    let externalIDs: [CGDirectDisplayID]

    var hasExternal: Bool { !externalIDs.isEmpty }
    /// Online but inactive = turned off programmatically (by us or another tool).
    var builtinInactive: Bool { builtinID != nil && !builtinActive }

    static func current() -> DisplaySnapshot {
        let empty = DisplaySnapshot(builtinID: nil, builtinActive: false, externalIDs: [])
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return empty }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count) + 8)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return empty }

        var builtin: CGDirectDisplayID?
        var builtinActive = false
        var external: [CGDirectDisplayID] = []
        for id in ids.prefix(Int(count)) {
            if CGDisplayIsBuiltin(id) != 0 {
                builtin = id
                builtinActive = CGDisplayIsActive(id) != 0
            } else if CGDisplayIsActive(id) != 0 {
                external.append(id)
            }
        }
        return DisplaySnapshot(builtinID: builtin, builtinActive: builtinActive, externalIDs: external)
    }
}

/// System layer – `DisplayAPI` in the app, a simulator in tests.
protocol DisplaySystem: AnyObject {
    var isSupported: Bool { get }
    var resolvedSymbolDescription: String? { get }
    func snapshot() -> DisplaySnapshot
    func setEnabled(_ display: CGDirectDisplayID, enabled: Bool) -> Result<Void, DisplayAPIError>
}

extension DisplayAPI: DisplaySystem {
    func snapshot() -> DisplaySnapshot { .current() }
}

/// State shown in the menu.
enum DisplayStatus: Equatable {
    case unsupported
    case noExternal
    case externalActive(count: Int)
    case builtinDisabled(externalCount: Int)
    case builtinUnavailable(externalCount: Int)
}

/// Toggle logic and fail-safe mechanisms. Public methods are called on the main thread.
///
/// Display configuration changes run on a separate serial queue: they can take seconds
/// (see `DisplayAPI.setEnabled`), and blocking the main thread would freeze the menu.
final class DisplayManager {
    private let log = Logger(subsystem: Log.subsystem, category: "DisplayManager")

    private let system: DisplaySystem
    private let prefs: Preferences
    private let worker = DispatchQueue(label: "local.ScreenDimmer.display-config")

    /// Called after every state change (menu refresh).
    var onChange: (() -> Void)?

    private(set) var snapshot: DisplaySnapshot
    private(set) var lastError: String?

    /// Last seen panel ID. IDs can change (e.g. GPU switching), so a fresh reading
    /// is always preferred and this is only a fallback.
    private var knownBuiltinID: CGDirectDisplayID?

    /// Panel is off (turned off by us or detected as off) – persisted immediately so the
    /// display can be restored on the next launch after a crash.
    private var disabledByUs: Bool {
        didSet { if prefs.disabledByUs != disabledByUs { prefs.disabledByUs = disabledByUs } }
    }

    /// The user turned the panel on manually while an external display is connected –
    /// auto-off must not turn it off again until the next connection.
    private var userOverride = false
    private var lastExternalCount = 0
    private var lastOwnChange = Date.distantPast
    /// Number of operations in flight and the target of the latest one (true = turning on).
    private var inFlight = 0
    private var pendingTarget: Bool?
    private var pendingAutoOff: DispatchWorkItem?
    private var pendingGraceRecheck: DispatchWorkItem?
    private var deferredAllowAutoOff = false
    private var lastLoggedStatus: String?

    /// For this long after our own change, trust the intended state rather than the snapshot (the system updates with a delay).
    private let ownChangeGrace: TimeInterval
    /// Settle delay before turning off automatically.
    private let autoOffDelay: TimeInterval

    init(system: DisplaySystem, prefs: Preferences,
         autoOffDelay: TimeInterval = 2.0, ownChangeGrace: TimeInterval = 1.5) {
        self.system = system
        self.prefs = prefs
        self.autoOffDelay = autoOffDelay
        self.ownChangeGrace = ownChangeGrace
        let snap = system.snapshot()
        self.snapshot = snap
        self.knownBuiltinID = snap.builtinID ?? prefs.builtinID
        self.disabledByUs = prefs.disabledByUs
        if let id = snap.builtinID { prefs.builtinID = id }
    }

    // MARK: - Public properties

    var isSupported: Bool { system.isSupported }
    var symbolDescription: String? { system.resolvedSymbolDescription }
    var isBusy: Bool { inFlight > 0 }

    private var inGrace: Bool {
        inFlight > 0 || Date().timeIntervalSince(lastOwnChange) < ownChangeGrace
    }

    /// Whether the built-in display is (programmatically) off – derived from the system state,
    /// or from the intended state during / right after our own operation.
    var isBuiltinDisabled: Bool {
        if inGrace { return disabledByUs }
        return snapshot.builtinInactive || (snapshot.builtinID == nil && disabledByUs)
    }

    var autoOff: Bool {
        get { prefs.autoOff }
        set {
            prefs.autoOff = newValue
            if !newValue { cancelAutoOff() }
            publish()
        }
    }

    var status: DisplayStatus {
        if !system.isSupported { return .unsupported }
        let ext = snapshot.externalIDs.count
        if isBuiltinDisabled { return .builtinDisabled(externalCount: ext) }
        if snapshot.builtinID == nil { return .builtinUnavailable(externalCount: ext) }
        return ext == 0 ? .noExternal : .externalActive(count: ext)
    }

    var canDisable: Bool {
        system.isSupported && !isBuiltinDisabled && snapshot.builtinID != nil && snapshot.hasExternal
    }

    var canEnable: Bool {
        system.isSupported && isBuiltinDisabled && (snapshot.builtinID ?? knownBuiltinID) != nil
    }

    // MARK: - Launch / recovery

    /// Recovery after a crash / `kill -9` (or a panel turned off by another tool): restore the display on launch.
    func recoverOnLaunch() {
        snapshot = system.snapshot()
        if disabledByUs || snapshot.builtinInactive {
            log.notice("Launch recovery: restoring the built-in display")
            disabledByUs = true
            enable(reason: "launch recovery")
        }
        reconcile(reason: "launch", allowAutoOff: true)
    }

    // MARK: - User actions

    func userToggle() {
        snapshot = system.snapshot()
        if isBuiltinDisabled {
            userOverride = snapshot.hasExternal
            enable(reason: "user")
        } else {
            userOverride = false
            disable(reason: "user")
        }
        publish()
    }

    /// Restore on app exit – synchronous (call after unregistering the event callback).
    func restoreForExit() {
        cancelAutoOff()
        snapshot = system.snapshot()
        if disabledByUs || snapshot.builtinInactive || pendingTarget == false {
            enable(reason: "app exit", synchronous: true)
        }
    }

    // MARK: - Event handling

    /// Fast safety path – called immediately on every event, without debouncing.
    func failSafeCheck() {
        let snap = system.snapshot()
        guard !snap.hasExternal, disabledByUs || snap.builtinInactive, pendingTarget != true else { return }
        log.notice("No external display while the panel is off – restoring immediately")
        snapshot = snap
        enable(reason: "external display disconnected")
        publish()
    }

    /// Full synchronization of the app state with reality.
    func reconcile(reason: String, allowAutoOff: Bool = false) {
        let snap = system.snapshot()
        snapshot = snap

        if let id = snap.builtinID {
            knownBuiltinID = id
            prefs.builtinID = id
            if inGrace {
                deferredAllowAutoOff = deferredAllowAutoOff || allowAutoOff
                scheduleGraceRecheck()
            } else if snap.builtinActive && disabledByUs {
                log.notice("Built-in display active again without the app – syncing state")
                disabledByUs = false
            } else if !snap.builtinActive && !disabledByUs {
                log.notice("Built-in display turned off externally – syncing state")
                disabledByUs = true
            }
        }

        let ext = snap.externalIDs.count

        // Fail-safe: never leave the panel off without an external display.
        if ext == 0 && (disabledByUs || snap.builtinInactive) {
            enable(reason: "no external display")
        }

        if ext == 0 {
            userOverride = false
            cancelAutoOff()
        }

        let newlyConnected = ext > 0 && lastExternalCount == 0
        if prefs.autoOff && (newlyConnected || allowAutoOff) && canDisable && !userOverride {
            scheduleAutoOff()
        }

        lastExternalCount = ext
        publish()
    }

    // MARK: - Implementation

    private func publish() {
        let line = "state=\(status) off=\(isBuiltinDisabled) panel=\(snapshot.builtinID.map(String.init) ?? "-")/\(snapshot.builtinActive ? "active" : "inactive") external=\(snapshot.externalIDs.count) autoOff=\(prefs.autoOff) inFlight=\(inFlight)"
        if line != lastLoggedStatus {
            lastLoggedStatus = line
            log.notice("\(line, privacy: .public)")
        }
        onChange?()
    }

    /// Applies the change on the worker queue; `completion` runs on the main thread.
    private func apply(_ id: CGDirectDisplayID, enabled: Bool, synchronous: Bool = false,
                       completion: @escaping (Result<Void, DisplayAPIError>) -> Void) {
        inFlight += 1
        pendingTarget = enabled
        lastOwnChange = Date()
        let system = self.system
        let finish: (Result<Void, DisplayAPIError>) -> Void = { [weak self] result in
            guard let self else { return }
            self.inFlight -= 1
            if self.inFlight == 0 { self.pendingTarget = nil }
            self.lastOwnChange = Date()
            completion(result)
            self.snapshot = self.system.snapshot()
            self.publish()
        }
        if synchronous {
            finish(worker.sync { system.setEnabled(id, enabled: enabled) })
        } else {
            worker.async {
                let result = system.setEnabled(id, enabled: enabled)
                DispatchQueue.main.async { finish(result) }
            }
        }
    }

    private func disable(reason: String) {
        guard pendingTarget != false else { return }   // turning off already in progress
        let snap = system.snapshot()
        snapshot = snap
        guard snap.hasExternal else {
            lastError = L("error.noExternal", "Cannot turn off – no external display connected")
            log.notice("Refusing to turn off: no external display")
            return
        }
        guard let id = snap.builtinID, snap.builtinActive else {
            lastError = L("error.builtinUnavailable", "The built-in display is unavailable")
            return
        }
        knownBuiltinID = id
        prefs.builtinID = id

        // Persist the intent BEFORE the call – if the process dies midway, launch recovery still works.
        disabledByUs = true
        apply(id, enabled: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.lastError = nil
                self.log.notice("Turned off built-in display \(id) (\(reason, privacy: .public))")
                // The external display may have disappeared during the operation – check right away.
                self.failSafeCheck()
            case .failure(let err):
                if self.pendingTarget == nil { self.disabledByUs = false }
                self.lastOwnChange = .distantPast
                self.lastError = err.description
                self.log.error("Turning off failed: \(err.description, privacy: .public)")
            }
        }
    }

    private func enable(reason: String, synchronous: Bool = false) {
        cancelAutoOff()
        guard synchronous || pendingTarget != true else { return }   // turning on already in progress
        // Always use a fresh ID – the remembered one may be stale.
        let fresh = system.snapshot()
        guard let id = fresh.builtinID ?? knownBuiltinID ?? prefs.builtinID else {
            lastError = L("error.unknownBuiltinID", "Unknown built-in display identifier")
            log.error("No built-in display ID – cannot restore")
            return
        }
        apply(id, enabled: true, synchronous: synchronous) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.pendingTarget == nil { self.disabledByUs = false }
                self.lastError = nil
                self.log.notice("Restored built-in display \(id) (\(reason, privacy: .public))")
            case .failure(let err):
                self.lastOwnChange = .distantPast
                self.lastError = err.description
                self.log.error("Restoring failed: \(err.description, privacy: .public)")
            }
        }
    }

    private func scheduleAutoOff() {
        guard pendingAutoOff == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingAutoOff = nil
            self.snapshot = self.system.snapshot()
            guard self.prefs.autoOff, !self.userOverride, self.canDisable else { return }
            self.disable(reason: "auto-off")
            self.publish()
        }
        pendingAutoOff = item
        log.notice("Auto-off scheduled in \(self.autoOffDelay, privacy: .public) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + autoOffDelay, execute: item)
    }

    private func cancelAutoOff() {
        pendingAutoOff?.cancel()
        pendingAutoOff = nil
    }

    private func scheduleGraceRecheck() {
        pendingGraceRecheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingGraceRecheck = nil
            let allow = self.deferredAllowAutoOff
            self.deferredAllowAutoOff = false
            self.reconcile(reason: "after grace period", allowAutoOff: allow)
        }
        pendingGraceRecheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ownChangeGrace + 0.25, execute: item)
    }
}
