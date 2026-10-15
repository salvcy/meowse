import SwiftUI
import MeowseCore


extension View {
    func settingsTab() -> some View {
        formStyle(.grouped)
            // The window fits the form, so it only scrolls on a screen too short for it.
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }
}

func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    let requestPermission: () -> Void
    @State private var confirmingRestore = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    if store.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow Access…", action: requestPermission)
                    }
                }
                LabeledContent("Scroll engine") {
                    switch store.engineStatus {
                    case .active:
                        EngineActivity(idle: store.scrollDevice == .touch, surface: store.touchKind)
                    case .failed:
                        Label("Couldn’t start", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .off:
                        Text(ScrollingPause(trusted: store.accessibilityTrusted, enabled: store.settings.enabled,
                                            engine: .off, device: nil, touch: nil)?.label ?? "Off (nothing enabled)")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if !store.accessibilityTrusted {
                    caption("Turn on Meowse in System Settings → Privacy & Security → Accessibility. It takes effect within a few seconds.")
                }
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                Toggle("Show in menu bar", isOn: $store.settings.showMenuBarIcon)
            } footer: {
                if !store.settings.showMenuBarIcon {
                    caption("Open Meowse again from Finder or Spotlight to return to Settings.")
                }
            }

            Section {
                HStack {
                    Text("Meowse \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults…") { confirmingRestore = true }
                }
                .confirmationDialog("Restore default settings?", isPresented: $confirmingRestore) {
                    Button("Restore Defaults", role: .destructive) {
                        let keepIcon = store.settings.showMenuBarIcon
                        store.settings = Settings()
                        store.settings.showMenuBarIcon = keepIcon
                    }
                } message: {
                    Text("Everything except Launch at login and Show in menu bar goes back to how Meowse came.")
                }
            }
        }
        .settingsTab()
    }
}

// MARK: - Scrolling

struct ScrollingTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Enable scroll enhancements", isOn: $store.settings.enabled)
                ExcludedApps(store: store)
            } footer: {
                caption("Only scroll wheels are affected. Trackpads and the Magic Mouse are left alone.")
            }

            Section("Smoothing") {
                Toggle("Smooth scrolling", isOn: $store.settings.smooth)
                Group {
                    Toggle("Vertical", isOn: $store.settings.smoothVertical)
                    Toggle("Horizontal", isOn: $store.settings.smoothHorizontal)
                    SliderRow("Scroll distance", value: $store.settings.notchDistance, range: Settings.notchDistanceRange, format: "%.0f pt")
                    SliderRow("Smoothness", value: $store.settings.glideTime, range: Settings.glideTimeRange, format: "%.2f s")
                    Toggle("Trackpad-style momentum", isOn: $store.settings.trackpadPhases)
                        .help("Glides rubber-band at the ends of pages, like a trackpad.")
                }
                .disabled(!store.settings.smooth)
            }
            .disabled(!store.settings.enabled)

            Section("Direction") {
                Toggle("Reverse vertical", isOn: $store.settings.reverseVertical)
                Toggle("Reverse horizontal", isOn: $store.settings.reverseHorizontal)
            }
            .disabled(!store.settings.enabled)

            Section {
                LabeledContent {
                    ScrollPreview()
                } label: {
                    Text("Try it")
                    Text("Scroll here with your mouse wheel.")
                }
            }
        }
        .settingsTab()
    }
}

// MARK: - Hotkeys

