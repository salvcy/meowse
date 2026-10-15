import Foundation

/// How macOS turns a mouse's movement into the pointer's, computed the way
/// the system's pointer filter does, so Settings can draw the curve in use.
///
/// A mouse brings either parametric curves or a table of points; one that
/// brings neither gets the system's built-in table. Each curve belongs to an
/// acceleration value (the number System Settings' Tracking speed sets), and
/// a value between two curves blends them. Apps may set that value but not
/// the curves themselves, so it's the one thing Meowse changes.
///
/// Speeds are in the system's standardized units: mouse speed as the curves
/// take it, and pointer speed as they return it.
public struct PointerCurves: Codable, Equatable, Sendable {

    public struct Parametric: Codable, Equatable, Sendable {
        public var index: Double
        public var gainLinear = 0.0
        public var gainParabolic = 0.0
        public var gainCubic = 0.0
        public var gainQuartic = 0.0
        public var tangentLinear = 0.0
        public var tangentRoot = 0.0

        public init(index: Double, gainLinear: Double = 0, gainParabolic: Double = 0, gainCubic: Double = 0,
                    gainQuartic: Double = 0, tangentLinear: Double = 0, tangentRoot: Double = 0) {
            self.index = index
            self.gainLinear = gainLinear
            self.gainParabolic = gainParabolic
            self.gainCubic = gainCubic
            self.gainQuartic = gainQuartic
            self.tangentLinear = tangentLinear
            self.tangentRoot = tangentRoot
        }

        var isValid: Bool { gainLinear != 0 || gainParabolic != 0 || gainCubic != 0 || gainQuartic != 0 }
    }

    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Table: Codable, Equatable, Sendable {
        public var acceleration: Double
        public var points: [Point]

        public init(acceleration: Double, points: [Point]) {
            self.acceleration = acceleration
            self.points = points
        }
    }

    /// Empty when the mouse uses tables.
    public var parametric: [Parametric]
    public var tables: [Table]
    /// Counts per inch the mouse reports.
    public var resolution: Double

    public init(parametric: [Parametric] = [], tables: [Table] = PointerCurves.builtInTable, resolution: Double = 400) {
        self.parametric = parametric.filter(\.isValid)
        self.tables = tables.isEmpty ? Self.builtInTable : tables
        self.resolution = resolution > 0 ? resolution : 400
    }

    /// Tracking speed's range in System Settings.
    public static let accelerationRange = 0.0...3.0

    /// Pointer speed for mouse speed `x`. A negative acceleration turns it
    /// off, so the pointer moves exactly as far as the mouse reports; with
    /// `linear` (System Settings' Pointer acceleration off) the value scales
    /// that movement instead of picking a curve.
    public func pointerSpeed(at x: Double, acceleration a: Double, linear: Bool = false) -> Double {
        let raw = x * resolution / Self.cursorDPI
        if a < 0 { return raw }
        if linear { return raw * (a == 0 ? Self.minimumLinear : a) }
        if !parametric.isEmpty { return Self.blend(parametric, at: a).speed(at: x) }
        return Self.blend(tables, at: a).speed(at: x)
    }

    /// Mouse speeds worth drawing: a little past where the curves level off.
    public var span: Double {
        if !parametric.isEmpty {
            let knee = parametric.map { max($0.tangentRoot, $0.tangentLinear) }.max() ?? 0
            return knee > 0 ? knee * 1.1 : 20
        }
        let points = tables.last?.points ?? []
        guard let top = points.map(\.y).max(), let flat = points.first(where: { $0.y >= top }) else { return 40 }
        return flat.x * 1.1
    }

    // The pointer filter's constants: it treats a curve's output as 96 points
    // per inch, and pointer acceleration below this as this.
    static let cursorDPI = 96.0
    static let minimumLinear = 0.1

    // MARK: Parametric curves

