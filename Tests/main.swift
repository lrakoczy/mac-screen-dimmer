// Logic tests for DisplayManager, run against a display simulator.
// Run with: ./scripts/test.sh
import CoreGraphics
import Foundation

// MARK: - Simulator reproducing measured macOS behavior

final class FakeSystem: DisplaySystem {
    var isSupported = true
    var resolvedSymbolDescription: String? = "fake"
    var builtinID: CGDirectDisplayID = 100
    var builtinOnline = true          // false = lid closed
    var builtinActive = true
    var externals: [CGDirectDisplayID] = []
    var failNext = false
    var delay: TimeInterval = 0          // simulates a slow CGCompleteDisplayConfiguration
    var calls: [(CGDirectDisplayID, Bool)] = []
    let callsLock = NSLock()

    func snapshot() -> DisplaySnapshot {
        DisplaySnapshot(builtinID: builtinOnline ? builtinID : nil,
                        builtinActive: builtinOnline && builtinActive,
                        externalIDs: externals)
    }

    func setEnabled(_ display: CGDirectDisplayID, enabled: Bool) -> Result<Void, DisplayAPIError> {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        callsLock.lock(); calls.append((display, enabled)); callsLock.unlock()
        guard isSupported else { return .failure(.unsupported) }
        if failNext { failNext = false; return .failure(.configureFailed(.illegalArgument)) }
        // Like the real system: a wrong ID changes nothing.
        if display == builtinID { builtinActive = enabled }
        return .success(())
    }
}

// MARK: - Mini framework

var failures = 0
var currentTest = ""

func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if !cond() {
        failures += 1
        print("  ✗ [\(currentTest)] \(msg) (line \(line))")
    }
}

func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Waits for operations on the worker queue to finish.
func settle() { wait(0.08) }

let grace: TimeInterval = 0.2
let autoDelay: TimeInterval = 0.15

func makeEnv(autoOff: Bool = false, configure: (FakeSystem, Preferences) -> Void = { _, _ in })
    -> (FakeSystem, Preferences, DisplayManager) {
    let suite = "ScreenDimmerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let prefs = Preferences(defaults: defaults)
    prefs.autoOff = autoOff
    let sys = FakeSystem()
    configure(sys, prefs)
    let m = DisplayManager(system: sys, prefs: prefs, autoOffDelay: autoDelay, ownChangeGrace: grace)
    return (sys, prefs, m)
}

