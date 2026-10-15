import Foundation

/// Why mouse wheel scrolling isn't being handled right now. The menu bar icon
/// is gray exactly while there's a reason, and the menu, its tooltip and
/// Settings all name it the same way.
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