struct HotkeysTab: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var capture = Capture()

    private static let holdKeys: [(String, WritableKeyPath<MeowseCore.Settings, Hotkey>)] = [
        ("Scroll faster", \.fasterKey),
        ("Scroll sideways", \.sidewaysKey),
        ("Scroll without smoothing", \.unsmoothedKey),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.holdKeys.indices, id: \.self) { i in
                    holdKey(i)
                }
                SliderRow("Faster by", value: $store.settings.fasterFactor, range: Settings.fasterFactorRange, format: "%.1f×")
                Toggle("Stop glide on click", isOn: $store.settings.stopOnClick)
            } header: {
                Text("Scroll")
            } footer: {
                caption(sharedKey ?? "Hold these while scrolling. Click one, then press a modifier key or an extra mouse button. Right-click a modifier to use only its left or right key.")
            }
            .disabled(!store.settings.enabled)

            MouseButtonsSection(store: store, capture: capture)
        }
        .settingsTab()
        .onDisappear { capture.stop() }
    }

    private func holdKey(_ i: Int) -> some View {
        let (title, path) = Self.holdKeys[i]
        let key = store.settings[keyPath: path]
        return LabeledContent(title) {
            HStack(spacing: 6) {
                RecorderField(label: key.fieldLabel, empty: "Set key", prompt: "Press a key…",
                              recording: capture.target == .hotkey(i)) {
                    capture.start(.hotkey(i)) { event in
                        guard let hotkey = Recorded.hotkey(event) else { return .keep }
                        store.settings[keyPath: path] = hotkey
                        return .finish
                    }
                }
                .contextMenu {
                    if case .modifier(let m) = key {
                        Button("Either Side") { store.settings[keyPath: path] = .modifier(m.either) }
                        Button("Left Side Only") { store.settings[keyPath: path] = .modifier(m.left) }
                        Button("Right Side Only") { store.settings[keyPath: path] = .modifier(m.right) }
                    }
                }
                ClearButton(help: "No key") { store.settings[keyPath: path] = .none }
                    .opacity(key == .none ? 0 : 1)
                    .disabled(key == .none)
            }
        }
    }

    /// Holding a key that two actions use does both.
    private var sharedKey: String? {
        let s = store.settings
        let keys = Self.holdKeys.map { ($0.0, s[keyPath: $0.1]) }
        for (i, a) in keys.enumerated() {
            for b in keys[(i + 1)...] where a.1.overlaps(b.1) {
                return "\(a.0) and \(b.0.lowercased()) share a key, so holding it does both."
            }
        }
        return nil
    }
}

/// Extra buttons and side-wheel directions that press key combinations.
private struct MouseButtonsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var capture: Capture

    var body: some View {
        Section {
            Toggle(isOn: $store.settings.buttonShortcutsOn) {
                Text("Use extra buttons as shortcuts")
                Text("A button or side wheel with an action does it instead of what it normally does. The side buttons go back and forward.")
            }
            Group {
                ForEach(store.settings.buttonShortcuts, id: \.trigger) { shortcut in
                    row(shortcut)
                }
                addRow
            }
            .disabled(!store.settings.buttonShortcutsOn)
        } header: {
            Text("Mouse buttons")
        } footer: {
            if let note { caption(note) }
        }
    }

    private func row(_ shortcut: ButtonShortcut) -> some View {
        LabeledContent(shortcut.trigger.displayName) {
            HStack(spacing: 6) {
                if capture.target == .shortcut(shortcut.trigger) {
                    RecorderField(label: nil, empty: "", prompt: "Type a shortcut…", recording: true) { capture.stop() }
                } else {
                    actions(shortcut)
                }
                ClearButton(help: "Remove") {
                    store.settings.buttonShortcuts.removeAll { $0.trigger == shortcut.trigger }
                }
            }
        }
    }

    /// Ready-made actions, or a shortcut of the user's own.
    private func actions(_ shortcut: ButtonShortcut) -> some View {
        Menu {
            ForEach(KeyCombo.presets, id: \.name) { preset in
                Button {
                    set(shortcut.trigger, preset.keys)
                } label: {
                    Text(preset.name)
                    Text(preset.keys.displayName)
                }
            }
            Divider()
            Button("Record Shortcut…") { record(shortcut.trigger) }
        } label: {
            Text(shortcut.keys?.name ?? "Choose…")
        }
        .fixedSize()
        .frame(minWidth: 140, alignment: .trailing)
    }

    private func set(_ trigger: MouseTrigger, _ keys: KeyCombo) {
        guard let i = store.settings.buttonShortcuts.firstIndex(where: { $0.trigger == trigger }) else { return }
        store.settings.buttonShortcuts[i].keys = keys
    }

    private var addRow: some View {
        HStack {
            if capture.target == .trigger {
                Text("Press a mouse button or turn the side wheel over this window…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { capture.stop() }
            } else {
                Button {
                    capture.start(.trigger) { event in
                        let s = store.settings
                        guard let trigger = Recorded.trigger(event, reversed: s.enabled && s.reverseHorizontal) else { return .keep }
                        if !s.buttonShortcuts.contains(where: { $0.trigger == trigger }) {
                            store.settings.buttonShortcuts.append(ButtonShortcut(trigger: trigger))
                        }
                        return .finish
                    }
                } label: {
                    Label("Add a Button or Side Wheel", systemImage: "plus")
                }
            }
        }
    }

    private func record(_ trigger: MouseTrigger) {
        capture.start(.shortcut(trigger)) { event in
            guard let keys = Recorded.shortcut(event) else { return .keep }
            set(trigger, keys)
            return .finish
        }
    }

    /// A button that's also held to scroll does both.
    private var note: String? {
        let s = store.settings
        let holds: [(String, Hotkey)] = [("scroll faster", s.fasterKey), ("scroll sideways", s.sidewaysKey),
                                         ("scroll without smoothing", s.unsmoothedKey)]
        for shortcut in s.buttonShortcuts where shortcut.keys != nil {
            guard case .button(let n) = shortcut.trigger,
                  let hold = holds.first(where: { $0.1 == .mouseButton(n) }) else { continue }
            return "\(shortcut.trigger.displayName) is also held to \(hold.0), so it does both."
        }
        return nil
    }
}

