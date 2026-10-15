import Foundation
import IOKit.ps
import ServiceManagement
import MeowseCore

/// Keeps the Mac awake with the lid closed while Keep Awake runs with that
/// option on, through the lid helper (see `Lid`). The XPC connection exists
/// only while holding: if Meowse quits or crashes it drops and the helper turns
/// sleep back on. On battery, a low charge lets go too; the power source is
/// watched only while a hold is wanted.
final class LidHold {

    enum State: Equatable {
        case idle
        /// macOS needs an administrator to allow the helper in System Settings.
        case needsApproval
        case lowBattery
        case holding
        case failed
    }

    private(set) var state = State.idle { didSet { if state != oldValue { onChange() } } }
    var onChange: () -> Void = {}

    private let app = Bundle.main.bundleIdentifier ?? "app.meowse.Meowse"
    private lazy var service = SMAppService.daemon(plistName: Lid.service(forApp: app) + ".plist")
    private var connection: NSXPCConnection?
    private var wanted = false
    private var power: CFRunLoopSource?

    /// macOS still needs an administrator to allow the helper.
    var needsApproval: Bool { service.status != .enabled }

    /// Opens Login Items in System Settings, where the helper is allowed,
    /// registering it first if it isn't yet.
    func openApproval() {
        if service.status == .notRegistered || service.status == .notFound { try? service.register() }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Registers the helper, and opens System Settings if an administrator
    /// still has to allow it. Run when the option is turned on by hand.
    func prepare() {
        if service.status != .enabled && service.status != .requiresApproval {
            do {
                try service.register()
            } catch {
                NSLog("Meowse: lid helper not registered: \(error)")
            }
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Holds while `wanted` and the battery allows; lets go otherwise. Cheap
    /// to call again, e.g. when the menu opens after the helper was approved.
    func update(wanted: Bool) {
        self.wanted = wanted
        watchPower(wanted)
        guard wanted else { return release(.idle) }
        guard service.status == .enabled else { return release(.needsApproval) }
        let battery = Self.battery()
        guard Lid.shouldHold(keepAwake: true, enabled: true, onBattery: battery.onBattery, charge: battery.charge) else {
            return release(.lowBattery)
        }
        hold()
    }

    // MARK: - Helper

    private func hold() {
        guard state != .holding || connection == nil else { return }
        let c = connection ?? connect()
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self, weak c] _ in
            DispatchQueue.main.async { self?.lost(c) }
        } as? LidService
        proxy?.hold(true) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.wanted, self.connection === c else { return }
                self.state = ok ? .holding : .failed
            }
        }
    }

    private func connect() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: Lid.service(forApp: app), options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: LidService.self)
        // The helper ends its hold when this connection does, and if it
        // restarted it undid the hold already, so either way it's gone.
        c.invalidationHandler = { [weak self, weak c] in DispatchQueue.main.async { self?.lost(c) } }
        c.interruptionHandler = { [weak self, weak c] in DispatchQueue.main.async { self?.lost(c) } }
        c.resume()
        connection = c
        return c
    }

    private func lost(_ c: NSXPCConnection?) {
        guard let c, c === connection else { return }
        connection = nil
        c.invalidate()
        if wanted { state = .failed }
    }

    private func release(_ next: State) {
        state = next
        guard let c = connection else { return }
        connection = nil
        // Ending the connection is enough; asking first just lets go sooner.
        (c.remoteObjectProxy as? LidService)?.hold(false) { _ in c.invalidate() }
    }

    // MARK: - Battery

    private static func battery() -> (onBattery: Bool, charge: Int) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (false, 100)
        }
        let onBattery = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (onBattery, now * 100 / max)
        }
        return (onBattery, 100)
    }

    /// Power source changes, posted by the system, re-check the battery.
    private func watchPower(_ on: Bool) {
        if on, power == nil {
            let me = Unmanaged.passUnretained(self).toOpaque()
            power = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let hold = Unmanaged<LidHold>.fromOpaque(context).takeUnretainedValue()
                hold.update(wanted: hold.wanted)
            }, me)?.takeRetainedValue()
            if let power { CFRunLoopAddSource(CFRunLoopGetMain(), power, .defaultMode) }
        } else if !on, let source = power {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            power = nil
        }
    }
}
