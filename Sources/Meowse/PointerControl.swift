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

    /// Called on the main thread when a mouse connects or disconnects.
    var onDevicesChange: (() -> Void)?
    /// Cached activity for the menu bar; a requested setting is not necessarily applied.
    var onActivityChange: ((Bool) -> Void)?
    private(set) var isActive = false {
        didSet { if isActive != oldValue { onActivityChange?(isActive) } }
    }

    private var wanted: PointerOverride?
    private var externalOnly = true
    /// What each mouse has from Meowse, by registry ID.
    private var applied: [UInt64: PointerOverride] = [:]
    /// Successful writes only; failed partial writes still need restoring on quit.
    private var confirmed: Set<UInt64> = []
    /// Mice given a table of Meowse's, which gets the mouse's own back afterwards.
    private var tables: Set<UInt64> = []
    /// Held only while Meowse's settings are applied.
    private var client: IOHIDEventSystemClient?
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var pending: DispatchWorkItem?

    private static let accelerationKey = "HIDMouseAcceleration" as CFString
    private static let linearKey = "HIDUseLinearScalingMouseAcceleration" as CFString
    private static let curvesKey = "UserPointerAccelCurvesKey" as CFString
    private static let tableKey = "HIDPointerAccelerationTable" as CFString

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
        let customized = settings.pointerCustomized
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
        confirmed.removeAll()
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
        let mice = Self.mice(c)
        for mouse in mice {
            guard let id = (IOHIDServiceClientGetRegistryID(mouse) as? NSNumber)?.uint64Value else { continue }
            if let wanted, !externalOnly || !Self.isApple(mouse) {
                if applied[id] != wanted {
                    if set(mouse, id, wanted) {
                        confirmed.insert(id)
                    } else {
                        confirmed.remove(id)
                    }
                    applied[id] = wanted
                }
            } else if applied.removeValue(forKey: id) != nil {
                confirmed.remove(id)
                set(mouse, id, mac.own)
            }
        }
        if wanted == nil { applied.removeAll(); confirmed.removeAll() }
        updateActivity(mice)
    }

    /// A disconnection only updates bookkeeping; it must not apply settings
    /// to a different mouse that may still be finishing its setup.
    private func updateActivity(_ mice: [IOHIDServiceClient]) {
        let connected = Set(mice.compactMap { (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value })
        applied = applied.filter { connected.contains($0.key) }
        confirmed.formIntersection(connected)
        tables.formIntersection(connected)
        isActive = mice.contains { mouse in
            guard Self.isMouse(mouse), let id = (IOHIDServiceClientGetRegistryID(mouse) as? NSNumber)?.uint64Value else { return false }
            return confirmed.contains(id)
        }
    }

    @discardableResult
    private func set(_ mouse: IOHIDServiceClient, _ id: UInt64, _ o: PointerOverride) -> Bool {
        let fixed = { (v: Double) in NSNumber(value: Int64((v * 65536).rounded())) }
        func dictionary(_ c: PointerCurves.Parametric) -> [String: NSNumber] {
            ["HIDAccelIndex": fixed(c.index), "HIDAccelGainLinear": fixed(c.gainLinear),
             "HIDAccelGainParabolic": fixed(c.gainParabolic), "HIDAccelGainCubic": fixed(c.gainCubic),
             "HIDAccelGainQuartic": fixed(c.gainQuartic), "HIDAccelTangentSpeedLinear": fixed(c.tangentLinear),
             "HIDAccelTangentSpeedParabolicRoot": fixed(c.tangentRoot)]
        }
        // Curves of Meowse's replace the mouse's; an empty list gives its own back.
        var curves = o.curve.map { [dictionary($0)] } ?? []
        var table: Data?
        if o.curve == nil, !o.isLine, o.scale != 1, let own = Self.curves(mouse) {
            // The mouse's own curve made faster or slower, in the form it comes in.
            let scaled = own.scaled(o.scale)
            if scaled.parametric.isEmpty {
                table = PointerCurves.data(scaled.tables)
            } else {
                curves = scaled.parametric.map(dictionary)
            }
        }
        var ok = true
        if let table {
            ok = IOHIDServiceClientSetProperty(mouse, Self.tableKey, table as CFData)
            tables.insert(id)
        } else if tables.remove(id) != nil, let own = Self.curves(mouse) {
            ok = IOHIDServiceClientSetProperty(mouse, Self.tableKey, PointerCurves.data(own.tables) as CFData)
        }
        // The table isn't read until one of these changes, so it goes first.
        ok = IOHIDServiceClientSetProperty(mouse, Self.curvesKey, curves as CFArray)
            && IOHIDServiceClientSetProperty(mouse, Self.linearKey, NSNumber(value: o.linear ? 1 : 0))
            && IOHIDServiceClientSetProperty(mouse, Self.accelerationKey, fixed(o.acceleration))
            && ok
        if !ok { NSLog("Meowse: couldn't set the pointer settings") }
        return ok
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

    /// A mouse's own curves, from its registry entry. What Meowse sets lives
    /// elsewhere on it, so these stay the mouse's.
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
            if removed != 0 { IOObjectRelease(removed); removed = 0 }
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
        let removal: IOServiceMatchingCallback = { refcon, iterator in
            PointerControl.drain(iterator)
            let control = Unmanaged<PointerControl>.fromOpaque(refcon!).takeUnretainedValue()
            if let client = control.client { control.updateActivity(PointerControl.mice(client)) }
            control.onDevicesChange?()
        }
        IOServiceAddMatchingNotification(newPort, kIOTerminatedNotification, IOServiceMatching("IOHIDEventService"),
                                         removal, Unmanaged.passUnretained(self).toOpaque(), &removed)
        Self.drain(removed)
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
