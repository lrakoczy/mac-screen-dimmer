import CoreGraphics
import Foundation

/// Persistent settings and the state needed for crash recovery.
final class Preferences {
    private enum Key {
        static let autoOff = "autoOffOnExternalConnect"
        static let builtinID = "lastKnownBuiltinDisplayID"
        static let disabledByUs = "builtinDisabledByApp"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var autoOff: Bool {
        get { defaults.bool(forKey: Key.autoOff) }
        set { defaults.set(newValue, forKey: Key.autoOff) }
    }

    var builtinID: CGDirectDisplayID? {
        get {
            guard let n = defaults.object(forKey: Key.builtinID) as? NSNumber else { return nil }
            return CGDirectDisplayID(n.uint32Value)
        }
        set {
            if let newValue {
                defaults.set(NSNumber(value: newValue), forKey: Key.builtinID)
            } else {
                defaults.removeObject(forKey: Key.builtinID)
            }
        }
    }

    /// `true` when the app turned the built-in display off and has not restored it yet.
    /// Saved immediately so the display can be restored on launch after `kill -9` / a crash.
    var disabledByUs: Bool {
        get { defaults.bool(forKey: Key.disabledByUs) }
        set {
            defaults.set(newValue, forKey: Key.disabledByUs)
            defaults.synchronize()
        }
    }
}
