import AppKit

// Helper process mode: apply one display configuration change and exit (no NSApplication).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == DisplayAPI.helperFlag {
    exit(DisplayAPI.runHelperCommand(CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon (LSUIElement is also set in Info.plist)
app.run()
