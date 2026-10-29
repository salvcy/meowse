import Foundation

/// Why mouse wheel scrolling isn't being handled right now. Other features
/// can still be active while scrolling is paused.
public enum ScrollingPause: Equatable, Sendable {
    case waitingForAccess
    case paused
    case failed
    /// A trackpad or Magic Mouse is scrolling, which is smooth on its own.
    case idle(TouchKind?)

    public init?(trusted: Bool, enabled: Bool, engine: EngineStatus, device: ScrollDevice?, touch: TouchKind?) {
        if !trusted {
            self = .waitingForAccess
        } else if !enabled {
            self = .paused
        } else if engine == .failed {
            self = .failed
        } else if engine == .active && device == .touch {
            self = .idle(touch)
        } else {
            return nil
        }
    }

    /// "Paused", "Idle (trackpad)".
    public var label: String {
        switch self {
        case .waitingForAccess: return "Waiting for access"
        case .paused: return "Paused"
        case .failed: return "Couldn’t start"
        case .idle(let touch): return touch.map { "Idle (\($0.name))" } ?? "Idle"
        }
    }
}

/// The activity represented by the menu bar icon. Scrolling's pause reason
/// alone cannot describe it: a tap may serve only shortcuts, or no scrolling
/// enhancements may be enabled at all.
public struct MenuBarStatus: Equatable, Sendable {
    public let wheel: Bool
    public let shortcuts: Bool
    public let pointer: Bool
    public let dimmed: Bool
    public let scrollingLabel: String

    public init(configuration: EngineConfig, pause: ScrollingPause?, trusted: Bool,
                engine: EngineStatus, pointerActive: Bool, awake: Bool, wiggling: Bool) {
        let running = trusted && engine == .active
        let scrollingConfigured = configuration.smooth || configuration.reverseVertical || configuration.reverseHorizontal
        wheel = running && scrollingConfigured && pause == nil
        shortcuts = running && (!configuration.buttonKeys.isEmpty
            || configuration.wheelLeftKeys != nil || configuration.wheelRightKeys != nil)
        pointer = pointerActive
        dimmed = !wheel && !shortcuts && !pointer && !awake && !wiggling

        if let pause {
            scrollingLabel = pause.label
        } else if !scrollingConfigured {
            scrollingLabel = "Nothing enabled"
        } else if !running {
            scrollingLabel = "Starting"
        } else {
            scrollingLabel = "On"
        }
    }
}
