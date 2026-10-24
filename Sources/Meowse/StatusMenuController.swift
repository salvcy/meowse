import AppKit
import Combine
import MeowseCore

/// The menu bar item. Items are built the first time the menu opens and
/// refreshed in `menuNeedsUpdate`, so nothing runs while the menu is closed
/// and a menu that's never opened costs nothing.
final class StatusMenuController: NSObject, NSMenuDelegate {

    private let store: SettingsStore
    private let awake: AwakeController
    private let updater: Updater
    private let lid: LidHold
    private var statusItem: NSStatusItem?

    var openSettings: () -> Void = {}
    var openUpdates: () -> Void = {}
    var requestPermission: () -> Void = {}
    var retryEngine: () -> Void = {}
    /// Runs when the menu opens, before items are refreshed.
    var willOpen: () -> Void = {}
    var trusted = false { didSet { updateIcon() } }
    var engineStatus: Engine.TapStatus = .off { didSet { updateIcon() } }

    /// What the icon draws now; nil while it's hidden.
    private var shown: Look?
    private var eyesOpen = false
    /// Bumped to cancel a blink in progress.
    private var blink = 0
    private var updates: AnyCancellable?

    private let menu = NSMenu()
    private var permissionItem: NSMenuItem!
    private var engineFailedItem: NSMenuItem!
    private var permissionSeparator: NSMenuItem!
    private var scrollingRow: ToggleRow!
    private var smoothRow: ToggleRow!
    private var reverseRow: ToggleRow!
    private var keepAwakeRow: ToggleRow!
    private var pillsRow: PillsRow!
    private var untilRow: UntilRow!
    private var untilItem: NSMenuItem!
    private var optionsRow: DisclosureRow!
    private var optionItems: [NSMenuItem] = []
    private var displaySleepRow: ToggleRow!
    private var wiggleRow: ToggleRow!
    /// How long idle before a wiggle; shown only while Wiggle Cursor is on.
    private var wiggleEveryItem: NSMenuItem!
    private var intervalItems: [NSMenuItem] = []
    private var lidRow: ToggleRow!
    private var lidNote: NoteRow!
    private var lidNoteItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var updateRow: ActionRow!

