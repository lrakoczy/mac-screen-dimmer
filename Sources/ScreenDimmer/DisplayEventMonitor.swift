import AppKit
import CoreGraphics
import os

/// Listens for display reconfiguration and wake events, debouncing bursts of events.
final class DisplayEventMonitor {
    private let log = Logger(subsystem: Log.subsystem, category: "Events")

    /// Called immediately on every event (safety path).
    var onImmediate: (() -> Void)?
    /// Called once a burst of events has settled. Parameter: whether auto-off is allowed (e.g. after wake).
    var onSettled: ((_ reason: String, _ allowAutoOff: Bool) -> Void)?

    private let debounceInterval: TimeInterval = 0.75
    private var pending: DispatchWorkItem?
    private var pendingAllowsAutoOff = false
    private var registered = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !registered else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let err = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, ctx)
        registered = (err == .success)
        if !registered { log.error("Registering the reconfiguration callback failed: \(err.rawValue)") }

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handle(reason: "wake", allowAutoOff: true)
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handle(reason: "screen parameters changed", allowAutoOff: false)
        })
    }

    func stop() {
        if registered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback,
                                                   Unmanaged.passUnretained(self).toOpaque())
            registered = false
        }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0)
                            NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pending?.cancel()
        pending = nil
    }

    fileprivate func handleReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        // Notice level: unlike debug/info it is persisted, so `log show` still has it after the fact.
        log.notice("Display event #\(display) \(Self.describe(flags), privacy: .public) \(Self.stateDescription(display, flags: flags), privacy: .public)")
        handle(reason: "display reconfiguration", allowAutoOff: false)
    }

    /// State of the display when the event is handled. For a display that is gone, CoreGraphics
    /// answers with another display's properties (seen in issue #3: a removed monitor reported
    /// `builtin=true online=true`), so only `online=false` is logged then.
    static func stateDescription(_ display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) -> String {
        guard !flags.contains(.removeFlag), CGDisplayIsOnline(display) != 0 else { return "online=false" }
        return "builtin=\(CGDisplayIsBuiltin(display) != 0) online=true active=\(CGDisplayIsActive(display) != 0)"
    }

    /// Human-readable flag names, e.g. `[add,enabled]`.
    static func describe(_ flags: CGDisplayChangeSummaryFlags) -> String {
        let names: [(CGDisplayChangeSummaryFlags, String)] = [
            (.beginConfigurationFlag, "begin"), (.movedFlag, "moved"), (.setMainFlag, "setMain"),
            (.setModeFlag, "setMode"), (.addFlag, "add"), (.removeFlag, "remove"),
            (.enabledFlag, "enabled"), (.disabledFlag, "disabled"), (.mirrorFlag, "mirror"),
            (.unMirrorFlag, "unMirror"), (.desktopShapeChangedFlag, "desktopShapeChanged"),
        ]
        var known: CGDisplayChangeSummaryFlags = []
        var parts: [String] = []
        for (flag, name) in names where flags.contains(flag) {
            parts.append(name)
            known.insert(flag)
        }
        let rest = flags.rawValue & ~known.rawValue
        if rest != 0 { parts.append(String(format: "0x%X", rest)) }
        return "[" + parts.joined(separator: ",") + "]"
    }

    private func handle(reason: String, allowAutoOff: Bool) {
        if reason == "wake" { log.notice("Wake event") }
        onImmediate?()

        // Debounce: coalesce a burst of events (cable, input switching, wake) into a single reaction.
        pendingAllowsAutoOff = pendingAllowsAutoOff || allowAutoOff
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let allow = self.pendingAllowsAutoOff
            self.pendingAllowsAutoOff = false
            self.pending = nil
            self.onSettled?(reason, allow)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}

private func displayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    // The first call (beginConfiguration) arrives BEFORE the change – the state is not updated yet.
    if flags.contains(.beginConfigurationFlag) { return }
    guard let userInfo else { return }
    let monitor = Unmanaged<DisplayEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.handleReconfiguration(display: display, flags: flags)
    }
}
