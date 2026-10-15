import Foundation

/// How macOS turns a mouse's movement into the pointer's, computed the way
/// the system's pointer filter does, so Settings can draw the curve in use.
///
/// A mouse brings either parametric curves or a table of points; one that
/// brings neither gets the system's built-in table. Each curve belongs to an
/// acceleration value (the number System Settings' Tracking speed sets), and
/// a value between two curves blends them. A curve of the user's own, which
/// Meowse gives the mouse, replaces them all (`fit`).
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

        /// Pointer speed for mouse speed `x`, as the system computes it.
        public func speed(at x: Double) -> Double { Curve(self).speed(at: x) }
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

    /// Where a curve of the user's own is shaped: slow, medium and fast.
    public var handles: [Double] { [0.15, 0.45, 0.8].map { $0 * span } }

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

    // MARK: Curves of the user's own

    /// The parametric curve through `points` (slow, medium and fast), as
    /// near as the system's curves allow: one that rises from zero and keeps
    /// rising. Like the system's own curves, it follows a cubic up to the
    /// middle point, then a square root that levels off, aimed at the fast
    /// point. The square root's slope where it starts fixes the cubic's slope
    /// at the middle point, which makes the cubic exact.
    public static func fit(_ points: [Point]) -> Parametric {
        let p = points.sorted { $0.x < $1.x }
        guard p.count == 3, p[0].x > 0, p[1].x > p[0].x, p[2].x > p[1].x else {
            return Parametric(index: 0, gainLinear: 1)
        }
        let (x1, y1) = (p[0].x, max(p[0].y, 0))
        let (x2, y2) = (p[1].x, max(p[1].y, 0.01))
        let (x3, y3) = (p[2].x, p[2].y)
        let slope = max(0, (y3 * y3 - y2 * y2) / (2 * y2 * (x3 - x2)))
        // Rows: the value at the slow point, at the middle point, and the slope there.
        let rows = [[x1, x1 * x1, x1 * x1 * x1], [x2, x2 * x2, x2 * x2 * x2], [1, 2 * x2, 3 * x2 * x2]]
        let rhs = [y1, y2, slope]
        // The system squares the parabolic gain, so that term can't be
        // negative; nor can the slope at zero. Where the exact curve needs
        // either, the nearest one without.
        var a = leastSquares(rows, rhs, [0, 1, 2])
        if a[1] < 0 { a = leastSquares(rows, rhs, [0, 2]) }
        if a[0] < 0 { a = leastSquares(rows, rhs, [1, 2]) }
        if a[1] < 0 || a[0] < 0 { a = leastSquares(rows, rhs, [2]) }
        let a1 = max(0, a[0]), a2 = max(0, a[1])
        // Rising all the way to the middle point: with the slope at zero and
        // there both non-negative, it is in between.
        let a3 = max(a[2], -(a1 + 2 * a2 * x2) / (3 * x2 * x2))
        return Parametric(index: 0, gainLinear: a1, gainParabolic: a2.squareRoot(), gainCubic: cbrt(a3),
                          tangentLinear: x2, tangentRoot: x2)
    }

    /// Least squares for the coefficients in `columns`; the rest are zero.
    private static func leastSquares(_ rows: [[Double]], _ rhs: [Double], _ columns: [Int]) -> [Double] {
        let n = columns.count
        var m = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for (row, y) in zip(rows, rhs) {
            let v = columns.map { row[$0] }
            for i in 0..<n {
                for j in 0..<n { m[i][j] += v[i] * v[j] }
                m[i][n] += v[i] * y
            }
        }
        for c in 0..<n {
            guard let pivot = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), m[pivot][c] != 0 else { continue }
            m.swapAt(c, pivot)
            for r in 0..<n where r != c {
                let f = m[r][c] / m[c][c]
                for k in c...n { m[r][k] -= f * m[c][k] }
            }
        }
        var out = [0.0, 0.0, 0.0]
        for (i, column) in columns.enumerated() where m[i][i] != 0 { out[column] = m[i][n] / m[i][i] }
        return out
    }

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
    /// Whether this macOS lets Meowse set the pointer at all.
    public var adjustable: Bool

    public init(acceleration: Double, linear: Bool, curves: PointerCurves?, adjustable: Bool = true) {
        self.acceleration = acceleration
        self.linear = linear
        self.curves = curves
        self.adjustable = adjustable
    }

    /// Whether macOS accelerates the pointer.
    public var accelerates: Bool { acceleration >= 0 && !linear }

    /// The Tracking speed to pick the mouse's own curve with.
    public var trackingSpeed: Double { acceleration >= 0 ? acceleration : 1 }

    /// The Mac's settings as a mouse has them.
    public var own: PointerOverride { PointerOverride(acceleration: acceleration, linear: linear, curve: nil) }
}

/// What Meowse gives a mouse in place of the Mac's settings.
public struct PointerOverride: Equatable, Sendable {
    /// The Tracking speed value, or with `linear` the speed itself.
    public var acceleration: Double
    /// Acceleration off: each count of movement goes `acceleration` times as far.
    public var linear: Bool
    /// A curve of the user's own; nil keeps the mouse's.
    public var curve: PointerCurves.Parametric?

    public init(acceleration: Double, linear: Bool, curve: PointerCurves.Parametric?) {
        self.acceleration = acceleration
        self.linear = linear
        self.curve = curve
    }
}

public enum Pointer {
    /// What to give each mouse, or nil to leave the Mac's settings.
    public static func override(_ s: Settings, mac: PointerInfo) -> PointerOverride? {
        guard s.pointerAcceleration != nil || s.pointerSpeed != nil || s.pointerCurve != nil else { return nil }
        if s.pointerAcceleration ?? mac.accelerates {
            return PointerOverride(acceleration: mac.trackingSpeed, linear: false,
                                   curve: s.pointerCurve.map(PointerCurves.fit))
        }
        return PointerOverride(acceleration: s.pointerSpeed ?? mac.trackingSpeed, linear: true, curve: nil)
    }

    /// Speeds without acceleration, as System Settings offers them.
    public static let speedRange = 0.1...3.0

    /// The pointer speed for mouse speed `x` under `o`, or the Mac's settings.
    public static func speed(at x: Double, _ o: PointerOverride, curves: PointerCurves) -> Double {
        if let curve = o.curve { return curve.speed(at: x) }
        return curves.pointerSpeed(at: x, acceleration: o.acceleration, linear: o.linear)
    }

    /// Mice that keep the Mac's settings when Meowse sets only external ones.
    public static func isApple(vendor: Int) -> Bool { vendor == 0x05AC || vendor == 0x004C }
}
