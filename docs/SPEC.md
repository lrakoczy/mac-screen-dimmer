# Functional specification

This is the original specification ScreenDimmer was built from (translated from Polish). It describes requirements, not implementation; see the [README](../README.md) for how they were implemented and for behavior measured on real hardware.

## Purpose

A lightweight, resident **macOS** app living in the menu bar (no Dock icon) whose job is to **programmatically turn the MacBook's built-in display off and on with the lid open** while an external display is connected. This keeps the built-in keyboard, trackpad and Touch ID available, and the system does not "lose" windows on an invisible panel.

## Functional requirements

1. **Menu bar interface**
   - A clear state indicator (icon/state showing whether the built-in display is active or off).
   - The main toggle action: *Turn off built-in display* / *Turn on built-in display*.
   - An automatic-mode switch: *Turn off automatically when a display is connected* (optionally remembered between launches).
   - Current status information (e.g. no external display, external display active, built-in display off, and possibly missing support for the system symbol).
   - A proper exit (*Quit*).
2. **Display detection and state management**
   - Recognizing the built-in display and the presence of at least one external display.
   - Switching the built-in panel's state within a system display configuration transaction, using the private symbol `CGSConfigureDisplayEnabled` loaded dynamically at runtime via `dlopen` / `dlsym`, to avoid a hard linker dependency and to handle its absence safely.
   - Handling display configuration change events (connecting/disconnecting a display, layout changes).
3. **Automation and fail-safe mechanisms**
   - **No turning off "blind":** the built-in display must not be turned off if no external display is connected.
   - **Automatic restore on disconnect:** if the built-in display is off and the external display is disconnected, the app must restore the built-in display immediately.
   - **Automatic restore on quit:** quitting the app (or the system terminating the process) should restore the built-in display, so the user is never left with a dark panel after closing the tool.
   - **Auto-off mode:** with automatic turn-off enabled, after a new external display is detected the app may turn the built-in display off (allowing a short delay/settling time after plugging in the cable, in case the display shows up in stages).

## Notes for the implementation

1. **Undocumented / private macOS API**
   - Turning off a single display with the lid open relies on a private symbol (`CGSConfigureDisplayEnabled`), not on an official public API.
   - The symbol may change or disappear in newer macOS versions – the app must check whether it was resolved and communicate this clearly instead of throwing or hanging.
   - If `CGSConfigureDisplayEnabled` is unavailable or fails on a given OS version, the fallback should be described clearly (e.g. a "not supported" message, or the alternative of mirroring plus brightness adjustment).
2. **Project configuration and macOS permissions**
   - A menu bar agent app should be configured as a background element without a Dock icon (`LSUIElement`).
   - When using low-level system calls / private symbols, the **App Sandbox** can get in the way in a local project – this should be mentioned in the build requirements.
   - For use on your own MacBook only, no paid Apple Developer account is needed (local signing is enough).
3. **Hardware and system edge cases**
   - **Waking from sleep and switching monitor inputs:** connecting/disconnecting a USB-C/HDMI/Thunderbolt cable or switching the monitor's input can generate several display configuration change events in a row – the event handling must be robust against duplicates and race conditions.
   - **Keeping app state in sync with reality:** if the user changes the display layout manually in System Settings (e.g. disconnects a display or changes the configuration), the app's internal state (`isDisabled`) and the menu items must stay consistent with reality.
   - **Multiple external displays:** the app should check for *any* external display (not just one), so that unplugging one of two external displays does not restore the built-in display prematurely while the other external display is still active.