    /// Three segments: a polynomial up to `tangentLinear`, its tangent line
    /// up to `tangentRoot`, then a square root that meets the line smoothly.
    struct Curve {
        var c: Parametric
        var tangent0 = Double.greatestFiniteMagnitude
        var tangent1 = Double.greatestFiniteMagnitude
        var m0 = 0.0, b0 = 0.0, m1 = 0.0, b1 = 0.0

        init(_ c: Parametric) {
            self.c = c
            if c.tangentLinear != 0 {
                let t = c.tangentLinear
                let y0 = poly(t)
                m0 = slope(t)
                b0 = y0 - m0 * t
                tangent0 = t
                if c.tangentRoot != 0 {
                    let y1 = m0 * c.tangentRoot + b0
                    m1 = 2 * y1 * m0
                    b1 = y1 * y1 - m1 * c.tangentRoot
                    tangent1 = c.tangentRoot
                }
            } else if c.tangentRoot != 0 {
                let t = c.tangentRoot
                let y0 = poly(t)
                m1 = slope(t)
                b1 = y0 * y0 - m1 * t
                tangent0 = t
            }
        }

        // As the system computes them: each gain is raised with its speed.
        func poly(_ x: Double) -> Double {
            c.gainLinear * x + pow(c.gainParabolic * x, 2) + pow(c.gainCubic * x, 3) + pow(c.gainQuartic * x, 4)
        }

        func slope(_ x: Double) -> Double {
            c.gainLinear + 2 * x * pow(c.gainParabolic, 2) + 3 * x * x * pow(c.gainCubic, 3) + 4 * pow(x, 3) * pow(c.gainQuartic, 4)
        }

        func speed(at x: Double) -> Double {
            if x <= tangent0 { return poly(x) }
            if x <= tangent1 && tangent0 == c.tangentLinear { return m0 * x + b0 }
            return (max(0, m1 * x + b1)).squareRoot()
        }
    }

    static func blend(_ curves: [Parametric], at a: Double) -> Curve {
        var i = 0
        for (n, c) in curves.enumerated() where a >= c.index { i = n }
        let lo = curves[i]
        guard lo.index < a, i + 1 < curves.count else { return Curve(lo) }
        let hi = curves[i + 1]
        let r = (a - lo.index) / (hi.index - lo.index)
        func mix(_ k: KeyPath<Parametric, Double>) -> Double { lo[keyPath: k] + r * (hi[keyPath: k] - lo[keyPath: k]) }
        return Curve(Parametric(index: mix(\.index), gainLinear: mix(\.gainLinear), gainParabolic: mix(\.gainParabolic),
                                gainCubic: mix(\.gainCubic), gainQuartic: mix(\.gainQuartic),
                                tangentLinear: mix(\.tangentLinear), tangentRoot: mix(\.tangentRoot)))
    }

    // MARK: Tables

    /// Straight lines from the origin through each point, the last one extended.
    struct Segments {
        var points: [Point]

        func speed(at x: Double) -> Double {
            var p0 = Point(0, 0)
            for (i, p1) in points.enumerated() {
                if x <= p1.x || i == points.count - 1 {
                    guard p1.x != p0.x else { return p1.y }
                    return p0.y + (p1.y - p0.y) / (p1.x - p0.x) * (x - p0.x)
                }
                p0 = p1
            }
            return x
        }
    }

    static func blend(_ tables: [Table], at a: Double) -> Segments {
        var lo = tables[0], hi = tables[0]
        for t in tables {
            lo = hi
            hi = t
            if a <= t.acceleration {
                if a == t.acceleration { lo = hi }
                break
            }
        }
        if lo == hi || a > hi.acceleration {
            // Past the last curve, the system scales it up.
            let scale = (a + 1) / (hi.acceleration + 1)
            return Segments(points: hi.points.map { Point($0.x, $0.y * scale) })
        }
        let ratio = (a - lo.acceleration) / (hi.acceleration - lo.acceleration)
        // Each curve's points, moved toward the other curve by the ratio;
        // where both have a point at the same speed, the first one stays.
        var merged: [Double: Double] = [:]
        for (from, toward) in [(lo, hi), (hi, lo)] {
            for (x, y) in interpolate(from.points, toward.points, ratio) where merged[x] == nil { merged[x] = y }
        }
        return Segments(points: merged.keys.sorted().map { Point($0, merged[$0]!) })
    }

