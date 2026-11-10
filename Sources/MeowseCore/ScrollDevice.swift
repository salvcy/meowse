/// The kind of device behind a scroll event, as far as its fields tell.
public enum ScrollDevice: UInt8, Codable, Sendable {
    /// Discrete ticks from a mouse wheel: what Meowse smooths.
    case wheel
    /// Continuous, phased scrolling from a trackpad or Magic Mouse, which
    /// Meowse leaves alone.
    case touch

    /// Source data on every frame Meowse posts. The frames are copies of the
    /// wheel's event, so without it they'd look like hardware.
    public static let frameTag: Int64 = 0x4D65_6F77  // "Meow"

    /// Whether a discrete event is a wheel tick. A wheel never sends gesture
    /// phases; a discrete event that has one closes a trackpad's momentum.
    @inline(__always)
    public static func isWheelTick(scrollPhase: Int64, momentumPhase: Int64) -> Bool {
        scrollPhase == 0 && momentumPhase == 0
    }

    /// While a trackpad or Magic Mouse coasts, the system copies each wheel
    /// tick (discrete) and each of Meowse's frames (`tagged`) into a "momentum
    /// ended" event for the coasting app. The frames' copies make
    /// Chromium-based apps drop the glide; a tick's copy carries the tick's
    /// motion, which the glide already brings.
    @inline(__always)
    public static func isMomentumEcho(continuous: Bool, scrollPhase: Int64, momentumPhase: Int64, tagged: Bool) -> Bool {
        guard scrollPhase == 0, momentumPhase != 0 else { return false }
        return !continuous || tagged
    }

    /// Classifies one scroll event. Every wheel tick is a wheel's, even one
    /// relayed by a mouse utility. A touch surface counts only when a gesture
    /// starts on it, straight from hardware: its coasting can still arrive
    /// after a switch to the wheel, and software posts phased scrolling too
    /// (Meowse's own frames, remote sessions).
    @inline(__always)
    public static func of(continuous: Bool, sourcePID: Int64, userData: Int64,
                          scrollPhase: Int64, momentumPhase: Int64) -> ScrollDevice? {
        if !continuous {
            return isWheelTick(scrollPhase: scrollPhase, momentumPhase: momentumPhase) ? .wheel : nil
        }
        guard sourcePID == 0, userData != frameTag else { return nil }
        // kCGScrollPhaseBegan, or kCGScrollPhaseMayBegin as fingers land.
        return scrollPhase == 1 || scrollPhase == 128 ? .touch : nil
    }
}

/// Which touch surface is scrolling.
public enum TouchKind: String, Codable, Sendable {
    case trackpad, magicMouse

    public var name: String {
        switch self {
        case .trackpad: return String(localized: "trackpad", comment: "Shown as “Idle (trackpad)”")
        case .magicMouse: return String(localized: "Magic Mouse", comment: "Product name, shown as “Idle (Magic Mouse)”")
        }
    }

    /// From the sending device's registry properties. macOS applies Trackpad
    /// or Mouse settings by its scroll acceleration type; the original Magic
    /// Mouse has none, so its product name decides.
    public init?(scrollAcceleration: String?, product: String?) {
        switch scrollAcceleration {
        case "HIDTrackpadScrollAcceleration": self = .trackpad
        case "HIDMouseScrollAcceleration": self = .magicMouse
        default:
            if product?.contains("Trackpad") == true {
                self = .trackpad
            } else if product?.contains("Mouse") == true {
                self = .magicMouse
            } else {
                return nil
            }
        }
    }
}
