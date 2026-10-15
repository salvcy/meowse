import Foundation

/// User settings, persisted as JSON. Missing keys fall back to defaults, so
/// older payloads keep decoding as fields are added.
public struct Settings: Codable, Equatable, Sendable {
    // General
    public var enabled = true
    public var showMenuBarIcon = true

    // Mouse pointer. Nil follows the Mac's own setting.
    public var pointerAcceleration: Bool?
    /// Speed without acceleration: how many times as far each count goes.
    public var pointerSpeed: Double?
    /// A curve of the user's own: the pointer speed at a few mouse speeds.
    public var pointerCurve: [PointerCurves.Point]?
    /// Leave the Magic Mouse with the Mac's settings.
    public var pointerExternalOnly = true

    // Smoothing
    public var smooth = true
    public var smoothVertical = true
    public var smoothHorizontal = true
    /// Scroll distance: points one slow notch scrolls. Faster spins go farther.
    public var notchDistance = 100.0
    /// Smoothness: seconds a glide takes to cover 99% of its distance.
    public var glideTime = 0.5
    /// Mark glides with trackpad scroll and momentum phases, so apps
    /// rubber-band at the edges and treat the glide like a swipe.
    public var trackpadPhases = false

    // Direction
    public var reverseVertical = true
    public var reverseHorizontal = true

    /// Apps whose scrolling is left as it is.
    public var excludedApps: [ExcludedApp] = []

    // Hold while scrolling
    public var fasterKey: Hotkey = .modifier(.option)
    /// Turns vertical wheel input into horizontal scrolling.
    public var sidewaysKey: Hotkey = .modifier(.shift)
    /// Passes the wheel through unsmoothed (reverse still applies).
    public var unsmoothedKey: Hotkey = .modifier(.command)
    public var fasterFactor = 3.0

    /// A click stops a glide in flight.
    public var stopOnClick = true

    // Mouse buttons. The side buttons go back and forward everywhere, not
    // only in apps that read them.
    public var buttonShortcutsOn = true
    public var buttonShortcuts: [ButtonShortcut] = [
        ButtonShortcut(trigger: .button(3), keys: .back),
        ButtonShortcut(trigger: .button(4), keys: .forward),
    ]

    // Awake. Sessions aren't persisted; these preferences are.
    /// Keep the system awake but let the display sleep.
    public var awakeAllowDisplaySleep = false
    /// While Keep Awake is on, closing the lid doesn't sleep the Mac. Uses a
    /// helper an administrator approves once (see `Lid`).
    public var awakeLidClosed = false
    /// Wiggle the cursor after this many idle seconds.
    public var wiggleInterval: TimeInterval = 60

    // Updates
    public var checkForUpdates = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = Settings()
        func read<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { into = v }
        }
        read(.enabled, &s.enabled)
        read(.showMenuBarIcon, &s.showMenuBarIcon)
        read(.pointerAcceleration, &s.pointerAcceleration)
        read(.pointerSpeed, &s.pointerSpeed)
        read(.pointerCurve, &s.pointerCurve)
        read(.pointerExternalOnly, &s.pointerExternalOnly)
        read(.smooth, &s.smooth)
        read(.smoothVertical, &s.smoothVertical)
        read(.smoothHorizontal, &s.smoothHorizontal)
        read(.notchDistance, &s.notchDistance)
        read(.glideTime, &s.glideTime)
        read(.trackpadPhases, &s.trackpadPhases)
        read(.reverseVertical, &s.reverseVertical)
        read(.reverseHorizontal, &s.reverseHorizontal)
        read(.excludedApps, &s.excludedApps)
        read(.fasterKey, &s.fasterKey)
        read(.sidewaysKey, &s.sidewaysKey)
        read(.unsmoothedKey, &s.unsmoothedKey)
        read(.fasterFactor, &s.fasterFactor)
        read(.stopOnClick, &s.stopOnClick)
        read(.buttonShortcutsOn, &s.buttonShortcutsOn)
        read(.buttonShortcuts, &s.buttonShortcuts)
        read(.awakeAllowDisplaySleep, &s.awakeAllowDisplaySleep)
        read(.awakeLidClosed, &s.awakeLidClosed)
        read(.wiggleInterval, &s.wiggleInterval)
        read(.checkForUpdates, &s.checkForUpdates)

        // Stored values can be edited by hand. Keep them in the ranges the UI
        // offers, so the engine and timers never see a value they can't use.
        s.notchDistance = s.notchDistance.clamped(to: Self.notchDistanceRange)
        s.glideTime = s.glideTime.clamped(to: Self.glideTimeRange)
        s.fasterFactor = s.fasterFactor.clamped(to: Self.fasterFactorRange)
        s.wiggleInterval = s.wiggleInterval.clamped(to: Awake.wiggleIntervals.min()!...Awake.wiggleIntervals.max()!)
        s.pointerSpeed = s.pointerSpeed.map { $0.clamped(to: Pointer.speedRange) }
        if let curve = s.pointerCurve, curve.count != 3 || curve.contains(where: { !($0.x > 0 && $0.y >= 0 && $0.x.isFinite && $0.y.isFinite) }) {
            s.pointerCurve = nil
        }
        // One row per button or wheel direction.
        var triggers = Set<MouseTrigger>()
        s.buttonShortcuts = s.buttonShortcuts.filter { $0.trigger.isValid && triggers.insert($0.trigger).inserted }
        var apps = Set<String>()
        s.excludedApps = s.excludedApps.filter { apps.insert($0.bundleID).inserted }
        let defaults = Settings()
        if !s.fasterKey.isValid { s.fasterKey = defaults.fasterKey }
        if !s.sidewaysKey.isValid { s.sidewaysKey = defaults.sidewaysKey }
        if !s.unsmoothedKey.isValid { s.unsmoothedKey = defaults.unsmoothedKey }
        self = s
    }

    // Slider ranges in Settings.
    public static let notchDistanceRange = 20.0...200.0
    public static let glideTimeRange = 0.1...1.0
    public static let fasterFactorRange = 2.0...10.0
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
