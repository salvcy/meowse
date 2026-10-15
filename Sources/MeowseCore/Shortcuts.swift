import CoreGraphics

/// A key combination that a mouse button presses, as recorded in Settings.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// Virtual key code, independent of the keyboard layout.
    public var keyCode: UInt16
    /// CGEventFlags; only command, option, control and shift are kept.
    public var modifiers: UInt64
    /// The key as it was labelled when recorded: "W", "]", "↩".
    public var key: String

    public static let modifierMask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    public init(keyCode: UInt16, modifiers: UInt64, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
        self.key = key
    }

    /// Flags for posting it. A keyboard marks the arrows, and the keys an
    /// Fn key reaches on a laptop, with the function flag (the arrows with
    /// the keypad flag too); system shortcuts such as Mission Control's ⌃↑
    /// match only with them.
    public var eventFlags: UInt64 {
        var flags = modifiers
        switch keyCode {
        case 123...126:
            flags |= CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskNumericPad.rawValue
        case 115, 116, 117, 119, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90:
            flags |= CGEventFlags.maskSecondaryFn.rawValue
        default:
            break
        }
        return flags
    }

    /// Common actions for mouse buttons, so the side buttons can go back
    /// and forward without recording anything.
    public static let presets: [(name: String, keys: KeyCombo)] = {
        let cmd = CGEventFlags.maskCommand.rawValue, ctrl = CGEventFlags.maskControl.rawValue
        let shift = CGEventFlags.maskShift.rawValue
        return [
            ("Back", KeyCombo(keyCode: 33, modifiers: cmd, key: "[")),
            ("Forward", KeyCombo(keyCode: 30, modifiers: cmd, key: "]")),
            ("Previous Tab", KeyCombo(keyCode: 48, modifiers: ctrl | shift, key: "⇥")),
            ("Next Tab", KeyCombo(keyCode: 48, modifiers: ctrl, key: "⇥")),
            ("Mission Control", KeyCombo(keyCode: 126, modifiers: ctrl, key: "↑")),
            ("App Windows", KeyCombo(keyCode: 125, modifiers: ctrl, key: "↓")),
            ("Space Left", KeyCombo(keyCode: 123, modifiers: ctrl, key: "←")),
            ("Space Right", KeyCombo(keyCode: 124, modifiers: ctrl, key: "→")),
        ]
    }()

    public static let back = presets[0].keys
    public static let forward = presets[1].keys

    /// The preset's name, or the keys: "Back", "⌘W".
    public var name: String {
        Self.presets.first { $0.keys.keyCode == keyCode && $0.keys.modifiers == modifiers }?.name ?? displayName
    }

    /// "⇧⌘ ]", in the order macOS menus use.
    public var displayName: String {
        var s = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        // A symbol key reads better set apart from the modifiers.
        let spaced = !s.isEmpty && key.count == 1 && !(key.first?.isLetter ?? false) && !(key.first?.isNumber ?? false)
        return s + (spaced ? " " : "") + key
    }
}

/// An extra mouse button, or one direction of a side wheel.
public enum MouseTrigger: Codable, Hashable, Sendable {
    /// CGEvent button number: 2 is the middle button, 3 and 4 the side buttons.
    case button(Int)
    /// A tick of a side (horizontal) wheel, by the way it turned on the mouse.
    case wheel(left: Bool)

    /// Buttons beyond the left and right ones, which the tap can track.
    public var isValid: Bool {
        if case .button(let n) = self { return (2..<32).contains(n) }
        return true
    }

    public var displayName: String {
        switch self {
        case .button(2): return "Middle button"
        case .button(3): return "Back side button"
        case .button(4): return "Forward side button"
        case .button(let n): return "Button \(n + 1)"
        case .wheel(let left): return left ? "Side wheel left" : "Side wheel right"
        }
    }
}

/// While it has keys, the trigger presses them instead of doing what it did.
public struct ButtonShortcut: Codable, Hashable, Sendable {
    public var trigger: MouseTrigger
    /// Nil until a combination is recorded.
    public var keys: KeyCombo?

    public init(trigger: MouseTrigger, keys: KeyCombo? = nil) {
        self.trigger = trigger
        self.keys = keys
    }
}

/// An app whose scrolling Meowse leaves alone.
public struct ExcludedApp: Codable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    /// Where the app was when it was added, used if it can't be found by its identifier.
    public var path: String

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

public enum SideWheel {
    /// CGEvent field set when macOS reversed a scroll for natural scrolling
    /// (NSEvent's `isDirectionInvertedFromDevice`). Undocumented.
    public static let invertedField = CGEventField(rawValue: 137)!

    /// Which way a side wheel turned, from a horizontal delta as apps see it.
    /// With natural scrolling macOS reverses the delta, so a positive one
    /// means left only when it wasn't.
    @inline(__always)
    public static func turnedLeft(delta: Double, inverted: Bool) -> Bool {
        (delta > 0) != inverted
    }
}
