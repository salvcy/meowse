import AppKit
import Combine
import MeowseCore

/// Runs the Settings window as its own process, Meowse Settings.app inside
/// this bundle, so the SwiftUI it loads goes back to the system when the
/// window closes. One pipe each way; while the window is closed there's no
/// process, pipe or observer at all.
final class SettingsHost {

    private let store: SettingsStore
    private let awake: AwakeController
    private let updater: Updater
    var requestPermission: () -> Void = {}
    var openLoginItems: () -> Void = {}

    private var process: Process?
    private var toWindow: FileHandle?
    private var fromWindow: FileHandle?
    private var reader = LineReader()
    private var observers: AnyCancellable?
    private var statePending = false
    /// The settings the window has, so they're sent only when Meowse changed them.
    private var windowSettings: Settings?
    /// The rest of what the window shows, as last sent.
    private var shown: SettingsState?

    init(store: SettingsStore, awake: AwakeController, updater: Updater) {
        self.store = store
        self.awake = awake
        self.updater = updater
    }

    private let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Meowse Settings.app")

    var isOpen: Bool { process != nil }

    func show(tab: SettingsTab? = nil) {
        guard process != nil || launch() else { return }
        // A background app can't take focus on its own; this one may.
        if let id = Bundle(url: helper)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
        }
        send(.show(tab))
    }

    private func launch() -> Bool {
        let p = Process()
        p.executableURL = helper.appendingPathComponent("Contents/MacOS/Meowse Settings")
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        // A window that just closed mustn't reach or end one opened after it.
        output.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { if let self, self.process === p { self.received(data) } }
        }
        p.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async { if self?.process === exited { self?.ended() } }
        }
        do {
            try p.run()
        } catch {
            NSLog("Meowse: couldn't open Settings: \(error)")
            output.fileHandleForReading.readabilityHandler = nil
            return false
        }
        process = p
        toWindow = input.fileHandleForWriting
        fromWindow = output.fileHandleForReading

        // Changes fire before they happen; the state goes out once per run loop turn.
        observers = Publishers.Merge3(store.objectWillChange, awake.objectWillChange, updater.objectWillChange)
            .sink { [weak self] _ in self?.scheduleState() }
        sendState()
        return true
    }

    private func ended() {
        guard process != nil else { return }
        fromWindow?.readabilityHandler = nil
        try? toWindow?.close()
        try? fromWindow?.close()
        observers = nil
        process = nil
        toWindow = nil
        fromWindow = nil
        reader = LineReader()
        windowSettings = nil
        shown = nil
        statePending = false
    }

    // MARK: - Messages

    private func received(_ data: Data) {
        guard !data.isEmpty else { return ended() }
        for line in reader.feed(data) {
            if let action = SettingsLink.decode(SettingsAction.self, from: line) {
                perform(action)
            }
        }
    }

    private func perform(_ action: SettingsAction) {
        switch action {
        case .settings(let settings):
            windowSettings = settings
            store.settings = settings
        case .requestPermission:
            requestPermission()
        case .launchAtLogin(let on):
            shown?.launchAtLogin = on
            store.setLaunchAtLogin(on)
            scheduleState()  // the window showed the change already; confirm or undo it
        case .keepAwake(let on):
            shown?.awake = on  // the window shows these at once too
            if on {
                awake.startAwake(duration: 0, allowDisplaySleep: store.settings.awakeAllowDisplaySleep)
            } else {
                awake.stopAwake()
            }
        case .wiggle(let on):
            shown?.wiggling = on
            on ? awake.startWiggle(interval: store.settings.wiggleInterval) : awake.stopWiggle()
        case .checkForUpdates:
            updater.check(userInitiated: true)
        case .installUpdate:
            updater.install()
        case .openLoginItems:
            openLoginItems()
        }
    }

    private func scheduleState() {
        guard !statePending, process != nil else { return }
        statePending = true
        DispatchQueue.main.async { [weak self] in
            self?.statePending = false
            self?.sendState()
        }
    }

    private func sendState() {
        var s = SettingsState()
        s.trusted = store.accessibilityTrusted
        s.engine = store.engineStatus
        s.device = store.scrollDevice
        s.touch = store.touchKind
        s.pointer = store.pointerInfo
        s.launchAtLogin = store.launchAtLogin
        s.awake = awake.isAwake
        s.awakeUntil = awake.awakeUntil
        s.wiggling = awake.isWiggling
        s.version = updater.currentVersion.description
        s.update = updater.state
        s.lastChecked = updater.lastChecked
        s.availableVersion = updater.availableVersion
        s.availableNotes = updater.availableNotes
        s.releasePage = updater.releasePage
        // Nothing the window shows changed, as after its own edits.
        let settingsChanged = store.settings != windowSettings
        guard settingsChanged || s != shown else { return }
        let full = s
        if s.availableNotes == shown?.availableNotes { s.availableNotes = nil }  // it keeps the ones it has
        shown = full
        if settingsChanged {
            s.settings = store.settings
            windowSettings = store.settings
        }
        send(.state(s))
    }

    private func send(_ message: ToSettings) {
        guard let toWindow, let data = SettingsLink.encode(message) else { return }
        // Fails harmlessly if the window just closed; SIGPIPE is ignored.
        try? toWindow.write(contentsOf: data)
    }
}
