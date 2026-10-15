import AppKit
import MeowseCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = SettingsStore.shared
    private let engine = Engine.shared
    private let awake = AwakeController.shared
    private let updater = Updater.shared
    private let lid = LidHold()
    private let pointer = PointerControl()
    /// Where the excluded apps are, looked up when the list changes.
    private var excludedPaths: [String] = []
    private var engineConfig = EngineConfig(Settings())
    private lazy var statusMenu = StatusMenuController(store: store, awake: awake, updater: updater, lid: lid)
    private lazy var settingsHost: SettingsHost = {
        let host = SettingsHost(store: store, awake: awake, updater: updater)
        host.requestPermission = { [weak self] in self?.requestPermission() }
        host.openLoginItems = { [weak self] in self?.lid.openApproval() }
        return host
    }()
    private var trusted = false
    /// Exists only while Accessibility access is missing.
    private var trustWatch: DispatchSourceTimer?
    /// Memory in use once launch has settled; 0 until then.
    private var launchFootprint = 0
    private let launchUptime = ProcessInfo.processInfo.systemUptime
    /// Pending only while the display is asleep.
    private var refresh: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, so a copy that's moving never installs its tap or asks for access.
        if AppMover.offerMove() { return }
        engine.start()
        excludedPaths = Self.paths(of: store.settings.excludedApps)
        engineConfig = EngineConfig(store.settings, excludedPaths: excludedPaths)
        engine.apply(engineConfig)
        rebuildScreens()
        pointer.update(store.settings)
        pointer.onDevicesChange = { [weak self] in self?.refreshPointerInfo() }

        store.onChange = { [weak self] new, old in self?.settingsChanged(new, old) }
        awake.onChange = { [weak self] in
            self?.statusMenu.updateIcon()
            self?.updateLid()
        }
        lid.onChange = { [weak self] in self?.statusMenu.lidChanged() }
        statusMenu.openSettings = { [weak self] in self?.showSettings() }
        statusMenu.openUpdates = { [weak self] in self?.showSettings(tab: .updates) }
        statusMenu.requestPermission = { [weak self] in self?.requestPermission() }
        statusMenu.willOpen = { [weak self] in
            self?.refreshTrust(prompt: false)
            self?.updateLid()  // e.g. the helper was approved since
        }
        statusMenu.retryEngine = { [weak self] in self?.engine.revalidate() }
        engine.onStatusChange = { [weak self] status in
            self?.store.engineStatus = status
            self?.statusMenu.engineStatus = status
            if status != .active { self?.store.setScrollDevice(nil) }
        }
        engine.onDeviceChange = { [weak self] device, sender in
            self?.store.setScrollDevice(device, touch: device == .touch ? TouchKind(registryID: sender) : nil)
            self?.statusMenu.updateIcon()
        }
        statusMenu.setVisible(store.settings.showMenuBarIcon)

        observeSystem()
        awake.observeSystem()
        updater.setAutomaticChecks(store.settings.checkForUpdates)
        refreshTrust(prompt: true)
        welcomeOnFirstLaunch()
        // One-shot: what later growth is measured against.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.launchFootprint = Self.footprint()
        }
    }

    /// Opening the app again (e.g. with the menu bar icon hidden) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func settingsChanged(_ new: Settings, _ old: Settings) {
        if new.excludedApps != old.excludedApps { excludedPaths = Self.paths(of: new.excludedApps) }
        let config = EngineConfig(new, excludedPaths: excludedPaths)
        if config != engineConfig {
            engineConfig = config
            engine.apply(config)
        }
        if new.pointerAcceleration != old.pointerAcceleration || new.pointerSpeed != old.pointerSpeed
            || new.pointerCurve != old.pointerCurve || new.pointerScale != old.pointerScale
            || new.pointerExternalOnly != old.pointerExternalOnly {
            pointer.update(new)
            refreshPointerInfo()
        }
        if new.showMenuBarIcon != old.showMenuBarIcon { statusMenu.setVisible(new.showMenuBarIcon) }
        if new.enabled != old.enabled { statusMenu.updateIcon() }

        // Running sessions pick up preference changes.
        if new.awakeAllowDisplaySleep != old.awakeAllowDisplaySleep {
            awake.setAllowDisplaySleep(new.awakeAllowDisplaySleep)
        }
        if new.awakeLidClosed != old.awakeLidClosed {
            // Turned on by hand: ask for the helper's approval now, not when Keep Awake next starts.
            if new.awakeLidClosed { lid.prepare() }
            updateLid()
        }
        if new.wiggleInterval != old.wiggleInterval, awake.isWiggling {
            awake.startWiggle(interval: new.wiggleInterval)
        }
        if new.checkForUpdates != old.checkForUpdates {
            updater.setAutomaticChecks(new.checkForUpdates)
        }
    }

    /// Holds the lid open for sleep only while Keep Awake runs with that option on.
    private func updateLid() {
        lid.update(wanted: awake.isAwake && store.settings.awakeLidClosed)
    }

    // MARK: - System events

    private func observeSystem() {
        // Posted when the Accessibility list changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // The permission database updates shortly after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshTrust(prompt: false) }
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshTrust(prompt: false)
                self?.engine.revalidate()
                self?.pointer.reapply()
            }
        }

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.engine.cancelGlide()
                self?.cancelRefresh()
            }
        }

        // With the display asleep nobody is scrolling or looking at the menu bar.
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelRefresh()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildScreens()
        }
    }

    private func refreshTrust(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let now = AXIsProcessTrustedWithOptions(options)
        updateTrustWatch(trusted: now)
        guard now != trusted || prompt else { return }
        NSLog("Meowse: accessibility trusted = %d", now ? 1 : 0)
        trusted = now
        engine.setTrusted(now)
        statusMenu.trusted = now
        store.accessibilityTrusted = now
    }

    /// The accessibility notification isn't delivered on every macOS release,
    /// so while access is missing (and only then) recheck every 2 s.
    private func updateTrustWatch(trusted: Bool) {
        if trusted {
            trustWatch?.cancel()
            trustWatch = nil
        } else if trustWatch == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.refreshTrust(prompt: false) }
            t.resume()
            trustWatch = t
        }
    }

    private func requestPermission() {
        refreshTrust(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// One paused display link per screen; the engine runs the one under the
    /// cursor while a glide is in flight.
    private func rebuildScreens() {
        let links: [Engine.ScreenLink] = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            let link = screen.displayLink(target: engine, selector: #selector(Engine.tick(_:)))
            let maxHz = Float(max(screen.maximumFramesPerSecond, 60))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxHz, preferred: maxHz)
            link.isPaused = true
            return Engine.ScreenLink(bounds: CGDisplayBounds(id), link: link)
        }
        engine.setScreens(links)
    }

    // MARK: - Memory refresh

    /// Display changes leave memory in every menu bar app that the system
    /// never takes back while the app runs (see `Refresh`). Once Meowse has
    /// grown enough, it starts over while the display is asleep.
    private func scheduleRefresh() {
        cancelRefresh()
        let work = DispatchWorkItem { [weak self] in self?.refreshIfDue() }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Refresh.settleDelay, execute: work)
    }

    private func cancelRefresh() {
        refresh?.cancel()
        refresh = nil
    }

    private func refreshIfDue() {
        refresh = nil
        let busy = awake.isAwake || awake.isWiggling || settingsHost.isOpen || updater.state == .installing
        guard Refresh.isDue(footprint: Self.footprint(), atLaunch: launchFootprint,
                            uptime: ProcessInfo.processInfo.systemUptime - launchUptime, busy: busy) else { return }
        NSLog("Meowse: restarting to return memory the system kept after display changes")
        NSApp.relaunch(Bundle.main.bundleURL)
    }

    /// What Activity Monitor shows as Memory, in bytes.
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // MARK: - Settings window

    /// A menu bar app shows nothing when it opens, so the first time, Settings
    /// opens on General, where Accessibility turning on can be watched.
    private func welcomeOnFirstLaunch() {
        let key = "welcomed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !trusted { showSettings(tab: .general) }
    }

    private func showSettings(tab: SettingsTab? = nil) {
        store.refreshLaunchAtLogin()
        refreshTrust(prompt: false)
        store.pointerInfo = pointer.info(externalOnly: store.settings.pointerExternalOnly)
        settingsHost.show(tab: tab)
    }

    /// Only Settings shows it, so it's read only while Settings is open.
    private func refreshPointerInfo() {
        if settingsHost.isOpen { store.pointerInfo = pointer.info(externalOnly: store.settings.pointerExternalOnly) }
    }

    /// Where each excluded app is now, and where it was when added, in case
    /// there are two copies.
    private static func paths(of apps: [ExcludedApp]) -> [String] {
        var paths: [String] = []
        for app in apps {
            for url in [NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID), URL(fileURLWithPath: app.path)] {
                if let path = url?.resolvingSymlinksInPath().path, !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        awake.stopAwake()
        lid.update(wanted: false)
        pointer.restore()
    }
}
