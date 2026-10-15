import SwiftUI
import MeowseCore

// MARK: - Mouse

struct MouseTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            if let mac = store.pointer {
                pointer(mac)
            } else {
                Section { Text("Reading your Mac’s pointer settings…").foregroundStyle(.secondary) }
            }
        }
        .settingsTab()
    }

    @ViewBuilder private func pointer(_ mac: PointerInfo) -> some View {
        let s = store.settings
        // What the mice get: Meowse's value, or the Mac's own.
        let value = Pointer.value(s, mac: mac) ?? mac.acceleration
        let customized = s.pointerAcceleration != nil || s.pointerSpeed != nil
        Section {
            Toggle(isOn: Binding(
                get: { value >= 0 && !mac.linear },
                set: { store.settings.pointerAcceleration = $0 }
            )) {
                Text("Mouse acceleration")
                Text("Faster movements take the pointer farther.")
            }
            .disabled(mac.linear)

            if let curves = mac.curves {
                AccelerationGraph(curves: curves, value: value, linear: mac.linear,
                                  mac: customized ? mac.acceleration : nil) { store.settings.pointerSpeed = $0 }
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            } else {
                Text("Connect a mouse to see its curve.").foregroundStyle(.secondary)
            }

            HStack {
                if value >= 0 {
                    Text("Speed \(String(format: "%.2f", value))").monospacedDigit().foregroundStyle(.secondary)
                    if customized && mac.acceleration >= 0 && value != mac.acceleration {
                        Text("macOS \(String(format: "%.2f", mac.acceleration))").monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Use macOS Setting") {
                    store.settings.pointerAcceleration = nil
                    store.settings.pointerSpeed = nil
                }
                .disabled(!customized)
            }
            .font(.callout)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if mac.linear {
                    caption("Pointer acceleration is off in System Settings → Mouse → Advanced, so here you can change the speed but not turn acceleration on.")
                    Button("Open Mouse Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Mouse-Settings.extension")!)
                    }
                    .controlSize(.small)
                } else if value < 0 {
                    caption("Without acceleration the pointer moves as far as the mouse reports, so its speed is set by the mouse’s own DPI.")
                } else {
                    caption("Drag the curve to change how quickly the pointer speeds up. It starts as your Mac’s Tracking speed, and goes back to it when Meowse quits.")
                }
            }
        }
    }
}

/// How far the pointer goes for each speed of the mouse, as the system
/// computes it. Dragging moves the curve through the mouse's own family of
/// curves, the only change macOS allows apps to make.
private struct AccelerationGraph: View {
    let curves: PointerCurves
    /// The acceleration value in use; negative when it's off.
    let value: Double
    let linear: Bool
    /// The Mac's own value, drawn for comparison while Meowse's differs.
    let mac: Double?
    let commit: (Double) -> Void

    /// The value under the pointer while dragging; committed on release, so
    /// the pointer doesn't change speed under the drag.
    @State private var preview: Double?

    private var adjustable: Bool { value >= 0 || linear }
    private var span: Double { curves.span }
    /// Where the handle sits, and where a drag is measured.
    private var handleX: Double { span * 0.45 }
    /// A fixed height, so the curve moves rather than the frame. Speeds
    /// past 2 run off the top only where the pointer is already very fast.
    private var top: Double {
        let fast = curves.pointerSpeed(at: span, acceleration: 2, linear: linear)
        return max(fast, adjustable ? 0 : curves.pointerSpeed(at: span, acceleration: -1)) * 1.08
    }

    var body: some View {
        let shown = preview ?? value
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in
                draw(&ctx, size, shown)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard adjustable else { return }
                    preview = solve(forPointer: (1 - drag.location.y / size.height) * top)
                }
                .onEnded { _ in
                    if let preview, preview != value { commit(preview) }
                    preview = nil
                })
        }
        .frame(height: 170)
        .overlay(alignment: .topLeading) { axis("Pointer speed").padding(6) }
        .overlay(alignment: .bottomTrailing) { axis("Mouse speed").padding(6) }
        .accessibilityElement()
        .accessibilityLabel("Acceleration curve")
        .accessibilityValue(value >= 0 ? String(format: "%.2f", value) : "Off")
        .accessibilityAdjustableAction { direction in
            guard adjustable else { return }
            let step = direction == .increment ? 0.125 : -0.125
            commit(min(max(value + step, 0), PointerCurves.accelerationRange.upperBound))
        }
        .help(adjustable ? "Drag up for a faster pointer, down for a slower one." : "")
    }

    private func axis(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.tertiary)
    }

    private func point(_ x: Double, _ y: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: x / span * size.width, y: size.height - min(y / top, 1.02) * size.height)
    }

    private func path(_ a: Double, _ size: CGSize) -> Path {
        Path { p in
            let steps = 120
            for i in 0...steps {
                let x = span * Double(i) / Double(steps)
                let pt = point(x, curves.pointerSpeed(at: x, acceleration: a, linear: linear), size)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ shown: Double) {
        let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
        ctx.fill(frame, with: .style(.background.opacity(0.6)))
        var grid = Path()
        for i in 1..<4 {
            let x = size.width * Double(i) / 4, y = size.height * Double(i) / 4
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(grid, with: .style(.quaternary), lineWidth: 0.5)

        if let mac, mac != shown {
            ctx.stroke(path(mac, size), with: .style(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        ctx.stroke(path(shown, size), with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        if adjustable {
            let c = point(handleX, curves.pointerSpeed(at: handleX, acceleration: shown, linear: linear), size)
            let dot = Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            ctx.fill(dot, with: .color(.accentColor))
            ctx.stroke(dot, with: .color(.white), lineWidth: 2)
        }
    }

    /// The value whose curve passes through `y` at the handle. Curves rise
    /// with the value, so halving the range finds it.
    private func solve(forPointer y: Double) -> Double {
        var lo = PointerCurves.accelerationRange.lowerBound, hi = PointerCurves.accelerationRange.upperBound
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if curves.pointerSpeed(at: handleX, acceleration: mid, linear: linear) < y { lo = mid } else { hi = mid }
        }
        // Two decimals, as shown.
        return ((lo + hi) / 2 * 100).rounded() / 100
    }
}
