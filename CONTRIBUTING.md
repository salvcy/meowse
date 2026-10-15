# Contributing

Meowse's priority is efficiency, then native behaviour, then features. A
change that adds idle work or system-wide cost needs a very good reason.

## Rules

1. **No polling.** Respond to system notifications (wake, session, screen,
   lock, accessibility) instead of checking on a timer. Timers are allowed
   only when one-shot, when a user-enabled feature needs them, or while
   Accessibility access is missing. All timers get leeway so the kernel can
   coalesce wakeups.
2. **Idle is zero.** With the menu closed and no glide in progress, the app
   uses 0% CPU and has no idle wakeups. Check with `scripts/measure.sh`.
3. **One active event tap.** Its mask is built from the current settings, and
   it doesn't exist when nothing needs it. Modifier hotkeys are read from event
   flags, so the tap never receives keyboard events; button shortcuts only post
   them, and buttons reach the tap only once one has a shortcut. Stop-on-click listens
   through a second, listen-only tap that's enabled only while a glide is in
   flight, so clicks never wait for Meowse.
4. **Keep the event path lean.** Scroll handling and frame posting run on the
   engine thread (`Engine.swift`) without locks, allocation or main-thread
   work. Classify events and return early. Every synthetic event costs the
   target app work, so post only visible motion and end glides promptly.
5. **Prefer system mechanisms.** For example, Keep Awake uses a power assertion
   with a system-enforced timeout rather than tracking time itself, and freed
   memory goes back to the system through the allocator's space-efficient
   mode (`LSEnvironment` in `Resources/Info.plist`), not purging of our own.
   Mouse acceleration is the value System Settings' Tracking speed sets, given
   to each mouse (`PointerControl.swift`), so pointer movement never passes
   through Meowse; the Mac's own value goes back when Meowse quits.
   The one thing a running app can't return is what macOS keeps in it after
   display changes (colour tables, window contexts, freed pages), so once
   Meowse has doubled its launch memory it starts over the next time the
   display sleeps (`Refresh` in `MeowseCore`).
6. **Native UI.** `NSMenu` for the menu bar, built the first time it opens.
   Its rows draw themselves (`MenuRows.swift`): on macOS 27, system controls
   and text fields inside a menu cost megabytes once it opens.
   SwiftUI only in the Settings window, which runs as its own process
   (`Meowse Settings.app` inside the bundle) and exits when the window closes,
   so what SwiftUI loads never stays in Meowse. (On macOS 27, `NSMenu`
   itself loads some SwiftUI the first time a menu opens: about 3 MB for even
   a plain menu.) SF Symbols throughout and standard controls in Settings,
   no web views, no third-party dependencies.
7. **Root only where macOS requires it.** Run With Lid Closed needs
   `meowse-lid` (`Sources/MeowseLid`), a launchd daemon registered with
   `SMAppService`. It holds lid-close sleep off only while Meowse keeps an
   XPC connection to it, accepts only the app it ships in signed by the same
   team, and turns sleep back on when the connection ends.
8. **Lazy UI state.** Menu items refresh in `menuNeedsUpdate`. View code reads
   cached values and never makes system calls. Writes to disk are coalesced.
9. **Logic in `MeowseCore`.** Anything that can be pure lives there, without
   AppKit, and has unit tests.

## Workflow

```bash
swift test               # unit tests
scripts/build.sh         # release build → build/Meowse.app
scripts/install.sh       # build and move into /Applications, then relaunch
scripts/measure.sh       # CPU, idle wakeups and memory of the running app
scripts/release.sh 1.2.0 # version bump, build and dist/Meowse.zip
```

`build.sh` signs with the first Apple Development identity in your keychain,
which keeps the Accessibility permission across rebuilds. Releases must be
signed by the same team as installed copies, or the in-app updater rejects
them. `release.sh` signs with your Developer ID Application certificate and
has Apple notarize the archive, so Gatekeeper opens the download; its header
explains the one-time setup.
