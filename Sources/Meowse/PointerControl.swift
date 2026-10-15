import Foundation
import IOKit
import IOKit.hidsystem
import MeowseCore

/// Gives each mouse the pointer settings Meowse's settings ask for (see
/// `PointerOverride`), and puts the Mac's own back when they no longer ask
/// or Meowse quits. The system applies them, so pointer movement never
/// passes through Meowse. Nothing is watched or held while the Mac's
/// settings are followed.
final class PointerControl {

    /// Called on the main thread when a mouse connects.
    var onDevicesChange: (() -> Void)?

    private var wanted: PointerOverride?
    private var externalOnly = true
    /// What each mouse has from Meowse, by registry ID.
    private var applied: [UInt64: PointerOverride] = [:]
    /// Held only while Meowse's settings are applied.
    private var client: IOHIDEventSystemClient?
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var pending: DispatchWorkItem?

    private static let accelerationKey = "HIDMouseAcceleration" as CFString
    private static let linearKey = "HIDUseLinearScalingMouseAcceleration" as CFString
    private static let curvesKey = "UserPointerAccelCurvesKey" as CFString

    /// A passive HID client. The public simple client may set only the
    /// Tracking speed value; this one may also set a curve and turn
    /// acceleration off. It's private API, looked up when used, so a macOS
    /// without it leaves the Mac's settings alone (`PointerInfo.adjustable`).
    private static let createClient: (@convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<IOHIDEventSystemClient>?)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventSystemClientCreateWithType") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<IOHIDEventSystemClient>?).self)
    }()
    private static let passive: Int32 = 2

    private func connection() -> IOHIDEventSystemClient? {
        client ?? Self.createClient?(kCFAllocatorDefault, Self.passive, nil)?.takeRetainedValue()
    }

    /// Applies the settings, or the Mac's own when they have none.
    func update(_ settings: Settings) {
        let customized = settings.pointerAcceleration != nil || settings.pointerSpeed != nil || settings.pointerCurve != nil
        guard customized || !applied.isEmpty, let c = connection() else { return }
        let mac = Self.macSettings(c)
        wanted = customized ? Pointer.override(settings, mac: mac) : nil
        externalOnly = settings.pointerExternalOnly
        sync(c, mac)
        if wanted != nil {
            client = c
            watchDevices(true)
        } else {
            watchDevices(false)
            client = nil
        }
    }

    /// Gives every mouse its settings again, after something else (a wake,
    /// a mouse connecting) may have reset them.
    func reapply() {
        guard wanted != nil, let client else { return }
        applied.removeAll()
        sync(client, Self.macSettings(client))
    }

    /// Restores the Mac's settings, on quit.
    func restore() {
        guard !applied.isEmpty, let c = connection() else { return }
        wanted = nil
        sync(c, Self.macSettings(c))
    }

    /// The Mac's settings and the curves of the mouse Meowse would change, for Settings.
    func info(externalOnly: Bool) -> PointerInfo {
        guard let c = connection() else {
            return PointerInfo(acceleration: 1, linear: false, curves: nil, adjustable: false)
        }
        var info = Self.macSettings(c)
        info.curves = Self.mice(c).first { !externalOnly || !Self.isApple($0) }.flatMap(Self.curves)
        return info
    }

    // MARK: - Services

    private func sync(_ c: IOHIDEventSystemClient, _ mac: PointerInfo) {
        for mouse in Self.mice(c) {
            guard let id = (IOHIDServiceClientGetRegistryID(mouse) as? NSNumber)?.uint64Value else { continue }
            if let wanted, !externalOnly || !Self.isApple(mouse) {
                if applied[id] != wanted {
                    Self.set(mouse, wanted)
                    applied[id] = wanted
                }
            } else if applied.removeValue(forKey: id) != nil {
                Self.set(mouse, mac.own)
            }
        }
        if wanted == nil { applied.removeAll() }
    }

    private static func set(_ mouse: IOHIDServiceClient, _ o: PointerOverride) {
        let fixed = { (v: Double) in NSNumber(value: Int64((v * 65536).rounded())) }
        // An empty list gives the mouse its own curves back.
        let curves: [[String: NSNumber]] = o.curve.map { c in
            [["HIDAccelIndex": fixed(c.index), "HIDAccelGainLinear": fixed(c.gainLinear),
              "HIDAccelGainParabolic": fixed(c.gainParabolic), "HIDAccelGainCubic": fixed(c.gainCubic),
              "HIDAccelGainQuartic": fixed(c.gainQuartic), "HIDAccelTangentSpeedLinear": fixed(c.tangentLinear),
              "HIDAccelTangentSpeedParabolicRoot": fixed(c.tangentRoot)]]
        } ?? []
        let ok = IOHIDServiceClientSetProperty(mouse, curvesKey, curves as CFArray)
            && IOHIDServiceClientSetProperty(mouse, linearKey, NSNumber(value: o.linear ? 1 : 0))
            && IOHIDServiceClientSetProperty(mouse, accelerationKey, fixed(o.acceleration))
        if !ok { NSLog("Meowse: couldn't set the pointer settings") }
    }

    /// Services whose pointer follows the mouse Tracking speed, the
    /// connected mice first. Keyboards with a pointer part are in the list
    /// too: they never move it, and they accept the settings harmlessly.
    private static func mice(_ client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let mice = all.filter {
            (IOHIDServiceClientCopyProperty($0, "HIDPointerAccelerationType" as CFString) as? String) == accelerationKey as String
        }
        return mice.filter { isMouse($0) } + mice.filter { !isMouse($0) }
    }

    private static func isMouse(_ s: IOHIDServiceClient) -> Bool {
        (IOHIDServiceClientCopyProperty(s, kIOHIDPrimaryUsagePageKey as CFString) as? Int) == kHIDPage_GenericDesktop
            && (IOHIDServiceClientCopyProperty(s, kIOHIDPrimaryUsageKey as CFString) as? Int) == kHIDUsage_GD_Mouse
    }

    /// The Magic Mouse, which "external mice only" leaves alone.
    private static func isApple(_ s: IOHIDServiceClient) -> Bool {
        Pointer.isApple(vendor: IOHIDServiceClientCopyProperty(s, kIOHIDVendorIDKey as CFString) as? Int ?? 0)
    }

    /// A mouse's curves, from its registry entry.
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
        let value = (IOHIDEventSystemClientCopyProperty(client, accelerationKey) as? NSNumber).map { $0.doubleValue / 65536 }
            ?? UserDefaults.standard.double(forKey: "com.apple.mouse.scaling")
        let linear = (IOHIDEventSystemClientCopyProperty(client, linearKey) as? NSNumber)?.boolValue
            ?? UserDefaults.standard.bool(forKey: "com.apple.mouse.linear")
        return PointerInfo(acceleration: value, linear: linear, curves: nil)
    }

    // MARK: - New mice

    /// A mouse that connects gets the Mac's settings from the system;
    /// Meowse's follow shortly after. Watched only while they're applied.
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
        // The HID system sets up the new service and gives it the Mac's settings first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