func test(_ name: String, _ body: () -> Void) {
    currentTest = name
    let before = failures
    body()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

// MARK: - Scenarios

test("No external display: cannot turn off") {
    let (sys, _, m) = makeEnv()
    m.recoverOnLaunch(); settle()
    check(m.status == .noExternal, "status \(m.status)")
    check(!m.canDisable, "canDisable should be false")
    m.userToggle(); settle()
    check(sys.calls.isEmpty, "there should be no API calls")
    check(sys.builtinActive, "panel should stay active")
    check(m.lastError != nil, "there should be an error message")
}

test("REGRESSION: after turning off, the menu offers Turn On (also after the grace period)") {
    let (sys, prefs, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    check(m.canDisable, "canDisable")
    m.userToggle(); settle()
    check(!sys.builtinActive, "panel off")
    check(m.isBuiltinDisabled && m.canEnable, "right after turning off: Turn On available")
    wait(grace + 0.4)                       // grace period over, recheck done
    m.reconcile(reason: "event"); settle()  // panel still online but inactive
    check(m.isBuiltinDisabled, "still off after the grace period")
    check(m.canEnable, "Turn On available after the grace period")
    check(m.status == .builtinDisabled(externalCount: 1), "status \(m.status)")
    check(prefs.disabledByUs, "recovery flag saved")
    m.userToggle(); settle()
    check(sys.builtinActive, "panel turned on from the menu")
    wait(grace + 0.1)
    m.reconcile(reason: "event"); settle()
    check(!m.isBuiltinDisabled && m.canDisable, "can turn off again after turning on")
    check(!prefs.disabledByUs, "recovery flag cleared")
}

test("Only external display unplugged while panel is off → restored immediately") {
    let (sys, _, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    m.userToggle(); settle()
    sys.externals = []
    m.failSafeCheck(); settle()
    check(sys.builtinActive, "panel restored without waiting for the debounce")
    m.reconcile(reason: "after debounce"); settle()
    check(m.status == .noExternal, "status \(m.status)")
}

test("Two external displays, one unplugged → panel stays off") {
    let (sys, _, m) = makeEnv { s, _ in s.externals = [200, 201] }
    m.recoverOnLaunch(); settle()
    m.userToggle(); settle()
    sys.externals = [201]
    m.failSafeCheck(); settle()
    wait(grace + 0.1)
    m.reconcile(reason: "event"); settle()
    check(!sys.builtinActive, "panel still off")
    check(m.status == .builtinDisabled(externalCount: 1), "status \(m.status)")
    sys.externals = []
    m.failSafeCheck(); settle()
    check(sys.builtinActive, "restored after the last one is unplugged")
}

test("Quitting the app restores the panel") {
    let (sys, prefs, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    m.userToggle(); settle()
    m.restoreForExit()
    check(sys.builtinActive, "panel restored")
    check(!prefs.disabledByUs, "flag cleared")
}

test("Recovery after kill -9: panel off at launch → restored") {
    let (sys, _, m) = makeEnv { s, p in
        s.externals = [200]; s.builtinActive = false; p.disabledByUs = true
    }
    m.recoverOnLaunch(); settle()
    check(sys.builtinActive, "panel restored at launch")
}

test("Panel ID changed (remembered ID stale) → turning on uses the current ID") {
    let (sys, prefs, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    m.userToggle(); settle()
    sys.builtinID = 999                     // e.g. GPU switch
    sys.builtinActive = false
    check(prefs.builtinID == 100, "old ID remembered")
    wait(grace + 0.1)
    m.userToggle(); settle()
    check(sys.calls.last.map { $0.0 == 999 && $0.1 } == true, "turn-on called for ID 999: \(sys.calls)")
    check(sys.builtinActive, "panel on")
}

test("Panel turned off by another tool → state synced, Turn On available") {
    let (sys, prefs, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    sys.builtinActive = false
    m.reconcile(reason: "event"); settle()
    check(m.isBuiltinDisabled && m.canEnable, "Turn On available")
    check(prefs.disabledByUs, "will be restored on exit")
}

test("Panel turned on externally (e.g. System Settings) → state synced") {
    let (sys, prefs, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    m.userToggle(); settle()
    wait(grace + 0.1)
    sys.builtinActive = true
    m.reconcile(reason: "event"); settle()
    check(!m.isBuiltinDisabled && m.canDisable, "Turn Off available")
    check(!prefs.disabledByUs, "flag cleared")
}

test("Auto-off: display connected → panel turns off after the delay") {
    let (sys, _, m) = makeEnv(autoOff: true)
    m.recoverOnLaunch(); settle()
    sys.externals = [200]
    m.reconcile(reason: "connected")        // synchronous; auto-off is only scheduled
    check(sys.builtinActive, "not immediately")
    wait(autoDelay + 0.3)
    check(!sys.builtinActive, "off after the delay")
}

test("Auto-off: display gone before the delay → does nothing") {
    let (sys, _, m) = makeEnv(autoOff: true)
    m.recoverOnLaunch(); settle()
    sys.externals = [200]
    m.reconcile(reason: "connected")        // no wait here: disconnect before the auto-off delay
    sys.externals = []
    m.reconcile(reason: "disconnected"); settle()
    wait(autoDelay + 0.3)
    check(sys.builtinActive, "panel active")
    check(sys.calls.isEmpty, "no API calls")
}

test("Auto-off: manual turn-on is respected until the next connection") {
    let (sys, _, m) = makeEnv(autoOff: true) { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()                     // auto-off at launch with a display connected
    wait(autoDelay + 0.3)
    check(!sys.builtinActive, "auto-off at launch")
    m.userToggle(); settle()                          // user turns it on
    wait(grace + 0.4)
    m.reconcile(reason: "event", allowAutoOff: true); settle()  // e.g. wake
    wait(autoDelay + 0.3)
    check(sys.builtinActive, "auto-off does not turn it off after a manual turn-on")
    sys.externals = []
    m.reconcile(reason: "disconnected"); settle()
    sys.externals = [200]
    m.reconcile(reason: "reconnected"); settle()
    wait(autoDelay + 0.3)
    check(!sys.builtinActive, "auto-off works again after reconnecting")
}

test("Burst of duplicate events does not cause repeated calls") {
    let (sys, _, m) = makeEnv(autoOff: true)
    m.recoverOnLaunch(); settle()
    sys.externals = [200]
    for _ in 0..<5 { m.reconcile(reason: "duplicate"); m.failSafeCheck() }
    wait(autoDelay + 0.3)
    for _ in 0..<5 { m.reconcile(reason: "duplicate"); m.failSafeCheck() }
    check(sys.calls.count == 1, "exactly one API call: \(sys.calls)")
}

test("Lid closed (panel offline) → no actions, informational status") {
    let (sys, _, m) = makeEnv { s, _ in s.externals = [200]; s.builtinOnline = false }
    m.recoverOnLaunch(); settle()
    check(m.status == .builtinUnavailable(externalCount: 1), "status \(m.status)")
    check(!m.canDisable && !m.canEnable, "no actions")
    check(sys.calls.isEmpty, "no API calls")
}

test("Symbol missing → unsupported status, actions disabled") {
    let (_, _, m) = makeEnv { s, _ in s.isSupported = false; s.externals = [200] }
    m.recoverOnLaunch(); settle()
    check(m.status == .unsupported, "status \(m.status)")
    check(!m.canDisable && !m.canEnable, "actions disabled")
}

test("API error when turning off → state unchanged, error message") {
    let (sys, prefs, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    sys.failNext = true
    m.userToggle(); settle()
    check(sys.builtinActive, "panel active")
    check(!m.isBuiltinDisabled && m.canDisable, "can retry")
    check(!prefs.disabledByUs, "flag not saved")
    check(m.lastError != nil, "error message")
}

test("Repeated clicks during an operation → state consistent with the system") {
    let (sys, _, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    sys.delay = 0.3
    m.userToggle()
    check(m.isBuiltinDisabled && m.isBusy, "menu shows the target state immediately")
    m.userToggle()                          // second click = Turn On (intended state: off)
    m.userToggle()
    wait(1.0)
    check(sys.calls.count <= 3, "bounded number of calls: \(sys.calls.count)")
    check(sys.builtinActive == !m.isBuiltinDisabled, "app state matches the system")
}

test("Display unplugged while turning off → panel restored afterwards") {
    let (sys, _, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    sys.delay = 0.3
    m.userToggle()
    sys.externals = []
    m.failSafeCheck()                       // event arrives during the operation
    wait(1.0)
    check(sys.builtinActive, "panel restored")
    m.reconcile(reason: "event"); settle()
    check(m.status == .noExternal, "status \(m.status)")
}

test("Main thread is not blocked by a slow operation") {
    let (sys, _, m) = makeEnv { s, _ in s.externals = [200] }
    m.recoverOnLaunch(); settle()
    sys.delay = 0.5
    let t0 = Date()
    m.userToggle()
    check(Date().timeIntervalSince(t0) < 0.1, "userToggle returned immediately")
    wait(0.8)
    check(!sys.builtinActive, "panel off after completion")
}

// MARK: - Launch at Login

final class FakeLoginItemService: LoginItemService {
    struct Failure: LocalizedError { var errorDescription: String? { "boom" } }
    var state: LoginItemState = .disabled
    var stateAfterRegister: LoginItemState = .enabled
    var throwOnRegister = false
    var throwOnUnregister = false
    var registerCalls = 0
    var unregisterCalls = 0

    func register() throws {
        registerCalls += 1
        if throwOnRegister { throw Failure() }
        state = stateAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if throwOnUnregister { throw Failure() }
        state = .disabled
    }
}

test("Launch at Login: off → on → off") {
    let svc = FakeLoginItemService()
    let c = LoginItemController(service: svc)
    check(!c.isOn && !c.isPending, "initially off")
    check(c.toggle() == .enabled, "registered")
    check(c.isOn && svc.registerCalls == 1, "on after toggle")
    check(c.toggle() == .disabled, "unregistered")
    check(!c.isOn && svc.unregisterCalls == 1, "off after second toggle")
}

test("Launch at Login: state follows the system (changed in System Settings)") {
    let svc = FakeLoginItemService()
    let c = LoginItemController(service: svc)
    svc.state = .enabled
    check(c.isOn, "picked up external enable")
    svc.state = .requiresApproval
    check(!c.isOn && c.isPending, "pending shown as mixed")
}

test("Launch at Login: approval required after register") {
    let svc = FakeLoginItemService()
    svc.stateAfterRegister = .requiresApproval
    let c = LoginItemController(service: svc)
    check(c.toggle() == .needsApproval, "needs approval")
    check(c.isPending, "pending")
}

test("Launch at Login: pending approval → toggle does not touch the system") {
    let svc = FakeLoginItemService()
    svc.state = .requiresApproval
    let c = LoginItemController(service: svc)
    check(c.toggle() == .needsApproval, "needs approval")
    check(svc.registerCalls == 0 && svc.unregisterCalls == 0, "no calls")
}

test("Launch at Login: errors are reported, not swallowed") {
    let svc = FakeLoginItemService()
    svc.throwOnRegister = true
    let c = LoginItemController(service: svc)
    check(c.toggle() == .failed("boom"), "register error surfaced")
    check(!c.isOn, "still off")

    svc.state = .enabled
    svc.throwOnUnregister = true
    check(c.toggle() == .failed("boom"), "unregister error surfaced")
    check(c.isOn, "still on")
}

test("Launch at Login: register silently ignored (notFound) → error") {
    let svc = FakeLoginItemService()
    svc.state = .notFound
    svc.stateAfterRegister = .notFound
    let c = LoginItemController(service: svc)
    if case .failed = c.toggle() {} else { check(false, "expected failure") }
}

print(failures == 0 ? "\nALL TESTS PASSED" : "\nFAILED ASSERTIONS: \(failures)")
exit(failures == 0 ? 0 : 1)
