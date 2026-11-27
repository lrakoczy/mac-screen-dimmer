# ScreenDimmer

A tiny macOS menu bar app (no Dock icon) that turns the MacBook's **built-in display off and back on with the lid open** while an external display is connected. The built-in keyboard, trackpad and Touch ID keep working, and windows move to the external display instead of getting lost on an invisible panel.

- **macOS:** 14 Sonoma or later (15 Sequoia, 26 Tahoe, …)
- **Hardware:** Intel and Apple Silicon (M1 and later) – one universal `.app`
- **Languages:** English (default) and Polish

> [!WARNING]
> ScreenDimmer relies on an **undocumented, private macOS API** (`CGSConfigureDisplayEnabled`). It may stop working with any macOS update. The app is designed to fail safe (see [Safety](#safety)), but you use it at your own risk.

## Features

- Menu bar icon showing whether the built-in display is on or off
- **Turn Off / Turn On Built-in Display**
- **Turn Off Automatically When a Display Is Connected** (remembered between launches)
- **Launch at Login** – registers the app in System Settings → General → Login Items (`SMAppService`); the checkmark always reflects the system setting. Works best with the app in `/Applications`.
- Status line: no external display / external display(s) active / built-in display off / lid closed / API not supported
- **Quit** always turns the built-in display back on first

## Download

Get the latest `ScreenDimmer-x.y.z.zip` from [Releases](https://github.com/lrakoczy/mac-screen-dimmer/releases/latest), unzip it, move `ScreenDimmer.app` to Applications and see [Running on another Mac](#running-on-another-mac) for the first launch.

## Building

Only the Command Line Tools are required (`xcode-select --install`). No Xcode, no SwiftPM, no paid Apple Developer account.

```bash
./scripts/build-app.sh
open build/ScreenDimmer.app
```

The script compiles the sources with `swiftc` for `x86_64` and `arm64` (`-target …-apple-macosx14.0`), merges them with `lipo` and signs the bundle ad hoc (`codesign -s -`). Apple Silicon Macs refuse to run unsigned code, so the signature is required.

> [!NOTE]
> **Command Line Tools issue:** after a CLT update a stale
> `/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap` may be left behind, which makes compilation fail with `redefinition of module 'SwiftBridging'`. The build script detects this and works around it with a VFS overlay. To fix it permanently:
> `sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap`

**App Sandbox is intentionally not used** – the app calls a private API through `dlopen`/`dlsym`, which the sandbox may block.

### Running on another Mac

The app is only ad-hoc signed (not notarized), so if you copy it over AirDrop or download it, Gatekeeper will block it on first launch. On macOS 14, right-click it → **Open**. On macOS 15 and later, try to open it once, then go to System Settings → Privacy & Security and click **Open Anyway**. Alternatively, remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine ScreenDimmer.app
```

Release builds are produced by [GitHub Actions](.github/workflows/release.yml) and are ad-hoc signed the same way.

The version is taken from git, not from `Resources/Info.plist` (which only holds placeholders): the build script writes the latest `v*` tag as the version, the commit count as the build number and `git describe` (e.g. `v1.1.1-3-gabc1234-dirty`) as the source revision into the built app. The launch log shows all three. `VERSION` and `BUILD_NUMBER` environment variables override the first two.

### Making a release

Push a version tag; the [release workflow](.github/workflows/release.yml) runs the tests, builds the universal app with the version taken from the tag and publishes a GitHub release with the zip and its SHA-256:

```bash
git tag v1.2.3
git push origin v1.2.3
```

## Safety

| Situation | What happens |
|---|---|
| No external display | The built-in display cannot be turned off |
| Last external display unplugged | The built-in display comes back immediately, without debouncing |
| One of several external displays unplugged | The panel stays off – *any* of the displays connected when it was turned off counts |
| Displays connected while the panel is off | They do not keep it off: once all displays it was turned off for are gone, the panel comes back. Turn it off again to use the new display alone |
| Virtual displays (e.g. the 1920×1080 fallback display macOS creates when the last monitor is unplugged) | Never count as external displays. A display without an EDID vendor ID (or with the fallback display's `virt` model number) is treated as virtual, so the panel cannot be turned off with only such a display connected |
| Quit, logout, `SIGTERM` / `SIGINT` / `SIGHUP` | The built-in display is restored before the app exits |
| `kill -9` or crash | The state is persisted in UserDefaults; the next launch restores the display before doing anything else |
| Burst of events (cable, input switching, wake) | Events are coalesced (0.75 s) and the state is always re-read from the system |
| Auto-off | Turns the panel off 2 s after a display is connected, only if it is still connected. A manual Turn On is respected until the next connection |

## How it works

### Private API and newer macOS versions

At launch the app looks for the private function in this order:

1. `CoreGraphics` → `CGSConfigureDisplayEnabled`
2. `SkyLight` → `CGSConfigureDisplayEnabled`
3. `SkyLight` → `SLSConfigureDisplayEnabled`

If none is found, the app does not crash: the menu shows "Not supported" and the toggle is disabled. If the system rejects a change, the error code is shown in the menu. A manual alternative is mirroring to the external display in System Settings → Displays and turning the built-in brightness all the way down.

### Behavior measured on real hardware

- **macOS 14.8 (Intel):** a panel turned off this way **stays in the list of online displays**, it only reports `CGDisplayIsActive == false`. The app derives its state from that flag. With the lid closed the panel disappears from the list entirely.
- **macOS 27 (Apple Silicon, [#3](https://github.com/lrakoczy/mac-screen-dimmer/issues/3)):** a panel turned off this way **disappears from the list of online displays**, as with the lid closed. The app then relies on its own persisted state, and the helper treats "gone from the list" as a confirmed turn-off.
- When the last physical display is unplugged while the panel is off, WindowServer brings up a fallback **virtual display** (1920×1080, a new ID each time) that is online and active. It is not counted as an external display, and since it was not connected when the panel went off it cannot keep the panel off either. Measured on Mac16,1 (M4), macOS 27.2.1: vendor `unkn` (`0x756E6B6E`), model `virt` (`0x76697274`), no serial number. Its reported size (677×381 mm) is only CoreGraphics' 72 DPI estimate for a display without an EDID, so the size alone does not tell real and virtual displays apart. Confirmed fixed on that machine: the panel comes back about 0.2 s after the HDMI cable is unplugged.
- The built-in display ID can change (e.g. with GPU switching). Turning it back on always uses a fresh reading.
- When turning the panel off, `CGCompleteDisplayConfiguration` often returns only after a **10 s** timeout, even though the WindowServer logs show the reconfiguration finishing in ~0.3 s. This depends on system state, not on the app. Killing the waiting process does not undo the change. The app therefore applies changes in a short-lived helper process (`ScreenDimmer --configure-display <id> on|off`) off the main thread, polls the real display state every 0.1 s and ends the helper as soon as the target state is reached, so a toggle takes about 0.5 s. If the helper cannot be started, the change is applied in the app's own process.

## Languages

The UI is in English by default and in Polish when Polish is the preferred language. macOS picks the first language from your preferred-languages list (System Settings → General → Language & Region) that the app supports, and falls back to English for anything else. The language can also be set for this app alone under System Settings → General → Language & Region → Applications.

Strings live in `Resources/en.lproj/Localizable.strings` and `Resources/pl.lproj/Localizable.strings` and are used in code through `L("key", "English default")` from `Localization.swift`. Adding a language means adding another `.lproj` folder and listing it in `CFBundleLocalizations` in `Resources/Info.plist`.

## Testing

```bash
./scripts/test.sh
```

Runs 36 logic scenarios against a display simulator (including the macOS 27 behavior and the fallback virtual display) that reproduces the measured system behavior. Real displays are never touched.

### Manual checklist (especially on Apple Silicon and newer macOS)

1. After launch there is no Dock icon, only a menu bar icon.
2. Without an external display, Turn Off is disabled.
3. With an external display: Turn Off → the panel goes dark; Turn On → it comes back.
4. Panel off, unplug the cable → the panel comes back immediately (check both with one and with two external displays).
5. Auto-off enabled, plug in a display → the panel goes dark after ~2 s.
6. Panel off, `pkill ScreenDimmer` → the panel comes back.
7. Panel off, `pkill -9 ScreenDimmer`, launch again → the panel comes back.
8. After sleep and wake the menu status matches reality.
9. App in `/Applications`, enable Launch at Login → it appears in Login Items; log out and in → the app starts. Turn it off in System Settings → the menu checkmark clears.

## Diagnostics

Toggle the panel without clicking the menu (same as Turn Off / Turn On):

```bash
pkill -USR1 -x ScreenDimmer
```

Write the full state to the log: app version, macOS version, Mac model, resolved API, saved settings, internal state and every online display with its vendor, physical size, mode and how it was classified (built-in / external / virtual):

```bash
pkill -USR2 -x ScreenDimmer
```

Stream the logs:

```bash
log stream --level debug --predicate 'subsystem == "local.ScreenDimmer"'
```

Collect the logs after the fact, e.g. for a bug report (display events, decisions and the display list are logged at `notice` level, so they are kept):

```bash
log show --last 30m --info --predicate 'subsystem == "local.ScreenDimmer"'
```

What gets logged:

- At launch: version, build, macOS version, Mac model, architecture, resolved API and saved settings.
- Every display reconfiguration event with decoded flags (`add`, `remove`, `enabled`, `disabled`, …) and the display's state.
- The list of online displays whenever it changes, with the classification of each one.
- Every fail-safe decision: why the panel was restored, or which displays keep it off.
- Turning off: which external displays it was turned off for and which virtual ones were ignored.
- Helper timing, and the display state if the helper times out.

Serial numbers of displays are not logged, only whether a display has one.

## Project layout

```
Sources/ScreenDimmer/
  main.swift                 NSApplication startup (.accessory) and helper-process mode
  AppDelegate.swift          wiring, signal handling, restore on quit
  DisplayAPI.swift           dlopen/dlsym, CGBegin/CompleteDisplayConfiguration transaction, helper process
  DisplayManager.swift       state, safety rules, sync with the system state, auto-off
  DisplayEventMonitor.swift  display reconfiguration and wake events, debouncing
  StatusMenuController.swift menu bar icon and menu
  LoginItem.swift            Launch at Login (SMAppService.mainApp)
  Preferences.swift          UserDefaults
  Localization.swift         L() – localized strings (en default, pl)
Resources/Info.plist         LSUIElement, LSMinimumSystemVersion 14.0, CFBundleLocalizations en/pl
Resources/{en,pl}.lproj      Localizable.strings
Tests/main.swift             logic tests against a display simulator
scripts/build-app.sh         universal build + ad-hoc signing
scripts/test.sh              compiles and runs the tests
docs/SPEC.md                 original functional specification
```

## License

Released into the public domain under [The Unlicense](LICENSE).
