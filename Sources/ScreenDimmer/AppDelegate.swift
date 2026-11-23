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

        menuController = StatusMenuController(manager: manager) { NSApp.terminate(nil) }
        manager.onChange = { [weak self] in self?.menuController?.refresh() }

        events.onImmediate = { [weak self] in self?.manager.failSafeCheck() }
        events.onSettled = { [weak self] reason, allowAutoOff in
            self?.manager.reconcile(reason: reason, allowAutoOff: allowAutoOff)
        }
        events.start()

        // First recover from a possible crash of a previous instance, then sync normally.
        manager.recoverOnLaunch()
        log.info("Launched. API supported: \(self.api.isSupported)")
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
    }
}
