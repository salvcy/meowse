import SwiftUI
import MeowseCore

// MARK: - Mouse

struct MouseTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            if let mac = store.pointer {
                if mac.adjustable {
                    pointer(mac)
                } else {
                    Section {
                        Text("This version of macOS doesn’t let Meowse change the pointer.").foregroundStyle(.secondary)
                    }
                }
            } else {
                Section { Text("Reading your Mac’s pointer settings…").foregroundStyle(.secondary) }
            }
        }
        .settingsTab()
    }

    @ViewBuilder private func pointer(_ mac: PointerInfo) -> some View {
        let s = store.settings
        let customized = s.pointerAcceleration != nil || s.pointerSpeed != nil || s.pointerCurve != nil
        // What the mice get: Meowse's settings, or the Mac's own.
        let shown = Pointer.override(s, mac: mac) ?? mac.own
        let line = shown.linear || shown.acceleration < 0
        Section {
            Toggle(isOn: Binding(
                get: { !line },
                set: { store.settings.pointerAcceleration = $0 }
            )) {
                Text("Mouse acceleration")
                Text("Faster movements take the pointer farther.")
            }

            if let curves = mac.curves {
                PointerGraph(curves: curves, shown: shown, mac: customized ? mac.own : nil,
                             commitCurve: { store.settings.pointerCurve = $0 },
                             commitSpeed: { store.settings.pointerSpeed = $0 })
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            } else {
                Text(s.pointerExternalOnly ? "Connect an external mouse to see its curve." : "Connect a mouse to see its curve.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(readout(shown, custom: s.pointerCurve != nil)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Use macOS Settings") {
                    store.settings.pointerAcceleration = nil
                    store.settings.pointerSpeed = nil
                    store.settings.pointerCurve = nil
                }
                .disabled(!customized)
            }
            .font(.callout)
        } footer: {
            caption(line
                ? "Without acceleration the pointer goes the same distance for every bit the mouse moves. Drag the dot to set how far."
                : "Drag the dots to shape the curve: the left one for slow, careful movements, the right one for fast ones. It starts as your Mac’s own, which comes back when Meowse quits.")
        }

        Section {
            Toggle(isOn: $store.settings.pointerExternalOnly) {
                Text("Only external mice")
                Text("The Magic Mouse and trackpads keep your Mac’s settings.")
            }
        }
    }

    private func readout(_ o: PointerOverride, custom: Bool) -> String {
        if o.linear { return "Speed \(String(format: "%.2f", o.acceleration))×" }
        if o.acceleration < 0 { return "Speed set by the mouse" }
        return custom ? "Your curve" : "macOS curve"
    }
}

/// How far the pointer goes for each speed of the mouse, as the system
/// computes it. With acceleration on, three dots shape a curve of the
/// user's own; with it off, one dot sets the speed.
///
/// It's an AppKit view that draws itself: a SwiftUI `Canvas` here cost the
/// Settings window about 75 MB while the tab was open.
private struct PointerGraph: NSViewRepresentable {
    let curves: PointerCurves
    /// What the mice get now.
    let shown: PointerOverride
    /// The Mac's own settings, drawn for comparison while Meowse's differ.
    let mac: PointerOverride?
    let commitCurve: ([PointerCurves.Point]) -> Void
    let commitSpeed: (Double) -> Void

    func makeNSView(context: Context) -> GraphView { GraphView() }

    func updateNSView(_ view: GraphView, context: Context) {
        view.model = GraphModel(curves: curves, shown: shown, mac: mac)
        view.commitCurve = commitCurve
        view.commitSpeed = commitSpeed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GraphView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 440, height: 180)
    }
}

/// The curves and dots, in the system's speed units.
struct GraphModel: Equatable {
    var curves: PointerCurves
    var shown: PointerOverride
    var mac: PointerOverride?

    var span: Double { curves.span }
    /// A fixed height, so the curve moves rather than the frame.
    var top: Double {
        max(curves.pointerSpeed(at: span, acceleration: 2),
            curves.pointerSpeed(at: span, acceleration: 1, linear: true) * 1.5) * 1.08
    }

    static func isLine(_ o: PointerOverride) -> Bool { o.linear || o.acceleration < 0 }
    var handles: [Double] { Self.isLine(shown) ? [span * 0.45] : curves.handles }
    func speed(_ x: Double, _ o: PointerOverride) -> Double { Pointer.speed(at: x, o, curves: curves) }

    /// The settings with one dot moved to pointer speed `y`, the others
    /// where they were (`ys`); with no dot, all of them as given.
    func moved(_ ys: [Double], dot: Int?, to y: Double) -> PointerOverride {
        if Self.isLine(shown) {
            let raw = curves.pointerSpeed(at: handles[0], acceleration: 1, linear: true)
            let speed = min(max(y / raw, Pointer.speedRange.lowerBound), Pointer.speedRange.upperBound)
            return PointerOverride(acceleration: (speed * 100).rounded() / 100, linear: true, curve: nil)
        }
        var ys = ys
        if let dot { ys[dot] = max(y, 0.5) }
        let curve = PointerCurves.fit(zip(handles, ys).map { PointerCurves.Point($0, $1) })
        return PointerOverride(acceleration: shown.acceleration, linear: false, curve: curve)
    }
}

final class GraphView: NSView {
    var model: GraphModel? {
        didSet { if model != oldValue { update() } }
    }
    var commitCurve: ([PointerCurves.Point]) -> Void = { _ in }
    var commitSpeed: (Double) -> Void = { _ in }

