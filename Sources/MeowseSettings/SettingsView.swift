import SwiftUI
import MeowseCore


private extension View {
    func settingsTab() -> some View {
        formStyle(.grouped)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func caption(_ text: String) -> some View {
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

    private static let choices: [Hotkey] =
        [.none] + ModifierKey.allCases.map { .modifier($0) } + [.mouseButton(2), .mouseButton(3), .mouseButton(4)]

    var body: some View {
        Form {
            Section {
                picker("Scroll faster", $store.settings.fasterKey)
                picker("Scroll sideways", $store.settings.sidewaysKey)
                picker("Scroll without smoothing", $store.settings.unsmoothedKey)
                SliderRow("Faster by", value: $store.settings.fasterFactor, range: Settings.fasterFactorRange, format: "%.1f×")
            } header: {
                Text("Hold while scrolling")
            } footer: {
                if let shared = sharedKey { caption(shared) }
            }

            Section {
                Toggle("Stop glide on click", isOn: $store.settings.stopOnClick)
            }
        }
        .disabled(!store.settings.enabled)
        .settingsTab()
    }

    /// Holding a key that two actions use does both.
    private var sharedKey: String? {
        let s = store.settings
        let keys = [("Scroll faster", s.fasterKey), ("Scroll sideways", s.sidewaysKey), ("Scroll without smoothing", s.unsmoothedKey)]
        for (i, a) in keys.enumerated() {
            for b in keys[(i + 1)...] where a.1.overlaps(b.1) {
                return "\(a.0) and \(b.0.lowercased()) share a key, so holding it does both."
            }
        }
        return nil
    }

    private func picker(_ title: String, _ selection: Binding<Hotkey>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.choices, id: \.self) { Text($0.displayName).tag($0) }
        }
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