// MARK: - Awake

struct AwakeTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var awake: AwakeController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { awake.isAwake },
                    set: { $0 ? awake.startAwake(duration: 0, allowDisplaySleep: store.settings.awakeAllowDisplaySleep)
                              : awake.stopAwake() }
                )) {
                    Text("Keep awake now")
                    if awake.isAwake {
                        Text(awake.awakeUntil.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until turned off")
                    }
                }
                Toggle("Allow display to sleep", isOn: $store.settings.awakeAllowDisplaySleep)
                Toggle(isOn: $store.settings.awakeLidClosed) {
                    Text("Run with the lid closed")
                    Text("macOS asks an administrator to allow this once, in Login Items.")
                }
                if store.settings.awakeLidClosed {
                    LabeledContent {
                        Button("Open Login Items…") { store.openLoginItems() }
                    } label: {
                        Text("Allow Meowse in the background")
                        Text("If the window macOS opened was closed, it’s here.")
                    }
                }
            } header: {
                Text("Keep Awake")
            } footer: {
                caption("Set a time from the menu bar. Timed sessions end on schedule even if Meowse quits. With the lid closed, the Mac sleeps anyway if its battery falls to \(Lid.lowBattery)%.")
            }

            Section {
                Toggle("Wiggle cursor now", isOn: Binding(
                    get: { awake.isWiggling },
                    set: { $0 ? awake.startWiggle(interval: store.settings.wiggleInterval) : awake.stopWiggle() }
                ))
                Picker("When idle for", selection: $store.settings.wiggleInterval) {
                    ForEach(Awake.wiggleIntervals, id: \.self) { Text(Awake.intervalLabel($0)).tag($0) }
                }
            } header: {
                Text("Wiggle Cursor")
            } footer: {
                caption("Moves the pointer by one point and back after you’ve been idle, so you stay active in chat apps and the display stays on. Paused while the screen is locked or asleep.")
            }
        }
        .settingsTab()
    }
}

// MARK: - Updates

struct UpdatesTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater: Updater

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version", value: updater.currentVersion.description)
                LabeledContent("Status") { status }
                HStack {
                    if let checked = updater.lastChecked {
                        Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { updater.check(userInitiated: true) }
                        .disabled(updater.state == .checking || updater.state == .installing)
                }
            }

            if let version = updater.availableVersion {
                Section("Meowse \(version)") {
                    if !updater.availableNotes.isEmpty {
                        Text(Self.markdown(updater.availableNotes))
                            .font(.callout)
                            .lineLimit(10)
                            .textSelection(.enabled)
                    }
                    HStack {
                        if let page = updater.releasePage {
                            Link("Release Notes", destination: page)
                        }
                        Spacer()
                        Button("Install and Relaunch") { updater.install() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(updater.state == .installing)
                    }
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $store.settings.checkForUpdates)
            } footer: {
                caption("Checks GitHub at most once a day. This is the only network request Meowse makes. Updates are verified against the developer’s signature before installing.")
            }
        }
        .settingsTab()
    }

    /// Release notes are Markdown; render bold, italics, code and links, keeping
    /// line breaks. Notes are shown before the update is verified, so only web
    /// links stay clickable.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var notes = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in notes.runs where run.link != nil && run.link?.scheme?.lowercased() != "https" {
            notes[run.range].link = nil
        }
        return notes
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let version):
            Label("Version \(version) available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…") }
        case .failed(let message):
            Text(message).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Excluded apps

