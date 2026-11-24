import Foundation
import ServiceManagement

/// Launch at Login state as reported by the system (the system is the source of truth –
/// nothing is stored in Preferences, so changes made in System Settings are picked up).
enum LoginItemState: Equatable {
    case enabled
    case disabled
    case requiresApproval   // registered, but the user must allow it in System Settings → Login Items
    case notFound           // the system could not find the app (e.g. unusual location / signature)
}

/// Abstraction over SMAppService so the logic can be tested without touching the system.
protocol LoginItemService: AnyObject {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

/// Real implementation: `SMAppService.mainApp` (macOS 13+, no helper bundle required).
final class SystemLoginItemService: LoginItemService {
    private var service: SMAppService { .mainApp }

    var state: LoginItemState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

enum LoginItemToggleResult: Equatable {
    case enabled
    case disabled
    /// Registration needs the user's approval in System Settings → Login Items.
    case needsApproval
    case failed(String)
}

/// Menu-facing logic for the Launch at Login toggle.
final class LoginItemController {
    private let service: LoginItemService

    init(service: LoginItemService) {
        self.service = service
    }

    var state: LoginItemState { service.state }

    /// Checkmark: on when enabled; mixed while waiting for approval.
    var isOn: Bool { state == .enabled }
    var isPending: Bool { state == .requiresApproval }

    /// Enabled → turn off; disabled / not found → turn on;
    /// pending approval → nothing to toggle, the user has to decide in System Settings.
    func toggle() -> LoginItemToggleResult {
        switch service.state {
        case .requiresApproval:
            return .needsApproval
        case .enabled:
            do {
                try service.unregister()
                return .disabled
            } catch {
                return .failed(error.localizedDescription)
            }
        case .disabled, .notFound:
            do {
                try service.register()
            } catch {
                // register() may throw while still leaving the item pending approval.
                if service.state == .requiresApproval { return .needsApproval }
                return .failed(error.localizedDescription)
            }
            switch service.state {
            case .enabled: return .enabled
            case .requiresApproval: return .needsApproval
            case .disabled, .notFound:
                return .failed(L("error.loginItemNotFound",
                                 "macOS did not register the app. Move ScreenDimmer.app to the Applications folder and try again."))
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
