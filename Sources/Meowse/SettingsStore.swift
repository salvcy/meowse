import Foundation
import Combine
import ServiceManagement
import MeowseCore

/// Main-thread owner of `Settings`. Changes apply immediately; writes to disk
/// are throttled to at most one per half second while edits continue.
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()
    private static let key = "settings.v1"

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            onChange?(settings, oldValue)
        }
    }

    /// Runtime state, not persisted.
    @Published var accessibilityTrusted = false
    @Published var engineStatus: Engine.TapStatus = .off
    /// The device behind the last scroll while the engine runs; nil until one is seen.
    @Published private(set) var scrollDevice: ScrollDevice?
    /// Which touch surface, when `scrollDevice` is `.touch` and it could be told.
    @Published private(set) var touchKind: TouchKind?
    /// Cached so view updates never query the login-item service.
    @Published private(set) var launchAtLogin = false
    /// The Mac's pointer settings and the mouse's curves, read when Settings opens.
    @Published var pointerInfo: PointerInfo?

    private var savePending = false

    var onChange: ((Settings, Settings) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
            // A payload from an earlier version is rewritten once, so keys it
            // no longer uses don't linger.
            if let current = Self.encode(decoded), current != data {
                UserDefaults.standard.set(current, forKey: Self.key)
            }
        } else {
            settings = Settings()
        }
    }

    /// Sorted keys, so unchanged settings always encode to the same bytes.
    private static func encode(_ settings: Settings) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(settings)
    }

    /// At most one write per 0.5 s.
    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.flush()
        }
    }

    /// Writes pending changes now. Also called on quit.
    func flush() {
        guard savePending else { return }
        savePending = false
        if let data = Self.encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func setScrollDevice(_ device: ScrollDevice?, touch: TouchKind? = nil) {
        if device != scrollDevice { scrollDevice = device }
        if touch != touchKind { touchKind = touch }
    }

    // MARK: Launch at login

    /// Re-reads the login item status, which can also change in System Settings.
    func refreshLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Meowse: launch-at-login change failed: \(error)")
        }
        refreshLaunchAtLogin()
    }
}
