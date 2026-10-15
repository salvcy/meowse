import AppKit
import MeowseCore

// Every row of the menu, drawn on one grid so icons, titles and check marks
// line up whatever macOS does with its own item layout. Rows that switch
// something leave the menu open, so the change can be seen; rows that do
// something (Settings, Quit) close it, like the menu's own items.
//
// The switch and the pills are drawn here rather than being NSSwitch and
// NSSegmentedControl: on macOS 27 the system controls cost 2–6 MB more once a
// menu holding them opens. All of this costs about 0.2 MB.

private enum Grid {
    static let width: CGFloat = 284
    /// Rows inside a disclosure.
    static let indent: CGFloat = 14
    static let header: CGFloat = 14   // section header titles
    static let icon: CGFloat = 22     // center of the image column
    static let title: CGFloat = 36
    static let trailing: CGFloat = 14
    static let row: CGFloat = 24
}

/// What every row shares: an optional icon, a title, short text on the
/// right, and the menu's highlight while the pointer is over a row that can
/// be clicked. Each row is one view that draws all of it: system text fields
/// and image views would each bring layout constraints and a gesture
/// recognizer, about 1 MB across the menu.
class MenuRow: NSView {

    private(set) var titleText: String
    let isHeader: Bool
    private let indent: CGFloat
    /// Draws the highlight; rows with a switch don't, as in Control Center.
    var highlights = true

    init(_ text: String, symbol: String?, symbolSize: CGFloat = 13, height: CGFloat = Grid.row, indented: Bool = false) {
        titleText = text
        isHeader = symbol == nil
        indent = indented ? Grid.indent : 0
        self.symbolSize = symbolSize
        super.init(frame: NSRect(x: 0, y: 0, width: Grid.width, height: height))
        autoresizingMask = .width
        if let symbol { setSymbol(symbol) }
        setAccessibilityElement(true)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }

    var detailText = "" { didSet { if detailText != oldValue { needsDisplay = true } } }

    /// A symbol shown where the detail text goes, e.g. ∞ for no end.
    var detailSymbol: String? {
        didSet {
            guard detailSymbol != oldValue else { return }
            detailImage = detailSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            needsDisplay = true
        }
    }
    private var detailImage: NSImage?

