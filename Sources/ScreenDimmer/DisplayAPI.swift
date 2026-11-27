import CoreGraphics
import Darwin
import Foundation
import os

/// Signature of the private function:
/// `CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);`
typealias ConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

enum DisplayAPIError: Error, CustomStringConvertible {
    case unsupported
    case beginFailed(CGError)
    case configureFailed(CGError)
    case completeFailed(CGError)
    case helperFailed(String)

    var description: String {
        switch self {
        case .unsupported:
            return L("error.unsupported", "The private API is unavailable on this macOS version")
        case .beginFailed(let e):
            return L("error.begin", "CGBeginDisplayConfiguration failed (code %ld)", Int(e.rawValue))
        case .configureFailed(let e):
            return L("error.configure", "The system rejected the display change (code %ld)", Int(e.rawValue))
        case .completeFailed(let e):
            return L("error.complete", "CGCompleteDisplayConfiguration failed (code %ld)", Int(e.rawValue))
        case .helperFailed(let msg):
            return L("error.helper", "Helper process: %@", msg)
        }
    }
}

/// Loads the private symbol at runtime (no hard linker dependency)
/// and wraps it in a display configuration transaction.
final class DisplayAPI {
    private static let log = Logger(subsystem: Log.subsystem, category: "DisplayAPI")

    private let configureEnabled: ConfigureDisplayEnabledFn?
    /// Which variant was resolved, e.g. "CGSConfigureDisplayEnabled (CoreGraphics)".
    let resolvedSymbolDescription: String?

    var isSupported: Bool { configureEnabled != nil }

    /// Whether to apply changes in a short-lived helper process (see `setEnabled`).
    private let useHelper: Bool

    init(useHelper: Bool = false) {
        self.useHelper = useHelper
        let coreGraphics = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let candidates: [(path: String, framework: String, symbol: String)] = [
            (coreGraphics, "CoreGraphics", "CGSConfigureDisplayEnabled"),
            (skyLight, "SkyLight", "CGSConfigureDisplayEnabled"),
            (skyLight, "SkyLight", "SLSConfigureDisplayEnabled"),
        ]

        var fn: ConfigureDisplayEnabledFn?
        var desc: String?
        for c in candidates {
            // System libraries live in the dyld shared cache – dlopen works even though the file is not on disk.
            guard let handle = dlopen(c.path, RTLD_LAZY) else {
                Self.log.debug("dlopen failed: \(c.path, privacy: .public)")
                continue
            }
            if let sym = dlsym(handle, c.symbol) {
                fn = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
                desc = "\(c.symbol) (\(c.framework))"
                break
            }
            // The handle is intentionally kept open – system libraries are loaded anyway.
        }

        configureEnabled = fn
        resolvedSymbolDescription = desc
        if let desc {
            Self.log.info("Resolved symbol: \(desc, privacy: .public)")
        } else {
            Self.log.error("Neither CGSConfigureDisplayEnabled nor SLSConfigureDisplayEnabled was found")
        }
    }

    /// Turns a display on or off. Blocking – the app calls it off the main thread.
    ///
    /// Measured behavior: when turning the built-in panel off, `CGCompleteDisplayConfiguration`
    /// often returns only after a 10 s timeout, although WindowServer finishes the reconfiguration
    /// in ~0.3 s. This depends on system state, not on the app. Killing the waiting process does
    /// not undo the change. The app therefore runs itself as a short-lived helper
    /// (`--configure-display <id> on|off`) and ends it as soon as the system reports the target
    /// state. If the helper cannot be started, the change is applied in the current process.
    func setEnabled(_ display: CGDirectDisplayID, enabled: Bool) -> Result<Void, DisplayAPIError> {
        guard configureEnabled != nil else { return .failure(.unsupported) }
        if useHelper, let exe = Bundle.main.executableURL,
           let result = runHelper(executable: exe, display: display, enabled: enabled) {
            return result
        }
        return configureInProcess(display, enabled: enabled)
    }

    /// Configuration transaction in the current process (scope: current login session).
    func configureInProcess(_ display: CGDirectDisplayID, enabled: Bool) -> Result<Void, DisplayAPIError> {
        guard let configureEnabled else { return .failure(.unsupported) }

        let started = Date()
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return .failure(.beginFailed(begin)) }

