import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: Log.subsystem, category: "App")

    private let api = DisplayAPI(useHelper: true)
    private let prefs = Preferences()
    private lazy var manager = DisplayManager(system: api, prefs: prefs)
    private let events = DisplayEventMonitor()
    private var menuController: StatusMenuController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()

        menuController = StatusMenuController(
            manager: manager,
            loginItem: LoginItemController(service: SystemLoginItemService())
        ) { NSApp.terminate(nil) }
        manager.onChange = { [weak self] in self?.menuController?.refresh() }

        events.onImmediate = { [weak self] in self?.manager.failSafeCheck() }
        events.onSettled = { [weak self] reason, allowAutoOff in
            self?.manager.reconcile(reason: reason, allowAutoOff: allowAutoOff)
        }
        events.start()

        logEnvironment()
        // First recover from a possible crash of a previous instance, then sync normally.
        manager.recoverOnLaunch()
        log.info("Launched. API supported: \(self.api.isSupported)")
    }

    /// Everything a bug report needs about this machine, in one log line.
    private func logEnvironment() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString   // "Version 14.8 (Build 23J631)"
            .replacingOccurrences(of: "Version ", with: "")
        let defaults = prefs.diagnosticDescription
        log.notice("ScreenDimmer \(version, privacy: .public) (\(build, privacy: .public)) on macOS \(os, privacy: .public), \(Self.hardwareModel(), privacy: .public) \(Self.architecture, privacy: .public); API: \(self.api.resolvedSymbolDescription ?? "unsupported", privacy: .public); prefs: \(defaults, privacy: .public)")
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown model" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown model" }
        return String(cString: buf)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    private func shutdown() {
        events.stop()
        manager.restoreForExit()
    }

    /// SIGTERM (e.g. `kill`, logout), SIGINT (Ctrl+C in a terminal), SIGHUP – restore the display and quit.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.log.notice("Received signal \(sig) – restoring the display and quitting")
                self?.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        // SIGUSR1 – toggle the built-in display (same as the menu item); for tests and scripts: `pkill -USR1 ScreenDimmer`.
        signal(SIGUSR1, SIG_IGN)
        let toggle = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        toggle.setEventHandler { [weak self] in
            self?.log.notice("SIGUSR1 – toggling the built-in display")
            self?.manager.userToggle()
        }
        toggle.resume()
        signalSources.append(toggle)

        // SIGUSR2 – write the full state and display list to the log: `pkill -USR2 ScreenDimmer`.
        signal(SIGUSR2, SIG_IGN)
        let dump = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        dump.setEventHandler { [weak self] in
            self?.logEnvironment()
            self?.manager.logDiagnostics()
        }
        dump.resume()
        signalSources.append(dump)
    }
}