/// Apps whose scrolling Meowse leaves alone: a row that opens a list.
///
/// Opening it changes the window's height (see `SettingsWindowController`).
/// The rows appear without animation: the window's resize animates instead,
/// and two animations at once would flicker the scroll bar.
private struct ExcludedApps: View {
    @ObservedObject var store: SettingsStore
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                Text("Excluded apps")
                Spacer()
                if !store.settings.excludedApps.isEmpty {
                    Text("\(store.settings.excludedApps.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        if open {
            ForEach(store.settings.excludedApps, id: \.bundleID) { app in
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(app)).resizable().frame(width: 18, height: 18)
                    Text(app.name)
                    Spacer()
                    Button {
                        store.settings.excludedApps.removeAll { $0.bundleID == app.bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop excluding \(app.name)")
                    .accessibilityLabel("Remove \(app.name)")
                }
                .padding(.leading, 20)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(action: choose) {
                    Label("Add an App…", systemImage: "plus")
                }
                caption("Meowse doesn’t smooth, reverse or otherwise change the wheel in these apps. Handy for ones with wheel handling of their own, such as games and 3D tools.")
            }
            .padding(.leading, 20)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose apps whose scrolling Meowse should leave alone."
        let add = { (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let id = Bundle(url: url)?.bundleIdentifier,
                      !store.settings.excludedApps.contains(where: { $0.bundleID == id }) else { continue }
                let name = FileManager.default.displayName(atPath: url.path)
                store.settings.excludedApps.append(ExcludedApp(
                    bundleID: id,
                    name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                    path: url.path))
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }

    /// Looked up once per app, not on every redraw.
    private static var icons: [String: NSImage] = [:]

    private static func icon(_ app: ExcludedApp) -> NSImage {
        if let icon = icons[app.bundleID] { return icon }
        let path = FileManager.default.fileExists(atPath: app.path)
            ? app.path
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path ?? app.path
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[app.bundleID] = icon
        return icon
    }
}

// MARK: - Components

/// Running while a mouse wheel scrolls; idle while a trackpad or Magic Mouse
/// does, since those are smooth on their own.
private struct EngineActivity: View {
    let idle: Bool
    let surface: TouchKind?

    var body: some View {
        let title = idle ? surface.map { "Idle (\($0.name))" } ?? "Idle" : "Running"
        Label {
            Text(title)
        } icon: {
            Image(systemName: idle ? "moon.zzz.fill" : "checkmark.circle.fill")
                .contentTransition(.symbolEffect(.replace))
        }
        .foregroundStyle(idle ? Color.secondary : Color.green)
        .animation(.smooth, value: title)
        .help(idle ? "Trackpads and the Magic Mouse scroll smoothly on their own. Meowse takes over when you scroll a mouse wheel."
                   : "Smooths mouse wheel scrolling.")
    }
}

/// A numbered page to scroll, so distance and smoothness can be felt while
/// they're set. Meowse smooths this window like any other.
private struct ScrollPreview: View {
    /// Line lengths of a page of text: long lines, and a short one ending each paragraph.
    private static let lengths: [CGFloat] = [0.94, 0.88, 0.97, 0.9, 0.52, 0.96, 0.85, 0.92, 0.38, 0.9, 0.98, 0.83, 0.95, 0.61]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<150, id: \.self) { i in
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .trailing)
                        Capsule()
                            .fill(.quaternary)
                            .frame(width: 170 * Self.lengths[i % Self.lengths.count], height: 5)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(width: 220, height: 96)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A page to scroll")
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}
