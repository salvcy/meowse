import AppKit
import Combine
import MeowseCore

/// The pipe to Meowse: messages arrive on standard input and actions leave on
/// standard output. Meowse quitting closes standard input, which closes this
/// window too.
final class Connection {

    static let shared = Connection()

    var onMessage: ((ToSettings) -> Void)?
    private var reader = LineReader()

    func start() {
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { Connection.shared.received(data) }
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        for line in reader.feed(data) {
            if let message = SettingsLink.decode(ToSettings.self, from: line) {
                onMessage?(message)
            }
        }
    }

    func send(_ action: SettingsAction) {
        guard let data = SettingsLink.encode(action) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

/// Meowse's state as the views see it, under the names they've always used.
/// Edits go to Meowse, and its replies come back as state; a toggle shows
/// its new value right away and Meowse confirms it.
final class Remote {

    let store = SettingsStore()
    let awake = AwakeController()
    let updater = Updater()

    func apply(_ s: SettingsState) {
        if let settings = s.settings, settings != store.settings {
            store.applying = true
            store.settings = settings
            store.applying = false
        }
        update(&store.accessibilityTrusted, s.trusted)
        update(&store.engineStatus, s.engine)
        update(&store.scrollDevice, s.device)
        update(&store.touchKind, s.touch)
        update(&store.pointer, s.pointer)
        update(&store.launchAtLogin, s.launchAtLogin)
        update(&awake.isAwake, s.awake)
        update(&awake.awakeUntil, s.awakeUntil)
        update(&awake.isWiggling, s.wiggling)
        update(&updater.currentVersion, s.version)
        update(&updater.state, s.update)
        update(&updater.lastChecked, s.lastChecked)
        update(&updater.availableVersion, s.availableVersion)
        if let notes = s.availableNotes { update(&updater.availableNotes, notes) }
        update(&updater.releasePage, s.releasePage)
    }

    /// Assigning publishes even an equal value, which would redraw the views.
    private func update<T: Equatable>(_ field: inout T, _ value: T) {
        if field != value { field = value }
    }
}

final class SettingsStore: ObservableObject {
    @Published var settings = Settings() {
        didSet {
            if settings != oldValue && !applying { Connection.shared.send(.settings(settings)) }
        }
    }
    @Published fileprivate(set) var accessibilityTrusted = false
    @Published fileprivate(set) var engineStatus = EngineStatus.off
    @Published fileprivate(set) var scrollDevice: ScrollDevice?
    @Published fileprivate(set) var touchKind: TouchKind?
    @Published fileprivate(set) var launchAtLogin = false
    @Published fileprivate(set) var pointer: PointerInfo?
    /// Set while Meowse's settings are applied, so they aren't sent back.
    fileprivate var applying = false

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        Connection.shared.send(.launchAtLogin(on))
    }

    func openLoginItems() {
        Connection.shared.send(.openLoginItems)
    }
}

final class AwakeController: ObservableObject {
    @Published fileprivate(set) var isAwake = false
    @Published fileprivate(set) var awakeUntil: Date?
    @Published fileprivate(set) var isWiggling = false

    // Meowse starts sessions with the duration and interval in its settings,
    // which this window keeps current.
    func startAwake(duration: TimeInterval, allowDisplaySleep: Bool) {
        isAwake = true
        Connection.shared.send(.keepAwake(true))
    }

    func stopAwake() {
        isAwake = false
        Connection.shared.send(.keepAwake(false))
    }

    func startWiggle(interval: TimeInterval) {
        isWiggling = true
        Connection.shared.send(.wiggle(true))
    }

    func stopWiggle() {
        isWiggling = false
        Connection.shared.send(.wiggle(false))
    }
}

final class Updater: ObservableObject {
    @Published fileprivate(set) var state = UpdateStatus.idle
    @Published fileprivate(set) var lastChecked: Date?
    @Published fileprivate(set) var currentVersion = ""
    @Published fileprivate(set) var availableVersion: String?
    @Published fileprivate(set) var availableNotes = ""
    @Published fileprivate(set) var releasePage: URL?

    func check(userInitiated: Bool) {
        Connection.shared.send(.checkForUpdates)
    }

    func install() {
        Connection.shared.send(.installUpdate)
    }
}