    /// Shown while dragging; committed when the drag ends, so the pointer
    /// doesn't change speed under it.
    private var preview: PointerOverride?
    /// The dot being dragged, and where all the dots were when it started.
    private var drag: (index: Int, start: [Double])?

    // Shape layers, not draw(_:): a view that draws its own bitmap here made
    // the window server hold about 90 MB of graphics memory for the window.
    private let grid = CAShapeLayer()
    private let mac = CAShapeLayer()
    private let curve = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let labels = [CATextLayer(), CATextLayer()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        for l in [grid, mac, curve, dots] as [CAShapeLayer] {
            l.fillColor = nil
            layer?.addSublayer(l)
        }
        grid.lineWidth = 0.5
        mac.lineWidth = 1.5
        mac.lineDashPattern = [4, 3]
        curve.lineWidth = 2
        curve.lineCap = .round
        curve.lineJoin = .round
        dots.lineWidth = 2
        for (label, text) in zip(labels, ["Pointer speed", "Mouse speed"]) {
            label.string = text
            label.font = NSFont.systemFont(ofSize: 10)
            label.fontSize = 10
            layer?.addSublayer(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let x = convert(event.locationInWindow, from: nil).x / bounds.width * model.span
        let xs = model.handles
        let i = xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) } ?? 0
        drag = (i, xs.map { model.speed($0, model.shown) })
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let drag else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let speed = min(max((1 - y / bounds.height) * model.top, 0), model.top)
        preview = model.moved(drag.start, dot: drag.index, to: speed)
        update()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            preview = nil
            drag = nil
            update()
        }
        guard let model, let preview else { return }
        commit(preview, model)
    }

    func commit(_ o: PointerOverride, _ model: GraphModel) {
        if GraphModel.isLine(o) {
            commitSpeed(o.acceleration)
        } else if let curve = o.curve {
            // The dots sit on the curve the mouse gets.
            commitCurve(model.curves.handles.map { PointerCurves.Point($0, curve.speed(at: $0)) })
        }
    }

    // MARK: Drawing

    private func update() {
        guard let model, let layer, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let o = preview ?? model.shown
        let size = bounds.size
        // Colors resolved for this view's light or dark appearance.
        var colors: (background: CGColor, separator: CGColor, secondary: CGColor, tertiary: CGColor, accent: CGColor) = (.clear, .clear, .clear, .clear, .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = (NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor, NSColor.separatorColor.cgColor,
                      NSColor.secondaryLabelColor.cgColor, NSColor.tertiaryLabelColor.cgColor, NSColor.controlAccentColor.cgColor)
        }
        layer.backgroundColor = colors.background
        layer.contentsScale = window?.backingScaleFactor ?? 2

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x / model.span * size.width, y: size.height - min(y / model.top, 1.02) * size.height)
        }
        func path(_ o: PointerOverride) -> CGPath {
            let p = CGMutablePath()
            let steps = 120
            for i in 0...steps {
                let x = model.span * Double(i) / Double(steps)
                let pt = point(x, model.speed(x, o))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            return p
        }

        let g = CGMutablePath()
        for i in 1..<4 {
            let x = size.width * Double(i) / 4, y = size.height * Double(i) / 4
            g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height))
            g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
        }
        grid.path = g
        grid.strokeColor = colors.separator

        if let m = model.mac, m != o {
            mac.path = path(m)
            mac.strokeColor = colors.secondary
        } else {
            mac.path = nil
        }
        curve.path = path(o)
        curve.strokeColor = colors.accent

        let d = CGMutablePath()
        for (i, x) in model.handles.enumerated() {
            let c = point(x, model.speed(x, o))
            let r = drag?.index == i ? 7.0 : 6.0
            d.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        dots.path = d
        dots.fillColor = colors.accent
        dots.strokeColor = .white

        for l in [grid, mac, curve, dots] as [CAShapeLayer] { l.frame = layer.bounds }
        labels[0].frame = CGRect(x: 6, y: 5, width: 120, height: 14)
        labels[1].frame = CGRect(x: size.width - 126, y: size.height - 19, width: 120, height: 14)
        labels[1].alignmentMode = .right
        for l in labels {
            l.foregroundColor = colors.tertiary
            l.contentsScale = layer.contentsScale
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? {
        model.map { GraphModel.isLine($0.shown) ? "Pointer speed" : "Acceleration curve" }
    }
    override func accessibilityValue() -> Any? {
        guard let o = model?.shown else { return nil }
        return GraphModel.isLine(o) ? String(format: "%.2f times", o.acceleration) : "Custom"
    }
    override func accessibilityPerformIncrement() -> Bool { step(up: true) }
    override func accessibilityPerformDecrement() -> Bool { step(up: false) }

    /// Speed up or slow down: the speed by a tenth, or every dot by 10%.
    private func step(up: Bool) -> Bool {
        guard let model else { return false }
        let ys = model.handles.map { model.speed($0, model.shown) * (up ? 1.1 : 0.9) }
        let o = GraphModel.isLine(model.shown)
            ? PointerOverride(acceleration: min(max(model.shown.acceleration + (up ? 0.1 : -0.1), Pointer.speedRange.lowerBound),
                                                Pointer.speedRange.upperBound), linear: true, curve: nil)
            : model.moved(ys, dot: nil, to: 0)
        commit(o, model)
        return true
    }
}
