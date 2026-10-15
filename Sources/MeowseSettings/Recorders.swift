import AppKit
import SwiftUI
import MeowseCore

/// Listens for the next key, modifier, button or wheel turn in this window,
/// for whichever field is recording. One field records at a time; a click
/// anywhere else or Escape stops it.
final class Capture: ObservableObject {

    enum Target: Hashable {
        case hotkey(Int)
        case shortcut(MouseTrigger)
        case trigger
    }

    enum Outcome { case finish, keep }

    @Published private(set) var target: Target?
    private var monitor: Any?
    private var handler: ((NSEvent) -> Outcome)?

    func start(_ target: Target, _ handler: @escaping (NSEvent) -> Outcome) {
        stop()
        self.target = target
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .otherMouseDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handler = nil
        target = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // Clicking elsewhere, another field included, ends this one.
            stop()
            return event
        case .keyDown where event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
            stop()  // Escape
            return nil
        default:
            guard let handler else { return event }
            if handler(event) == .finish { stop() }
            // Scrolling the window still works while waiting for a side wheel.
            return event.type == .scrollWheel ? event : nil
        }
    }
}

/// A rounded field showing a key or shortcut; clicking it records a new one.
struct RecorderField: View {
    let label: String?
    let empty: String
    let prompt: String
    let recording: Bool
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            Text(recording ? prompt : label ?? empty)
                .lineLimit(1)
                .frame(minWidth: 128)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .foregroundStyle(recording || label == nil ? .secondary : .primary)
                .background(.quaternary, in: .rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor, lineWidth: recording ? 1.5 : 0)
                }
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityValue(label ?? empty)
        .accessibilityHint(recording ? prompt : "Records a new one")
    }
}

/// The small clear button beside a field.
struct ClearButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Reading events

enum Recorded {
    /// A modifier key going down, or an extra mouse button.
    static func hotkey(_ event: NSEvent) -> Hotkey? {
        switch event.type {
        case .flagsChanged:
            let keys: [UInt16: (ModifierKey, NSEvent.ModifierFlags)] = [
                55: (.command, .command), 54: (.command, .command),
                56: (.shift, .shift), 60: (.shift, .shift),
                58: (.option, .option), 61: (.option, .option),
                59: (.control, .control), 62: (.control, .control),
            ]
            guard let (key, flag) = keys[event.keyCode], event.modifierFlags.contains(flag) else { return nil }
            return .modifier(key)
        case .otherMouseDown where event.buttonNumber >= 2 && event.buttonNumber < 32:
            return .mouseButton(event.buttonNumber)
        default:
            return nil
        }
    }

    static func shortcut(_ event: NSEvent) -> KeyCombo? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return KeyCombo(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), key: keyName(event))
    }

    /// An extra button, or a side wheel's turn. `reversed` is whether
    /// Meowse reverses horizontal scrolling before this window sees it.
    static func trigger(_ event: NSEvent, reversed: Bool) -> MouseTrigger? {
        switch event.type {
        case .otherMouseDown where event.buttonNumber >= 2 && event.buttonNumber < 32:
            return .button(event.buttonNumber)
        case .scrollWheel:
            // A wheel's ticks, or Meowse's glide for one; not a trackpad.
            let glide = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ScrollDevice.frameTag
            guard !event.hasPreciseScrollingDeltas || glide else { return nil }
            let dx = event.scrollingDeltaX
            guard dx != 0, abs(dx) > abs(event.scrollingDeltaY) else { return nil }
            return .wheel(left: SideWheel.turnedLeft(delta: reversed ? -dx : dx, inverted: event.isDirectionInvertedFromDevice))
        default:
            return nil
        }
    }

    private static func keyName(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 76: "⌤",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        if let name = named[event.keyCode] { return name }
        let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars.uppercased()
    }
}

extension Hotkey {
    /// "⌥ Option", "⌥ Right Option", "Back Button".
    var fieldLabel: String? {
        switch self {
        case .none: return nil
        default: return displayName.replacingOccurrences(of: " (either)", with: "")
        }
    }
}

extension ModifierKey {
    var either: ModifierKey { sides.0 }
    var left: ModifierKey { sides.1 }
    var right: ModifierKey { sides.2 }

    private var sides: (ModifierKey, ModifierKey, ModifierKey) {
        switch self {
        case .shift, .leftShift, .rightShift: return (.shift, .leftShift, .rightShift)
        case .option, .leftOption, .rightOption: return (.option, .leftOption, .rightOption)
        case .command, .leftCommand, .rightCommand: return (.command, .leftCommand, .rightCommand)
        case .control, .leftControl, .rightControl: return (.control, .leftControl, .rightControl)
        }
    }
}
