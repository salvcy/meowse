import CoreGraphics
import Foundation

/// Settings resolved for the engine thread. Built on the main thread and
/// handed over as a value, so the event path reads plain stored fields.
public struct EngineConfig: Equatable, Sendable {
    public var smooth: Bool
    public var smoothVertical: Bool
    public var smoothHorizontal: Bool
    public var trackpadPhases: Bool
    public var reverseVertical: Bool
    public var reverseHorizontal: Bool
    public var notchDistance: Double
    /// Seconds for a glide's remaining distance to shrink by a factor of e.
    public var decay: Double
    public var fasterKey: Hotkey
    public var sidewaysKey: Hotkey
    public var unsmoothedKey: Hotkey
    public var fasterFactor: Double
    public var stopOnClick: Bool
    /// Bundle paths, each ending in "/", of apps whose scrolling is left alone.
    public var excludedPaths: [String]
    /// Keys each extra button presses, by CGEvent button number.
    public var buttonKeys: [Int: KeyCombo]
    public var wheelLeftKeys: KeyCombo?
    public var wheelRightKeys: KeyCombo?

    /// Events the tap must receive; 0 means no tap is needed. Clicks that
    /// stop a glide come from a separate tap that's on only mid-glide.
    public let eventMask: CGEventMask

    /// `excludedPaths` are where the excluded apps are now, if known.
    public init(_ s: Settings, excludedPaths: [String]? = nil) {
        let active = s.enabled
        smooth = active && s.smooth && (s.smoothVertical || s.smoothHorizontal)
        smoothVertical = s.smoothVertical
        smoothHorizontal = s.smoothHorizontal
        trackpadPhases = s.trackpadPhases
        reverseVertical = active && s.reverseVertical
        reverseHorizontal = active && s.reverseHorizontal
        notchDistance = max(1, s.notchDistance)
        // 99% of the distance is covered after ln(100) time constants.
        decay = max(0.01, s.glideTime) / log(100)
        fasterKey = s.fasterKey
        sidewaysKey = s.sidewaysKey
        unsmoothedKey = s.unsmoothedKey
        fasterFactor = max(1, s.fasterFactor)
        stopOnClick = s.stopOnClick
        self.excludedPaths = (excludedPaths ?? s.excludedApps.map(\.path)).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var buttons: [Int: KeyCombo] = [:]
        var left: KeyCombo?, right: KeyCombo?
        for shortcut in s.buttonShortcuts where s.buttonShortcutsOn {
            guard let keys = shortcut.keys else { continue }
            switch shortcut.trigger {
            case .button(let n): buttons[n] = keys
            case .wheel(let isLeft): if isLeft { left = keys } else { right = keys }
            }
        }
        buttonKeys = buttons
        wheelLeftKeys = left
        wheelRightKeys = right
        let effectiveHotkeys: [Hotkey]
        if smooth {
            effectiveHotkeys = [fasterFactor > 1 ? s.fasterKey : .none, s.sidewaysKey, s.unsmoothedKey]
        } else {
            effectiveHotkeys = reverseVertical != reverseHorizontal ? [s.sidewaysKey] : []
        }
        eventMask = EngineConfig.mask(
            smooth: smooth,
            reverse: reverseVertical || reverseHorizontal,
            hotkeys: effectiveHotkeys,
            buttons: !buttons.isEmpty,
            wheel: left != nil || right != nil
        )
    }

    /// Whether a side wheel turning this way presses keys.
    @inline(__always)
    public func wheelKeys(left: Bool) -> KeyCombo? { left ? wheelLeftKeys : wheelRightKeys }

    /// Whether a click should stop a glide in flight.
    public var stopsOnClick: Bool { smooth && stopOnClick }

    /// The smallest mask that serves the configuration. Keyboard events are
    /// never needed: modifier hotkeys come from the wheel event's flags, and
    /// shortcuts are only posted.
    static func mask(smooth: Bool, reverse: Bool, hotkeys: [Hotkey], buttons: Bool, wheel: Bool) -> CGEventMask {
        func bit(_ t: CGEventType) -> CGEventMask { 1 << CGEventMask(t.rawValue) }
        let scrolling = smooth || reverse
        var mask: CGEventMask = 0
        if scrolling || wheel { mask |= bit(.scrollWheel) }
        if buttons || (scrolling && hotkeys.contains(where: { $0.needsMouseButtonEvents })) {
            mask |= bit(.otherMouseDown) | bit(.otherMouseUp)
        }
        return mask
    }
}
