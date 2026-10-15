import Foundation

// The Settings window runs as its own process, Meowse Settings.app inside
// Meowse.app, so everything it loads goes back to the system when it closes.
// Meowse starts it with a pipe each way and they exchange these messages,
// one JSON object per line.

public enum EngineStatus: String, Codable, Sendable {
    case off      // nothing enabled, or no Accessibility permission
    case active
    case failed   // permitted, but the system refused to create the tap
}

public enum UpdateStatus: Codable, Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case installing
    case failed(String)
}

public enum SettingsTab: Int, Codable, Sendable {
    case general, scrolling, hotkeys, awake, updates
}

/// Everything the Settings window shows.
public struct SettingsState: Codable, Equatable, Sendable {
    /// Nil when the window already has them, so its own edits aren't echoed
    /// back in the middle of a slider drag.
    public var settings: Settings?
    public var trusted = false
    public var engine = EngineStatus.off
    public var device: ScrollDevice?
    public var touch: TouchKind?
    public var launchAtLogin = false
    public var awake = false
    /// When a timed Keep Awake session ends; nil for one that runs until turned off.
    public var awakeUntil: Date?
    public var wiggling = false
    public var version = ""
    public var update = UpdateStatus.idle
    public var lastChecked: Date?
    public var availableVersion: String?
    /// Nil retains the notes already held by the helper.
    public var availableNotes: String?
    public var releasePage: URL?

    public init() {}
}

/// Meowse → Settings.
public enum ToSettings: Codable, Equatable, Sendable {
    case state(SettingsState)
    /// Bring the window forward, on this tab if one is given.
    case show(SettingsTab?)
}

/// Settings → Meowse.
public enum SettingsAction: Codable, Equatable, Sendable {
    case settings(Settings)
    case requestPermission
    case launchAtLogin(Bool)
    case keepAwake(Bool)
    case wiggle(Bool)
    case checkForUpdates
    case installUpdate
    /// Login Items in System Settings, where the lid helper is allowed.
    case openLoginItems
}

public enum SettingsLink {
    /// One message as a line. JSON escapes newlines inside strings, so a
    /// newline only ever ends a message.
    public static func encode<T: Encodable>(_ message: T) -> Data? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }
}

/// Splits a byte stream into lines, holding a partial line until the rest arrives.
public struct LineReader: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<end]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...end)
        }
        return lines
    }
}