    func setTitle(_ text: String) {
        guard text != titleText else { return }
        titleText = text
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    private var symbol = ""
    private var image: NSImage?
    private let symbolSize: CGFloat

    func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: .regular))
        needsDisplay = true
    }

    var isHighlighted: Bool {
        highlights && !isHeader && isEnabled && enclosingMenuItem?.isHighlighted == true
    }

    /// The color for content that turns white on the highlight.
    var contentColor: NSColor {
        isHighlighted ? .selectedMenuItemTextColor : isEnabled ? .labelColor : .tertiaryLabelColor
    }

    var titleColor: NSColor { isHeader ? .secondaryLabelColor : contentColor }
    var detailColor: NSColor { isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor }

    /// Where content on the right ends; subclasses draw their accessory there.
    var right: CGFloat { bounds.width - Grid.trailing }
    /// Where the detail text ends, left of any accessory.
    var detailRight: CGFloat { right }

    private var font: NSFont { isHeader ? .systemFont(ofSize: 11, weight: .semibold) : .menuFont(ofSize: 0) }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 7, yRadius: 7).fill()
        }
        if let image {
            let color = isHighlighted ? NSColor.selectedMenuItemTextColor : isEnabled ? titleColor : .tertiaryLabelColor
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
            let size = tinted.size
            tinted.draw(in: NSRect(x: Grid.icon + indent - size.width / 2, y: bounds.midY - size.height / 2,
                                   width: size.width, height: size.height))
        }
        let title = NSAttributedString(string: titleText, attributes: [.font: font, .foregroundColor: titleColor])
        let titleSize = title.size()
        let titleX = (isHeader ? Grid.header : Grid.title) + indent
        title.draw(at: NSPoint(x: titleX, y: bounds.midY - titleSize.height / 2))

        if let detailImage {
            let tinted = detailImage.withSymbolConfiguration(.init(paletteColors: [detailColor])) ?? detailImage
            let size = tinted.size
            tinted.draw(in: NSRect(x: detailRight - 8 - size.width, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        } else if !detailText.isEmpty {
            // Right-aligned before the accessory; cut short rather than run into the title.
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            style.lineBreakMode = .byTruncatingTail
            let detail = NSAttributedString(string: detailText, attributes: [.font: font, .foregroundColor: detailColor, .paragraphStyle: style])
            let left = titleX + titleSize.width + 8
            let height = detail.size().height
            detail.draw(with: NSRect(x: left, y: bounds.midY - height / 2, width: max(0, detailRight - 8 - left), height: height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

/// A row that does something and closes the menu: Settings, Quit, an update.
final class ActionRow: MenuRow {

    private let action: () -> Void
    private let trailing: String
    private let isBadge: Bool

    /// `shortcut` is shown as the menu shows key equivalents; a `badge` is
    /// shown in a capsule, like "New".
    init(_ text: String, symbol: String, shortcut: String? = nil, badge: String? = nil, action: @escaping () -> Void) {
        self.action = action
        trailing = badge ?? shortcut ?? ""
        isBadge = badge != nil
        super.init(text, symbol: symbol)
        setAccessibilityRole(.menuItem)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !trailing.isEmpty else { return }
        let color: NSColor = isHighlighted ? .selectedMenuItemTextColor : isBadge ? .secondaryLabelColor : .tertiaryLabelColor
        let font: NSFont = isBadge ? .systemFont(ofSize: 10, weight: .semibold) : .menuFont(ofSize: 0)
        let text = NSAttributedString(string: trailing, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        let pad: CGFloat = isBadge ? 6 : 0
        let origin = NSPoint(x: right - size.width - pad, y: bounds.midY - size.height / 2)
        if isBadge {
            let capsule = NSRect(origin: origin, size: size).insetBy(dx: -6, dy: -1)
            (isHighlighted ? NSColor.white.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        }
        text.draw(at: origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform()
    }

    private func perform() {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async(execute: action)
    }

    override func accessibilityPerformPress() -> Bool { perform(); return true }
}

/// A title with a switch (a section header like "Scrolling", or a feature
/// like "Keep Awake"), a check mark on the right (an option like "Smooth
/// Scrolling"), or nothing (a plain section header). Short status text sits
/// beside the switch.
final class ToggleRow: MenuRow {

    enum Accessory { case toggle, check, none }

    var onToggle: (Bool) -> Void = { _ in }
    private let accessory: Accessory
    private static let switchSize = NSSize(width: 26, height: 15)

    init(_ text: String, symbol: String? = nil, accessory: Accessory = .toggle, indented: Bool = false) {
        self.accessory = accessory
        super.init(text, symbol: symbol, indented: indented)
        highlights = accessory == .check
        switch accessory {
        case .toggle:
            setAccessibilityRole(.checkBox)
            setAccessibilitySubrole(.switch)
        case .check:
            setAccessibilityRole(.checkBox)
        case .none:
            setAccessibilityRole(.staticText)
        }
    }

    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }

    /// Check rows only: some but not all of what the row covers is on.
    var isMixed = false { didSet { if isMixed != oldValue { needsDisplay = true } } }

    override var detailRight: CGFloat {
        switch accessory {
        case .toggle: return right - Self.switchSize.width
        case .check: return right - 13
        case .none: return right
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch accessory {
        case .toggle: drawSwitch()
        case .check: drawMark()
        case .none: break
        }
    }

    /// The look of a small system switch: accent when on, a white knob.
    private func drawSwitch() {
        let size = Self.switchSize
        let track = NSRect(x: right - size.width, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            .insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
        shape.fill()
        let d = track.height - 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? track.maxX - d - 1 : track.minX + 1, y: track.minY + 1, width: d, height: d)).fill()
        if !isEnabled {
            NSColor.windowBackgroundColor.withAlphaComponent(0.4).setFill()
            shape.fill()
        }
    }

    private static let marks: [String: NSImage] = ["checkmark", "minus"].reduce(into: [:]) {
        $0[$1] = NSImage(systemSymbolName: $1, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    }

    private func drawMark() {
        guard isOn || isMixed, let mark = Self.marks[isMixed ? "minus" : "checkmark"] else { return }
        let tinted = mark.withSymbolConfiguration(.init(paletteColors: [contentColor])) ?? mark
        let size = tinted.size
        tinted.draw(in: NSRect(x: right - 13 + (13 - size.width) / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// A click anywhere in the row flips it.
    override func mouseUp(with event: NSEvent) {
        guard accessory != .none, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    private func flip() {
        guard isEnabled else { return }
        isMixed = false
        isOn.toggle()
        onToggle(isOn)
    }

    override func accessibilityValue() -> Any? { isMixed ? 2 : isOn ? 1 : 0 }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
}

/// A row whose menu item opens a submenu as the pointer rests on it, like
/// the menu's own, with the chevron drawn on the right.
final class SubmenuRow: MenuRow {

    private static let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))

    init(_ text: String, symbol: String, indented: Bool = false) {
        super.init(text, symbol: symbol, indented: indented)
        setAccessibilityRole(.menuItem)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let chevron = Self.chevron?.withSymbolConfiguration(.init(paletteColors: [contentColor])) else { return }
        let size = chevron.size
        chevron.draw(in: NSRect(x: right - size.width, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }
}

/// A quiet line under a row, for something that needs attention: a warning
/// icon, the reason, and what clicking does, in the accent color.
final class NoteRow: NSView {

    var onClick: () -> Void = {}
    private var note = ""
    private var action = ""
    private let indented: Bool

    init(indented: Bool) {
        self.indented = indented
        super.init(frame: NSRect(x: 0, y: 0, width: Grid.width, height: 18))
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `action` is left out when clicking does nothing.
    func set(_ note: String, action: String = "") {
        guard note != self.note || action != self.action else { return }
        self.note = note
        self.action = action
        setAccessibilityLabel(action.isEmpty ? note : "\(note). \(action)")
        needsDisplay = true
    }

    private static let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor])))

    override func draw(_ dirtyRect: NSRect) {
        // Under the title of the row above.
        var x = Grid.title + (indented ? Grid.indent : 0)
        if let warning = Self.warning {
            warning.draw(in: NSRect(x: x, y: bounds.midY - warning.size.height / 2, width: warning.size.width, height: warning.size.height))
            x += warning.size.width + 5
        }
        let font = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString(string: note, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        if !action.isEmpty {
            text.append(NSAttributedString(string: "  " + action, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                                .foregroundColor: NSColor.controlAccentColor]))
        }
        text.draw(at: NSPoint(x: x, y: bounds.midY - text.size().height / 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard !action.isEmpty, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        click()
    }

    private func click() {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async(execute: onClick)
    }

    override func accessibilityPerformPress() -> Bool {
        guard !action.isEmpty else { return false }
        click()
        return true
    }
}

/// A row that shows or hides the rows under it: "Options". Collapsed, it
/// says how many of them are on, so nothing switched on is out of sight.
final class DisclosureRow: MenuRow {

    var onToggle: (Bool) -> Void = { _ in }

    init(_ text: String) {
        super.init(text, symbol: "chevron.right", symbolSize: 10)
        setAccessibilityRole(.disclosureTriangle)
    }

    var isOpen = false {
        didSet { setSymbol(isOpen ? "chevron.down" : "chevron.right") }
    }

    // Quieter than an item until the pointer is over it.
    override var isHighlighted: Bool { enclosingMenuItem?.isHighlighted == true }
    override var titleColor: NSColor { isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor }
    override var detailColor: NSColor { isHighlighted ? .selectedMenuItemTextColor : .tertiaryLabelColor }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }

    private func toggle() {
        isOpen.toggle()
        onToggle(isOpen)
    }

    override func accessibilityValue() -> Any? { isOpen ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
}

/// Pills to keep the Mac awake for a set time, in one click, and one more,
/// "Until…", to pick an end time. The running session's pill is lit;
/// clicking it again stops it.
final class PillsRow: NSView {

    var onPick: (TimeInterval) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onUntil: () -> Void = {}

    var session: AwakeController.Session? { didSet { if session != oldValue { needsDisplay = true } } }
    /// The Until… editor is showing.
    var isPicking = false { didSet { if isPicking != oldValue { needsDisplay = true } } }

    private let lengths = Awake.pills
    private var hovered: Int?
    private static let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Grid.width, height: 30))
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keep Awake for")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var untilIndex: Int { lengths.count }

    private func isLit(_ i: Int) -> Bool {
        switch session {
        case .length(let d)?: return i < lengths.count && lengths[i] == d
        case .until?: return i == untilIndex
        default: return false
        }
    }

    private func label(_ i: Int) -> String {
        guard i == untilIndex else { return Awake.shortLabel(lengths[i]) }
        if case .until(let end)? = session { return end.formatted(date: .omitted, time: .shortened) }
        return "Until…"
    }

    private static func text(_ string: String, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color])
    }

    /// Each pill gets its label's width and an equal share of what's left.
    private func frame(of i: Int) -> NSRect {
        let gap: CGFloat = 5
        let widths = (0...untilIndex).map { Self.text(label($0)).size().width + ($0 == untilIndex ? 16 : 0) }
        let row = NSRect(x: Grid.header, y: (bounds.height - 22) / 2, width: bounds.width - Grid.header - Grid.trailing, height: 22)
        let spare = (row.width - widths.reduce(0, +) - gap * CGFloat(untilIndex)) / CGFloat(widths.count)
        let x = row.minX + widths[..<i].reduce(0, +) + (spare + gap) * CGFloat(i)
        return NSRect(x: x, y: row.minY, width: widths[i] + spare, height: row.height)
    }

    private func pill(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return (0...untilIndex).first { frame(of: $0).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0...untilIndex {
            let r = frame(of: i)
            let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            let lit = isLit(i)
            (lit ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(i == hovered ? 0.16 : 0.09)).setFill()
            shape.fill()
            if i == untilIndex && isPicking && !lit {
                NSColor.controlAccentColor.setStroke()
                shape.lineWidth = 1.5
                shape.stroke()
            }
            let color: NSColor = lit ? .white : .labelColor
            let text = Self.text(label(i), color: color)
            let size = text.size()
            var x = r.midX - size.width / 2
            if i == untilIndex, let clock = Self.clock {
                let tinted = clock.tinted(color)
                x += 8
                tinted.draw(in: NSRect(x: x - 15, y: r.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
            }
            text.draw(at: NSPoint(x: x, y: r.midY - size.height / 2))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hover(pill(at: event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ i: Int?) {
        guard i != hovered else { return }
        hovered = i
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let i = pill(at: event) { press(i) }
    }

    private func press(_ i: Int) {
        if isLit(i) {
            onStop()
        } else if i == untilIndex {
            onUntil()
        } else {
            onPick(lengths[i])
        }
    }

    override func accessibilityChildren() -> [Any]? {
        (0...untilIndex).map { i in
            let name = i == untilIndex ? "Keep awake until a time" : "Keep awake for \(Awake.durationLabel(lengths[i]))"
            return DrawnPart(in: self, label: name, frame: { [weak self] in self?.frame(of: i) ?? .zero },
                        selected: { [weak self] in self?.isLit(i) ?? false }, press: { [weak self] in self?.press(i) })
        }
    }
}

/// The end time for "Until…": − and + move it by quarter hours, and so does
/// scrolling over it. It shows how long that is from now; Start begins.
final class UntilRow: NSView {

    var onStart: (Date) -> Void = { _ in }
    private(set) var time = Date()
    private var hovered: Part?
    private var scrolled: CGFloat = 0

    private enum Part: Equatable { case earlier, later, start }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Grid.width, height: 30))
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keep awake until")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Starts over from the first time offered, an hour ahead.
    func reset() {
        time = Awake.untilStart(now: Date())
        needsDisplay = true
    }

    private var bar: NSRect {
        NSRect(x: Grid.header, y: (bounds.height - 22) / 2, width: bounds.width - Grid.header - Grid.trailing, height: 22)
    }

    private func frame(of part: Part) -> NSRect {
        let b = bar
        switch part {
        case .start: return NSRect(x: b.maxX - 58, y: b.minY, width: 58, height: b.height)
        case .earlier: return NSRect(x: b.minX, y: b.minY, width: 28, height: b.height)
        case .later: return NSRect(x: b.maxX - 58 - 6 - 28, y: b.minY, width: 28, height: b.height)
        }
    }

    private func part(at event: NSEvent) -> Part? {
        let p = convert(event.locationInWindow, from: nil)
        return [Part.earlier, .later, .start].first { frame(of: $0).contains(p) }
    }

    private func capsule(_ r: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
    }

    private func center(_ text: NSAttributedString, in r: NSRect) {
        let size = text.size()
        text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }

    private static func text(_ s: String, weight: NSFont.Weight = .medium, size: CGFloat = 12, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    override func draw(_ dirtyRect: NSRect) {
        let dial = NSRect(x: bar.minX, y: bar.minY, width: frame(of: .later).maxX - bar.minX, height: bar.height)
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        capsule(dial).fill()
        for part in [Part.earlier, .later] where hovered == part {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            capsule(frame(of: part).insetBy(dx: 1.5, dy: 1.5)).fill()
        }
        center(Self.text("−", size: 14), in: frame(of: .earlier))
        center(Self.text("+", size: 14), in: frame(of: .later))

        let readout = NSMutableAttributedString(attributedString: Self.text(time.formatted(date: .omitted, time: .shortened), weight: .semibold))
        let minutes = max(1, Int((time.timeIntervalSinceNow / 60).rounded()))
        readout.append(Self.text("  " + Awake.shortLabel(TimeInterval(minutes * 60)), weight: .regular, color: .secondaryLabelColor))
        center(readout, in: NSRect(x: frame(of: .earlier).maxX, y: bar.minY,
                                   width: frame(of: .later).minX - frame(of: .earlier).maxX, height: bar.height))

        let start = frame(of: .start)
        NSColor.controlAccentColor.withAlphaComponent(hovered == .start ? 0.85 : 1).setFill()
        capsule(start).fill()
        center(Self.text("Start", weight: .semibold, color: .white), in: start)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hover(part(at: event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ part: Part?) {
        guard part != hovered else { return }
        hovered = part
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let part = part(at: event) { press(part) }
    }

    private func press(_ part: Part) {
        switch part {
        case .earlier, .later: step(up: part == .later)
        case .start: onStart(time)
        }
    }

    private func step(up: Bool) {
        time = Awake.untilStep(time, up: up, now: Date())
        needsDisplay = true
    }

    /// A quarter hour per wheel notch or short swipe; up is later.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            scrolled += event.scrollingDeltaY
            while abs(scrolled) >= 60 {
                step(up: scrolled > 0)
                scrolled -= scrolled > 0 ? 60 : -60
            }
        } else {
            step(up: event.scrollingDeltaY > 0)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let until = "Keep awake until \(time.formatted(date: .omitted, time: .shortened))"
        return [(Part.earlier, "Earlier"), (.later, "Later"), (.start, until)].map { part, name in
            DrawnPart(in: self, label: name, frame: { [weak self] in self?.frame(of: part) ?? .zero },
                      selected: { false }, press: { [weak self] in self?.press(part) })
        }
    }
}

/// A button-like piece of a drawn row, for VoiceOver.
private final class DrawnPart: NSAccessibilityElement {
    private weak var row: NSView?
    private let rect: () -> NSRect
    private let selected: () -> Bool
    private let action: () -> Void

    init(in row: NSView, label: String, frame: @escaping () -> NSRect, selected: @escaping () -> Bool, press: @escaping () -> Void) {
        self.row = row
        rect = frame
        self.selected = selected
        action = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(row)
    }

    override func accessibilityFrame() -> NSRect {
        guard let row else { return .zero }
        return NSAccessibility.screenRect(fromView: row, rect: rect())
    }

    override func isAccessibilitySelected() -> Bool { selected() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

private extension NSImage {
    /// A template symbol drawn in one color.
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