    private static func interpolate(_ from: [Point], _ toward: [Point], _ ratio: Double) -> [(Double, Double)] {
        guard !toward.isEmpty else { return from.map { ($0.x, $0.y) } }
        var h = 0
        var q0 = Point(0, 0), q1 = toward[0]
        return from.map { p in
            while p.x > q1.x && h < toward.count - 1 {
                q0 = q1
                h += 1
                q1 = toward[h]
            }
            let m = q1.x == q0.x ? 0 : (q1.y - q0.y) / (q1.x - q0.x)
            let line = q1.y - m * (q1.x - p.x)
            return (p.x, min(p.y, line) + abs(p.y - line) * ratio)
        }
    }

    /// A table as a mouse publishes it (`HIDPointerAccelerationTable`):
    /// big-endian 16.16 fixed point, curves listed by acceleration.
    public static func tables(from data: Data) -> [Table]? {
        let bytes = [UInt8](data)
        var at = 8  // scale and signature
        func int(_ size: Int) -> Int? {
            guard at + size <= bytes.count else { return nil }
            var v = 0
            for b in bytes[at..<at + size] { v = v << 8 | Int(b) }
            at += size
            return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : v
        }
        func fixed() -> Double? { int(4).map { Double($0) / 65536 } }
        guard let count = int(2), count > 0 else { return nil }
        var tables: [Table] = []
        for _ in 0..<count {
            guard let accel = fixed(), let n = int(2) else { return nil }
            var points: [Point] = []
            for _ in 0..<n {
                guard let x = fixed(), let y = fixed() else { return nil }
                points.append(Point(x, y))
            }
            tables.append(Table(acceleration: accel, points: points))
        }
        return tables
    }

    /// What the system uses for a mouse that brings no curves of its own.
    public static let builtInTable: [Table] = {
        func f(_ v: Int) -> Double { Double(v) / 65536 }
        let curve = [
            (0x0000_713B, 0x0000_6000), (0x0004_4EC5, 0x0010_8000), (0x000C_0000, 0x005F_0000),
            (0x0016_EC4F, 0x008B_0000), (0x001D_3B14, 0x0094_8000), (0x0022_7627, 0x0096_0000),
            (0x0024_6276, 0x0096_0000), (0x0026_0000, 0x0096_0000), (0x0028_0000, 0x0096_0000),
        ]
        return [
            Table(acceleration: 0, points: [Point(1, 1)]),
            Table(acceleration: 1, points: curve.map { Point(f($0.0), f($0.1)) }),
        ]
    }()
}

/// The Mac's own pointer settings and the mouse they apply to, as Settings shows them.
public struct PointerInfo: Codable, Equatable, Sendable {
    /// Tracking speed in System Settings; negative when acceleration is off the old way.
    public var acceleration: Double
    /// System Settings' Pointer acceleration is off: the value scales movement instead.
    public var linear: Bool
    /// The connected mouse's curves; nil when no mouse is connected.
    public var curves: PointerCurves?

    public init(acceleration: Double, linear: Bool, curves: PointerCurves?) {
        self.acceleration = acceleration
        self.linear = linear
        self.curves = curves
    }

    /// Whether macOS accelerates the pointer.
    public var accelerates: Bool { acceleration >= 0 && !linear }
}

public enum Pointer {
    /// The acceleration value to give each mouse, or nil to leave macOS's.
    /// Meowse can't change Pointer acceleration in System Settings: with it
    /// off there, only the speed can be set.
    public static func value(_ s: Settings, mac: PointerInfo) -> Double? {
        guard s.pointerAcceleration != nil || s.pointerSpeed != nil else { return nil }
        let speed = s.pointerSpeed ?? (mac.acceleration >= 0 ? mac.acceleration : 1)
        if mac.linear { return speed }
        return (s.pointerAcceleration ?? mac.accelerates) ? speed : -1
    }
}
