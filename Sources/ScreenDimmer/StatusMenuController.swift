import AppKit

/// Menu bar icon and its menu.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let manager: DisplayManager
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let onQuit: () -> Void

    init(manager: DisplayManager, onQuit: @escaping () -> Void) {
        self.manager = manager
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
    }

    func refresh() {
        updateIcon()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        manager.reconcile(reason: "menu opened")
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let names: [String]
        let description: String
        switch manager.status {
        case .unsupported:
            names = ["exclamationmark.triangle"]
            description = L("icon.unsupported", "ScreenDimmer – not supported")
        case .builtinDisabled:
            names = ["laptopcomputer.slash", "display.trianglebadge.exclamationmark", "eye.slash"]
            description = L("icon.builtinOff", "ScreenDimmer – built-in display off")
        default:
            names = ["laptopcomputer", "display"]
            description = L("icon.builtinOn", "ScreenDimmer – built-in display on")
        }
        let image = names.lazy.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: description)
        }.first
        if let image {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = manager.isBuiltinDisabled ? "◐" : "●"
        }
        button.toolTip = description
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(infoItem(statusText))
        if let symbol = manager.symbolDescription {
            menu.addItem(infoItem(L("menu.method", "Method: %@", symbol), small: true))
        }
        if let error = manager.lastError {
            menu.addItem(infoItem("⚠︎ \(error)", small: true))
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: manager.isBuiltinDisabled
                ? L("menu.turnOn", "Turn On Built-in Display")
                : L("menu.turnOff", "Turn Off Built-in Display"),
            action: #selector(toggleBuiltin), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !manager.isBusy && (manager.isBuiltinDisabled ? manager.canEnable : manager.canDisable)
        menu.addItem(toggle)

        let auto = NSMenuItem(title: L("menu.autoOff", "Turn Off Automatically When a Display Is Connected"),
                              action: #selector(toggleAutoOff), keyEquivalent: "")
        auto.target = self
        auto.state = manager.autoOff ? .on : .off
        auto.isEnabled = manager.isSupported
        menu.addItem(auto)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("menu.quit", "Quit ScreenDimmer"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var statusText: String {
        switch manager.status {
        case .unsupported:
            return L("status.unsupported", "Not supported: CGSConfigureDisplayEnabled is unavailable on this macOS version")
        case .noExternal:
            return L("status.noExternal", "No external display")
        case .externalActive(let n):
            return n == 1
                ? L("status.externalOne", "External display active")
                : L("status.externalMany", "External displays active (%ld)", n)
        case .builtinDisabled(let n):
            return L("status.builtinOff", "Built-in display off (external displays: %ld)", n)
        case .builtinUnavailable(let n):
            return L("status.builtinUnavailable", "Built-in display inactive – lid closed? (external displays: %ld)", n)
        }
    }

    private func infoItem(_ title: String, small: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if small {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        return item
    }

    // MARK: - Actions

    @objc private func toggleBuiltin() {
        manager.userToggle()
    }

    @objc private func toggleAutoOff() {
        manager.autoOff.toggle()
    }

    @objc private func quit() {
        onQuit()
    }
}
