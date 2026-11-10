import CoreGraphics

/// A key or button held while scrolling. Modifiers are read from the scroll
/// event's own flags; only mouse-button hotkeys need extra events from the tap.
public enum Hotkey: Codable, Hashable, Sendable {
    case none
    case modifier(ModifierKey)
    /// CGEvent mouse button number (2 = middle, 3 = back, 4 = forward, ...).
    case mouseButton(Int)

    /// Buttons beyond the left and right ones, which the tap can track.
    public var isValid: Bool {
        if case .mouseButton(let n) = self { return (2..<32).contains(n) }
        return true
    }

    /// Holding one can also count as holding the other, so both act at once.
    public func overlaps(_ other: Hotkey) -> Bool {
        switch (self, other) {
        case (.modifier(let a), .modifier(let b)): return a.overlaps(b)
        case (.mouseButton(let a), .mouseButton(let b)): return a == b
        default: return false
        }
    }

    public var needsMouseButtonEvents: Bool {
        if case .mouseButton = self { return true }
        return false
    }

    @inline(__always)
    public func isHeld(flags: UInt64, heldButtons: UInt32) -> Bool {
        switch self {
        case .none:
            return false
        case .modifier(let key):
            return key.isHeld(flags: flags)
        case .mouseButton(let n):
            return n >= 0 && n < 32 && heldButtons & (1 << UInt32(n)) != 0
        }
    }

    public var displayName: String {
        switch self {
        case .none: return String(localized: "None", comment: "No hold key set")
        case .modifier(let key): return key.displayName
        case .mouseButton(let n):
            switch n {
            case 2: return String(localized: "Middle Button")
            case 3: return String(localized: "Back Button")
            case 4: return String(localized: "Forward Button")
            default: return String(localized: "Mouse Button \(n + 1)")
            }
        }
    }
}

public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case shift, leftShift, rightShift
    case option, leftOption, rightOption
    case command, leftCommand, rightCommand
    case control, leftControl, rightControl

    // Device-dependent bits from IOLLEvent.h (NX_DEVICE*KEYMASK).
    private static let lCtl: UInt64 = 0x0000_0001
    private static let lShift: UInt64 = 0x0000_0002
    private static let rShift: UInt64 = 0x0000_0004
    private static let lCmd: UInt64 = 0x0000_0008
    private static let rCmd: UInt64 = 0x0000_0010
    private static let lAlt: UInt64 = 0x0000_0020
    private static let rAlt: UInt64 = 0x0000_0040
    private static let rCtl: UInt64 = 0x0000_2000

    private var family: (generic: UInt64, left: UInt64, right: UInt64) {
        switch self {
        case .shift, .leftShift, .rightShift:
            return (CGEventFlags.maskShift.rawValue, Self.lShift, Self.rShift)
        case .option, .leftOption, .rightOption:
            return (CGEventFlags.maskAlternate.rawValue, Self.lAlt, Self.rAlt)
        case .command, .leftCommand, .rightCommand:
            return (CGEventFlags.maskCommand.rawValue, Self.lCmd, Self.rCmd)
        case .control, .leftControl, .rightControl:
            return (CGEventFlags.maskControl.rawValue, Self.lCtl, Self.rCtl)
        }
    }

    /// The same key, or "either" and one side of it.
    public func overlaps(_ other: ModifierKey) -> Bool {
        guard family.generic == other.family.generic else { return false }
        let either: Set<ModifierKey> = [.shift, .option, .command, .control]
        return self == other || either.contains(self) || either.contains(other)
    }

    @inline(__always)
    public func isHeld(flags: UInt64) -> Bool {
        let f = family
        guard flags & f.generic != 0 else { return false }
        let sideBits = flags & (f.left | f.right)
        switch self {
        case .shift, .option, .command, .control:
            return true
        case .leftShift, .leftOption, .leftCommand, .leftControl:
            // Some synthetic sources omit side bits; fall back to the generic flag.
            return sideBits == 0 || flags & f.left != 0
        case .rightShift, .rightOption, .rightCommand, .rightControl:
            return sideBits == 0 || flags & f.right != 0
        }
    }

    /// The name without "(either)", for a field that already shows the key.
    public var plainName: String {
        switch self {
        case .shift: return String(localized: "⇧ Shift")
        case .option: return String(localized: "⌥ Option")
        case .command: return String(localized: "⌘ Command")
        case .control: return String(localized: "⌃ Control")
        default: return displayName
        }
    }

    public var displayName: String {
        switch self {
        case .shift: return String(localized: "⇧ Shift (either)")
        case .leftShift: return String(localized: "⇧ Left Shift")
        case .rightShift: return String(localized: "⇧ Right Shift")
        case .option: return String(localized: "⌥ Option (either)")
        case .leftOption: return String(localized: "⌥ Left Option")
        case .rightOption: return String(localized: "⌥ Right Option")
        case .command: return String(localized: "⌘ Command (either)")
        case .leftCommand: return String(localized: "⌘ Left Command")
        case .rightCommand: return String(localized: "⌘ Right Command")
        case .control: return String(localized: "⌃ Control (either)")
        case .leftControl: return String(localized: "⌃ Left Control")
        case .rightControl: return String(localized: "⌃ Right Control")
        }
    }
}
