import Foundation
import IOKit
import IOKit.hidsystem
import MeowseCore

/// Gives each mouse the acceleration value Meowse's settings ask for, the
/// same number System Settings' Tracking speed sets (see `PointerCurves`),
/// and puts the Mac's own value back when they no longer ask or Meowse quits.
/// Nothing is watched or held while the Mac's setting is followed.
final class PointerControl {

    /// Called on the main thread when a mouse connects.
    var onDevicesChange: (() -> Void)?

    private var wanted: Double?
    /// Set while a value of Meowse's is on the mice.
    private var applied = false
    /// Held only while Meowse's value is applied.
    private var client: IOHIDEventSystemClient?
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var pending: DispatchWorkItem?

    private static let key = "HIDMouseAcceleration" as CFString
    private static let linearKey = "HIDUseLinearScalingMouseAcceleration" as CFString

    private func connection() -> IOHIDEventSystemClient {
        client ?? IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    }

    /// Applies the settings' value, or the Mac's when they have none.
    func update(_ settings: Settings) {
        let following = settings.pointerAcceleration == nil && settings.pointerSpeed == nil
        guard !following || applied else { return }
        let c = connection()
        let mac = Self.macSettings(c)
        wanted = Pointer.value(settings, mac: mac)
        if let wanted {
            client = c
            apply(wanted, c)
            applied = true
            watchDevices(true)
        } else {
            apply(mac.acceleration, c)
            applied = false
            watchDevices(false)
            client = nil
        }
    }

    /// Puts the value back after something else may have reset it.
    func reapply() {
        if let wanted, let client { apply(wanted, client) }
    }

    /// Restores the Mac's value, on quit.
    func restore() {
        guard applied else { return }
        let c = connection()
        apply(Self.macSettings(c).acceleration, c)
        applied = false
    }

    /// The Mac's settings and the curves of the mouse in use, for Settings.
    func info() -> PointerInfo {
        let c = connection()
        var info = Self.macSettings(c)
        info.curves = Self.mice(c).first.flatMap(Self.curves)
        return info
    }

    // MARK: - Services

    private func apply(_ value: Double, _ client: IOHIDEventSystemClient) {
        let fixed = NSNumber(value: Int32((value * 65536).rounded()))
        for mouse in Self.mice(client) {
            if (IOHIDServiceClientCopyProperty(mouse, Self.key) as? NSNumber) == fixed { continue }
            if !IOHIDServiceClientSetProperty(mouse, Self.key, fixed) {
                NSLog("Meowse: couldn't set pointer acceleration")
            }
        }
    }

    /// Services whose pointer follows the mouse Tracking speed, the
    /// connected mice first. Keyboards with a pointer part are in the list
    /// too: they never move it, and they accept the value harmlessly.
    private static func mice(_ client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let mice = all.filter {
            (IOHIDServiceClientCopyProperty($0, "HIDPointerAccelerationType" as CFString) as? String) == key as String
        }
        return mice.filter { isMouse($0) } + mice.filter { !isMouse($0) }
    }

    private static func isMouse(_ s: IOHIDServiceClient) -> Bool {
        (IOHIDServiceClientCopyProperty(s, kIOHIDPrimaryUsagePageKey as CFString) as? Int) == kHIDPage_GenericDesktop
            && (IOHIDServiceClientCopyProperty(s, kIOHIDPrimaryUsageKey as CFString) as? Int) == kHIDUsage_GD_Mouse
    }

    /// A mouse's curves, from its registry entry (apps can't read them through the HID client).
    private static func curves(_ mouse: IOHIDServiceClient) -> PointerCurves? {
        guard let id = (IOHIDServiceClientGetRegistryID(mouse) as? NSNumber)?.uint64Value else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let fixed = { (v: Any?) in (v as? NSNumber).map { $0.doubleValue / 65536 } ?? 0 }
        let parametric = (property("HIDAccelCurves") as? [[String: Any]] ?? []).map {
            PointerCurves.Parametric(
                index: fixed($0["HIDAccelIndex"]),
                gainLinear: fixed($0["HIDAccelGainLinear"]),
                gainParabolic: fixed($0["HIDAccelGainParabolic"]),
                gainCubic: fixed($0["HIDAccelGainCubic"]),
                gainQuartic: fixed($0["HIDAccelGainQuartic"]),
                tangentLinear: fixed($0["HIDAccelTangentSpeedLinear"]),
                tangentRoot: fixed($0["HIDAccelTangentSpeedParabolicRoot"]))
        }
        let tables = (property("HIDPointerAccelerationTable") as? Data).flatMap(PointerCurves.tables(from:)) ?? []
        return PointerCurves(parametric: parametric, tables: tables, resolution: fixed(property("HIDPointerResolution")))
    }

    /// What System Settings has set, which Meowse never changes: its values
    /// live on the HID system as a whole, Meowse's on each mouse.
    private static func macSettings(_ client: IOHIDEventSystemClient) -> PointerInfo {
        let value = (IOHIDEventSystemClientCopyProperty(client, key) as? NSNumber).map { $0.doubleValue / 65536 }
            ?? UserDefaults.standard.double(forKey: "com.apple.mouse.scaling")
        let linear = (IOHIDEventSystemClientCopyProperty(client, linearKey) as? NSNumber)?.boolValue
            ?? UserDefaults.standard.bool(forKey: "com.apple.mouse.linear")
        return PointerInfo(acceleration: value, linear: linear, curves: nil)
    }

    // MARK: - New mice

    /// A mouse that connects gets the Mac's value from the system; Meowse's
    /// follows shortly after. Watched only while Meowse has a value applied.
    private func watchDevices(_ on: Bool) {
        if !on {
            pending?.cancel()
            pending = nil
            if added != 0 { IOObjectRelease(added); added = 0 }
            if let port { IONotificationPortDestroy(port) }
            port = nil
            return
        }
        guard port == nil, let newPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = newPort
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(newPort).takeUnretainedValue(), .defaultMode)
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            PointerControl.drain(iterator)
            Unmanaged<PointerControl>.fromOpaque(refcon!).takeUnretainedValue().deviceAdded()
        }
        IOServiceAddMatchingNotification(newPort, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
                                         callback, Unmanaged.passUnretained(self).toOpaque(), &added)
        Self.drain(added)  // arms the notification
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    private func deviceAdded() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.reapply()
            self?.onDevicesChange?()
        }
        pending = work
        // The HID system sets up the new service and gives it the Mac's value first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