        let result = configureEnabled(config, display, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return .failure(.configureFailed(result))
        }

        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        guard complete == .success else { return .failure(.completeFailed(complete)) }

        Self.log.notice("Display \(display) -> \(enabled ? "on" : "off", privacy: .public) in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public) s (pid \(getpid()))")
        return .success(())
    }

    // MARK: - Helper process

    static let helperFlag = "--configure-display"
    private static let helperTimeout: TimeInterval = 20

    /// `nil` = the helper could not be started (the caller then applies the change itself).
    private func runHelper(executable: URL, display: CGDirectDisplayID,
                           enabled: Bool) -> Result<Void, DisplayAPIError>? {
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.helperFlag, String(display), enabled ? "on" : "off"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            Self.log.error("Could not start the helper process: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Poll the real display state; once the system reports the target state, the change is
        // done and the helper (possibly still waiting in CGCompleteDisplayConfiguration) is ended.
        let deadline = Date().addingTimeInterval(Self.helperTimeout)
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            let elapsed = Date().timeIntervalSince(started)
            let online = CGDisplayIsOnline(display) != 0
            let active = online && CGDisplayIsActive(display) != 0
            if elapsed > 0.3, Self.targetReached(enabled: enabled, online: online, active: active) {
                process.terminate()
                _ = finished.wait(timeout: .now() + 2)
                Self.log.notice("Target state confirmed by the system after \(String(format: "%.2f", elapsed), privacy: .public) s (online=\(online) active=\(active)) – ending the waiting helper")
                return .success(())
            }
            if Date() > deadline {
                process.terminate()
                Self.log.error("Helper timed out after \(Int(Self.helperTimeout)) s; display \(display) online=\(online) active=\(active), target=\(enabled ? "on" : "off", privacy: .public)")
                return .failure(.helperFailed(L("error.helperTimeout", "timed out after %ld s", Int(Self.helperTimeout))))
            }
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Self.log.notice("Helper finished (status \(process.terminationStatus)) in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public) s: \(text, privacy: .public)")
        return Self.decodeHelperResult(status: process.terminationStatus, output: text)
    }

    /// Whether the polled display state matches the target. Turning the panel off is confirmed
    /// both by "online but inactive" (macOS 14) and by "gone from the online list" (macOS 27).
    static func targetReached(enabled: Bool, online: Bool, active: Bool) -> Bool {
        enabled ? (online && active) : !active
    }

    /// Entry point of the helper process (called from main.swift). Returns the exit code.
    static func runHelperCommand(_ args: [String]) -> Int32 {
        guard args.count >= 4, let id = CGDirectDisplayID(args[2]), ["on", "off"].contains(args[3]) else {
            print("usage \(helperFlag) <displayID> on|off")
            return 64
        }
        switch DisplayAPI(useHelper: false).configureInProcess(id, enabled: args[3] == "on") {
        case .success:
            print("ok")
            return 0
        case .failure(let err):
            switch err {
            case .unsupported: print("unsupported 0"); return 2
            case .beginFailed(let e): print("begin \(e.rawValue)"); return 3
            case .configureFailed(let e): print("configure \(e.rawValue)"); return 4
            case .completeFailed(let e): print("complete \(e.rawValue)"); return 5
            case .helperFailed: print("helper 0"); return 6
            }
        }
    }

    private static func decodeHelperResult(status: Int32, output: String) -> Result<Void, DisplayAPIError> {
        if status == 0 { return .success(()) }
        let parts = output.split(separator: " ")
        let code = parts.count == 2 ? Int32(parts[1]).flatMap { CGError(rawValue: $0) } : nil
        switch (status, code) {
        case (2, _): return .failure(.unsupported)
        case (3, let c?): return .failure(.beginFailed(c))
        case (4, let c?): return .failure(.configureFailed(c))
        case (5, let c?): return .failure(.completeFailed(c))
        default: return .failure(.helperFailed(L("error.helperExit", "exit code %ld %@", Int(status), output)))
        }
    }
}

enum Log {
    static let subsystem = "local.ScreenDimmer"
}