    init(store: SettingsStore, awake: AwakeController, updater: Updater, lid: LidHold) {
        self.store = store
        self.awake = awake
        self.updater = updater
        self.lid = lid
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        // A found update adds a dot. Changes are announced before they're made.
        updates = updater.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    // MARK: - Visibility

    func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.menu = menu
            statusItem = item
            updateIcon()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            shown = nil
        }
    }

    private var pause: ScrollingPause? {
        ScrollingPause(trusted: trusted, enabled: store.settings.enabled, engine: engineStatus,
                       device: store.scrollDevice, touch: store.touchKind)
    }

    /// The wheel shows only while scrolling is handled; the menu gives the
    /// reason when it isn't. Gray means Meowse is doing nothing at all: no
    /// scrolling, no Keep Awake, no Wiggle Cursor.
    /// Changes fade, and the eyes blink open or shut, unless Reduce Motion is on.
    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let pause = self.pause
        let dimmed = pause != nil && !awake.isAwake && !awake.isWiggling
        let look = Look(eyes: awake.isAwake ? .open : .none, wiggling: awake.isWiggling,
                        update: updater.availableVersion != nil, wheel: pause == nil)
        describe(button, pause: pause)

        let animate = shown != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let blinking = animate && awake.isAwake != eyesOpen
        eyesOpen = awake.isAwake
        blink += 1
        guard blinking else { return show(look, dimmed: dimmed, fade: animate) }

        // Opening, the eyes pass through closed and half open; closing, the reverse.
        let id = blink
        let steps: [Look.Eyes] = eyesOpen ? [.closed, .half, .open] : [.half, .closed, .none]
        for (i, eyes) in steps.enumerated() {
            var frame = look
            frame.eyes = eyes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(i)) { [weak self] in
                guard let self, self.blink == id else { return }
                self.show(frame, dimmed: dimmed, fade: false)
            }
        }
    }

    private func show(_ look: Look, dimmed: Bool, fade: Bool) {
        guard let button = statusItem?.button, look != shown || button.appearsDisabled != dimmed else { return }
        if fade, let layer = button.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            layer.add(transition, forKey: nil)
        }
        // Drawn each time rather than kept: it changes rarely, and each kept
        // look would hold its own bitmap.
        button.image = Self.makeIcon(look)
        button.appearsDisabled = dimmed
        shown = look
    }

    /// The tooltip and VoiceOver say what the icon shows. A timed Keep Awake
    /// gives its end time, which never needs updating.
    private func describe(_ button: NSStatusBarButton, pause: ScrollingPause?) {
        var lines = ["Meowse"]
        if let pause { lines.append("Scrolling: \(pause.label)") }
        if awake.isAwake {
            lines.append(awake.awakeUntil.map { "Keeping awake until \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "Keeping awake")
        }
        if awake.isWiggling { lines.append("Wiggling the cursor when idle") }
        if let version = updater.availableVersion { lines.append("Meowse \(version) is available") }
        let tip = lines.joined(separator: "\n")
        guard button.toolTip != tip else { return }
        button.toolTip = tip
        button.setAccessibilityLabel(lines.joined(separator: ", "))
    }

    // MARK: - Building

    /// Every row is drawn by Meowse (MenuRows.swift), so they share one grid.
    /// Scrolling's switch is its pause, and its options are checked on the
    /// right. Under Awake, each feature is one row with a switch, and Keep
    /// Awake's length is set on a slider right under it. Wiggle's interval and whether
    /// the display may sleep are set in Settings.
    private func buildMenu() {
        permissionItem = action(ActionRow("Allow Accessibility Access…", symbol: "exclamationmark.triangle.fill") { [weak self] in
            self?.requestPermission()
        })
        engineFailedItem = action(ActionRow("Scrolling Didn’t Start: Retry", symbol: "exclamationmark.triangle.fill") { [weak self] in
            self?.retryEngine()
        })
        permissionSeparator = .separator()
        menu.addItem(permissionItem)
        menu.addItem(engineFailedItem)
        menu.addItem(permissionSeparator)

        scrollingRow = ToggleRow("Scrolling")
        scrollingRow.onToggle = { [weak self] on in
            self?.store.settings.enabled = on
            self?.refresh()
        }
        smoothRow = ToggleRow("Smooth Scrolling", symbol: "scroll", accessory: .check)
        smoothRow.onToggle = { [weak self] on in self?.store.settings.smooth = on }
        reverseRow = ToggleRow("Reverse Direction", symbol: "arrow.up.arrow.down", accessory: .check)
        reverseRow.onToggle = { [weak self] on in
            self?.store.settings.reverseVertical = on
            self?.store.settings.reverseHorizontal = on
        }
        [scrollingRow, smoothRow, reverseRow].forEach { menu.addItem(viewItem($0)) }

        menu.addItem(.separator())
        menu.addItem(viewItem(ToggleRow("Awake", accessory: .none)))
        buildAwake()

        menu.addItem(.separator())
        let settings = action(ActionRow("Settings…", symbol: "gearshape", shortcut: "⌘,") { [weak self] in self?.openSettings() })
        settings.keyEquivalent = ","
        settings.action = #selector(settingsClicked)
        menu.addItem(settings)
        // Shown only once an update has been found.
        updateRow = ActionRow("Update Meowse…", symbol: "arrow.down.circle", badge: "New") { [weak self] in self?.openUpdates() }
        updateItem = action(updateRow)
        updateItem.isHidden = true
        menu.addItem(updateItem)
        let quit = action(ActionRow("Quit Meowse", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) })
        quit.keyEquivalent = "q"
        quit.action = #selector(NSApplication.terminate(_:))
        quit.target = nil
        menu.addItem(quit)
    }

    /// Keep Awake's switch runs it until turned off; a pill runs it for a set
    /// time, and Until… to a chosen time. Its Options, set once and left
    /// alone, are whether the display may sleep and running with the lid
    /// closed. Wiggle Cursor comes after, a feature of its own.
    private func buildAwake() {
        keepAwakeRow = ToggleRow("Keep Awake", symbol: "cup.and.saucer")
        keepAwakeRow.onToggle = { [weak self] on in
            guard let self else { return }
            on ? self.awake.startAwake(duration: 0, allowDisplaySleep: self.store.settings.awakeAllowDisplaySleep)
               : self.awake.stopAwake()
            self.closeUntil()
            self.refresh()
        }
        menu.addItem(viewItem(keepAwakeRow))

        pillsRow = PillsRow()
        pillsRow.onPick = { [weak self] length in
            guard let self else { return }
            self.awake.startAwake(duration: length, allowDisplaySleep: self.store.settings.awakeAllowDisplaySleep)
            self.closeUntil()
            self.refresh()
        }
        pillsRow.onStop = { [weak self] in
            self?.awake.stopAwake()
            self?.refresh()
        }
        pillsRow.onUntil = { [weak self] in
            guard let self else { return }
            self.untilItem.isHidden ? self.openUntil() : self.closeUntil()
        }
        menu.addItem(viewItem(pillsRow))

        untilRow = UntilRow()
        untilRow.onStart = { [weak self] end in
            guard let self else { return }
            self.awake.startAwake(until: end, allowDisplaySleep: self.store.settings.awakeAllowDisplaySleep)
            self.closeUntil()
            self.refresh()
        }
        untilItem = viewItem(untilRow)
        untilItem.isHidden = true
        menu.addItem(untilItem)

        optionsRow = DisclosureRow("Options")
        optionsRow.isOpen = UserDefaults.standard.bool(forKey: Self.optionsOpenKey)
        optionsRow.onToggle = { [weak self] open in
            UserDefaults.standard.set(open, forKey: Self.optionsOpenKey)
            self?.optionItems.forEach { $0.isHidden = !open }
            self?.refresh()  // the lid's note shows only when it has something to say
        }
        menu.addItem(viewItem(optionsRow))

        displaySleepRow = ToggleRow("Allow Display to Sleep", symbol: "display", accessory: .check, indented: true)
        displaySleepRow.onToggle = { [weak self] on in
            self?.store.settings.awakeAllowDisplaySleep = on  // AppDelegate updates a running session
            self?.refresh()
        }
        lidRow = ToggleRow("Run With Lid Closed", symbol: "laptopcomputer", accessory: .check, indented: true)
        lidRow.onToggle = { [weak self] on in
            self?.store.settings.awakeLidClosed = on  // AppDelegate asks for the helper's approval
            self?.refresh()
        }
        // Says what's keeping Run With Lid Closed from working, under it.
        lidNote = NoteRow(indented: true)
        lidNote.onClick = { [weak self] in self?.lid.openApproval() }
        lidNoteItem = viewItem(lidNote)
        optionItems = [displaySleepRow, lidRow].map(viewItem)
        optionItems.forEach {
            $0.isHidden = !optionsRow.isOpen
            menu.addItem($0)
        }
        menu.addItem(lidNoteItem)

        wiggleRow = ToggleRow("Wiggle Cursor", symbol: "cursorarrow.motionlines")
        wiggleRow.onToggle = { [weak self] on in
            guard let self else { return }
            on ? self.awake.startWiggle(interval: self.store.settings.wiggleInterval) : self.awake.stopWiggle()
            self.refresh()
        }
        menu.addItem(viewItem(wiggleRow))

        let intervals = NSMenu()
        intervals.autoenablesItems = false
        for seconds in Awake.wiggleIntervals {
            let i = NSMenuItem(title: Awake.intervalLabel(seconds), action: #selector(pickInterval(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = seconds
            intervalItems.append(i)
            intervals.addItem(i)
        }
        wiggleEveryItem = viewItem(SubmenuRow("Wiggle When Idle For", symbol: "hourglass", indented: true))
        wiggleEveryItem.submenu = intervals
        menu.addItem(wiggleEveryItem)
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        store.settings.wiggleInterval = seconds  // AppDelegate restarts the running wiggle
    }

    private static let optionsOpenKey = "menu.optionsOpen"

    private func openUntil() {
        untilRow.reset()
        untilItem.isHidden = false
        pillsRow.isPicking = true
    }

    private func closeUntil() {
        untilItem?.isHidden = true
        pillsRow?.isPicking = false
    }

    func menuDidClose(_ menu: NSMenu) {
        closeUntil()
    }

    /// The lid helper's state changed, e.g. it now holds.
    func lidChanged() {
        refresh()
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = view
        return i
    }

    /// The item keeps the row's title, so the menu can match its shortcut.
    private func action(_ row: ActionRow) -> NSMenuItem {
        let i = viewItem(row)
        i.title = row.titleText
        i.target = self
        return i
    }

    // MARK: - Refresh

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.items.isEmpty { buildMenu() }
        willOpen()
        let engineFailed = trusted && engineStatus == .failed
        permissionItem.isHidden = trusted
        engineFailedItem.isHidden = !engineFailed
        permissionSeparator.isHidden = trusted && !engineFailed

        let update = updater.availableVersion
        updateItem.isHidden = update == nil
        if let update { updateRow.setTitle("Update to Meowse \(update)…") }
        refresh()
    }

    /// Also run after a switch is flipped, since the menu stays open.
    private func refresh() {
        guard scrollingRow != nil else { return }
        let s = store.settings
        // Whenever the icon is gray, the menu says why; paused shows as the switch.
        scrollingRow.isOn = s.enabled
        scrollingRow.detailText = pause.flatMap { $0 == .paused ? nil : $0.label } ?? ""
        smoothRow.isOn = s.smooth
        // Mixed when Settings reverses only one direction; a click turns both on.
        reverseRow.isOn = s.reverseVertical && s.reverseHorizontal
        reverseRow.isMixed = s.reverseVertical != s.reverseHorizontal
        smoothRow.isEnabled = s.enabled
        reverseRow.isEnabled = s.enabled

        keepAwakeRow.isOn = awake.isAwake
        keepAwakeRow.setSymbol(awake.isAwake ? "cup.and.heat.waves" : "cup.and.saucer")
        keepAwakeRow.detailSymbol = nil
        switch awake.session {
        case .length?: keepAwakeRow.detailText = awake.awakeRemaining.map(Awake.remainingLabel) ?? ""
        case .until(let end)?: keepAwakeRow.detailText = "Until " + end.formatted(date: .omitted, time: .shortened)
        case .indefinite?:
            keepAwakeRow.detailText = ""
            keepAwakeRow.detailSymbol = "infinity"  // on with no end
        case nil: keepAwakeRow.detailText = ""
        }
        pillsRow.session = awake.session

        displaySleepRow.isOn = s.awakeAllowDisplaySleep
        wiggleRow.isOn = awake.isWiggling
        wiggleEveryItem.isHidden = !awake.isWiggling
        for i in intervalItems {
            i.state = (i.representedObject as? TimeInterval) == s.wiggleInterval ? .on : .off
        }
        // Collapsed, Options says how many of its switches are on.
        let on = [s.awakeAllowDisplaySleep, s.awakeLidClosed].filter { $0 }.count
        optionsRow.detailText = optionsRow.isOpen || on == 0 ? "" : "\(on) on"

        lidRow.isOn = s.awakeLidClosed
        var note = ""
        if s.awakeLidClosed {
            if lid.needsApproval {
                note = "Needs permission"
                lidNote.set(note, action: "Open Settings")
            } else if lid.state == .lowBattery {
                note = "Off while the battery is low"
                lidNote.set(note)
            } else if lid.state == .failed {
                note = "Couldn’t start"
                lidNote.set(note, action: "Open Settings")
            }
        }
        lidNoteItem.isHidden = note.isEmpty || !optionsRow.isOpen
        // Closed, Options carries the note instead.
        if !optionsRow.isOpen && !note.isEmpty { optionsRow.detailText = note }
    }

    // MARK: - Actions

    @objc private func settingsClicked() { openSettings() }

    // MARK: - Icon

    /// The eyes open while Keep Awake is on, motion lines show Wiggle, a
    /// dot means an update is waiting, and the wheel shows scrolling is on.
    private struct Look: Equatable {
        enum Eyes { case none, closed, half, open }
        var eyes = Eyes.none
        var wiggling = false
        var update = false
        var wheel = true
    }

    /// A mouse with cat ears, from the website's 24-unit outline scaled to the
    /// 16 pt height of a menu bar symbol. Every look has the same size, so the
    /// glyph stays put as they change.
    private static func makeIcon(_ look: Look) -> NSImage {
        @discardableResult func fit(_ path: NSBezierPath) -> NSBezierPath {
            path.transform(using: AffineTransform(scale: 0.8))
            path.transform(using: AffineTransform(translationByX: 0.4, byY: -0.2))
            return path
        }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let glyph = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 4.5, width: 11, height: 16), xRadius: 5.5, yRadius: 5.5)
            for ear in [[(8.5, 5.5), (7.0, 2.5), (10.0, 4.5)], [(15.5, 5.5), (17.0, 2.5), (14.0, 4.5)]] {
                glyph.move(to: NSPoint(x: ear[0].0, y: ear[0].1))
                glyph.line(to: NSPoint(x: ear[1].0, y: ear[1].1))
                glyph.line(to: NSPoint(x: ear[2].0, y: ear[2].1))
            }
            // The wheel: shorter with eyes, to leave them room.
            if look.wheel {
                glyph.move(to: NSPoint(x: 12, y: 4.5))
                glyph.line(to: NSPoint(x: 12, y: look.eyes == .none ? 9.5 : 8))
            }
            fit(glyph)
            glyph.lineWidth = 1.6 * 0.8
            glyph.lineCapStyle = .round
            glyph.lineJoinStyle = .round
            glyph.stroke()

            for x in [9.75, 14.25] {
                switch look.eyes {
                case .none:
                    break
                case .open:
                    fit(NSBezierPath(ovalIn: NSRect(x: x - 1, y: 12, width: 2, height: 2))).fill()
                case .half:
                    fit(NSBezierPath(ovalIn: NSRect(x: x - 1, y: 12.55, width: 2, height: 0.9))).fill()
                case .closed:
                    let lid = NSBezierPath()
                    lid.move(to: NSPoint(x: x - 1.25, y: 12.8))
                    lid.curve(to: NSPoint(x: x + 1.25, y: 12.8),
                              controlPoint1: NSPoint(x: x - 0.6, y: 13.8), controlPoint2: NSPoint(x: x + 0.6, y: 13.8))
                    fit(lid)
                    lid.lineWidth = 0.95
                    lid.lineCapStyle = .round
                    lid.stroke()
                }
            }
            if look.wiggling {
                // Speed lines trailing the mouse, longest in the middle.
                for (y, length) in [(7.0, 2.6), (10.0, 3.4), (13.0, 2.6)] {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: 1.2, y: y))
                    line.line(to: NSPoint(x: 1.2 + length, y: y))
                    line.lineWidth = 1.1
                    line.lineCapStyle = .round
                    line.stroke()
                }
            }
            if look.update {
                let dot = NSRect(x: 15.4, y: 0.4, width: 4.4, height: 4.4)
                // Clear a ring around the dot so it stands apart from the ear.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.1, dy: -1.1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Meowse"
        return image
    }
}
