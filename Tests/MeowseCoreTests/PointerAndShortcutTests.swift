import XCTest
import CoreGraphics
@testable import MeowseCore

final class PointerTests: XCTestCase {

    private let generic = PointerCurves()

    /// A mouse that brings its own curves (these are a Logitech receiver's,
    /// read from the registry on macOS 27).
    private let parametric = PointerCurves(parametric: [
        .init(index: 0, gainLinear: 1, tangentLinear: 8),
        .init(index: 0.125, gainLinear: 60293 / 65536, gainParabolic: 26214 / 65536, gainCubic: 5243 / 65536,
              tangentLinear: 537395 / 65536, tangentRoot: 1245184 / 65536),
        .init(index: 1, gainLinear: 62915 / 65536, gainParabolic: 69468 / 65536, gainCubic: 11796 / 65536,
              tangentLinear: 563610 / 65536, tangentRoot: 983040 / 65536),
        .init(index: 1.5, gainLinear: 63570 / 65536, gainParabolic: 81920 / 65536, gainCubic: 14418 / 65536,
              tangentLinear: 570163 / 65536, tangentRoot: 917504 / 65536),
    ])

    func testBuiltInTableMatchesWhatTheSystemUses() {
        // The system's own segments for a mouse without curves, at Tracking
        // speed 1 (hidutil dump): through (0.4423, 0.375), flat at 150.
        XCTAssertEqual(generic.pointerSpeed(at: 0.2, acceleration: 1), 0.2 * 0.375 / (0x713B / 65536.0), accuracy: 1e-9)
        XCTAssertEqual(generic.pointerSpeed(at: 12, acceleration: 1), 95, accuracy: 1e-9)
        XCTAssertEqual(generic.pointerSpeed(at: 37, acceleration: 1), 150, accuracy: 1e-9)
        XCTAssertEqual(generic.pointerSpeed(at: 80, acceleration: 1), 150, accuracy: 1e-9)
    }

    func testTablesBlendBetweenCurvesAndScalePastTheLast() {
        for x in [0.5, 3.0, 12.0, 30.0] {
            let low = generic.pointerSpeed(at: x, acceleration: 0)
            let mid = generic.pointerSpeed(at: x, acceleration: 0.5)
            let high = generic.pointerSpeed(at: x, acceleration: 1)
            XCTAssertGreaterThanOrEqual(mid, min(low, high) - 1e-9)
            XCTAssertLessThanOrEqual(mid, max(low, high) + 1e-9)
        }
        XCTAssertEqual(generic.pointerSpeed(at: 3, acceleration: 0), 3, accuracy: 1e-9)  // the 1:1 curve
        XCTAssertEqual(generic.pointerSpeed(at: 12, acceleration: 2), 95 * 1.5, accuracy: 1e-9)
    }

    func testTablesParseFromTheirBinaryForm() {
        // The built-in table as the system stores it.
        let bytes: [UInt8] = [
            0x00, 0x00, 0x80, 0x00, 0x40, 0x32, 0x30, 0x30, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x09,
            0x00, 0x00, 0x71, 0x3B, 0x00, 0x00, 0x60, 0x00, 0x00, 0x04, 0x4E, 0xC5, 0x00, 0x10, 0x80, 0x00,
            0x00, 0x0C, 0x00, 0x00, 0x00, 0x5F, 0x00, 0x00, 0x00, 0x16, 0xEC, 0x4F, 0x00, 0x8B, 0x00, 0x00,
            0x00, 0x1D, 0x3B, 0x14, 0x00, 0x94, 0x80, 0x00, 0x00, 0x22, 0x76, 0x27, 0x00, 0x96, 0x00, 0x00,
            0x00, 0x24, 0x62, 0x76, 0x00, 0x96, 0x00, 0x00, 0x00, 0x26, 0x00, 0x00, 0x00, 0x96, 0x00, 0x00,
            0x00, 0x28, 0x00, 0x00, 0x00, 0x96, 0x00, 0x00,
        ]
        XCTAssertEqual(PointerCurves.tables(from: Data(bytes)), PointerCurves.builtInTable)
        XCTAssertNil(PointerCurves.tables(from: Data(bytes.prefix(30))))
    }

    func testParametricCurvesFollowTheSystemFormula() {
        // At a curve's own index it's used as is: a polynomial with each gain
        // raised with the speed, then the tangent line.
        let g1 = 62915 / 65536.0, g2 = 69468 / 65536.0, g3 = 11796 / 65536.0
        let x = 4.0
        XCTAssertEqual(parametric.pointerSpeed(at: x, acceleration: 1), g1 * x + pow(g2 * x, 2) + pow(g3 * x, 3), accuracy: 1e-9)
        // The segments meet without a jump.
        let t0 = 563610 / 65536.0, t1 = 983040 / 65536.0
        for t in [t0, t1] {
            XCTAssertEqual(parametric.pointerSpeed(at: t - 1e-6, acceleration: 1),
                           parametric.pointerSpeed(at: t + 1e-6, acceleration: 1), accuracy: 1e-3)
        }
        // In between two curves, in between their speeds.
        let lo = parametric.pointerSpeed(at: x, acceleration: 1)
        let hi = parametric.pointerSpeed(at: x, acceleration: 1.5)
        let mid = parametric.pointerSpeed(at: x, acceleration: 1.25)
        XCTAssertGreaterThan(mid, lo)
        XCTAssertLessThan(mid, hi)
        // Past the last curve, the last curve.
        XCTAssertEqual(parametric.pointerSpeed(at: x, acceleration: 3), hi, accuracy: 1e-9)
    }

    func testCurvesRiseWithTheValueSoDraggingCanFindOne() {
        for curves in [generic, parametric] {
            let x = curves.span * 0.45
            var last = -1.0
            for step in 0...24 {
                let y = curves.pointerSpeed(at: x, acceleration: Double(step) / 8)
                XCTAssertGreaterThanOrEqual(y, last - 1e-9)
                last = y
            }
        }
    }

    func testWithoutAccelerationTheMouseMovesThePointerAsItReports() {
        let c = PointerCurves(resolution: 1600)
        XCTAssertEqual(c.pointerSpeed(at: 3, acceleration: -1), 3 * 1600 / 96, accuracy: 1e-9)
        XCTAssertEqual(c.pointerSpeed(at: 3, acceleration: 2, linear: true), 2 * 3 * 1600 / 96, accuracy: 1e-9)
        XCTAssertEqual(c.pointerSpeed(at: 3, acceleration: 0, linear: true), 0.1 * 3 * 1600 / 96, accuracy: 1e-9)
    }

    func testMeowseLeavesTheMacsSettingsUntilAskedOtherwise() {
        let mac = PointerInfo(acceleration: 1, linear: false, curves: nil)
        var s = Settings()
        XCTAssertNil(Pointer.override(s, mac: mac))
        // Off: the speed scales movement, starting from the Mac's.
        s.pointerAcceleration = false
        XCTAssertEqual(Pointer.override(s, mac: mac), PointerOverride(acceleration: 1, linear: true, curve: nil))
        s.pointerSpeed = 2
        XCTAssertEqual(Pointer.override(s, mac: mac)?.acceleration, 2)
        // On: the mouse's own curve, or the user's.
        s.pointerAcceleration = true
        XCTAssertEqual(Pointer.override(s, mac: mac), PointerOverride(acceleration: 1, linear: false, curve: nil))
        s.pointerCurve = [.init(5, 20), .init(15, 90), .init(30, 150)]
        XCTAssertNotNil(Pointer.override(s, mac: mac)?.curve)
        // Off in System Settings: Meowse can turn it back on.
        let linear = PointerInfo(acceleration: 0.5, linear: true, curves: nil)
        XCTAssertFalse(linear.accelerates)
        XCTAssertEqual(Pointer.override(Settings(), mac: linear), nil)
        var on = Settings()
        on.pointerAcceleration = true
        XCTAssertEqual(Pointer.override(on, mac: linear)?.linear, false)
        // Off the old way: a speed of 1 to start from.
        var off = Settings()
        off.pointerSpeed = nil
        off.pointerAcceleration = false
        XCTAssertEqual(Pointer.override(off, mac: PointerInfo(acceleration: -1, linear: false, curves: nil))?.acceleration, 1)
    }

    func testAShapedCurvePassesThroughItsPoints() {
        let points: [PointerCurves.Point] = [.init(5, 20), .init(15, 90), .init(30, 150)]
        let c = PointerCurves.fit(points)
        for p in points { XCTAssertEqual(c.speed(at: p.x), p.y, accuracy: 1e-6) }
        // Past the last point it levels off but keeps rising.
        XCTAssertGreaterThan(c.speed(at: 40), 150)
        XCTAssertLessThan(c.speed(at: 40) - 150, 150 - c.speed(at: 20))
    }

    func testCurvesTheSystemCantFollowStillRiseFromZero() {
        for points: [PointerCurves.Point] in [
            [.init(5, 100), .init(15, 20), .init(30, 150)],  // a dip
            [.init(5, 80), .init(15, 85), .init(30, 10)],    // falling at the end
            [.init(5, 0), .init(15, 0), .init(30, 0)],
            [.init(5, 1), .init(15, 50), .init(30, 51)],
        ] {
            let c = PointerCurves.fit(points)
            XCTAssertGreaterThanOrEqual(c.gainLinear, 0)
            XCTAssertEqual(c.speed(at: 0), 0, accuracy: 1e-9)
            var last = 0.0
            for i in 1...80 {
                let y = c.speed(at: Double(i) / 2)
                XCTAssertGreaterThanOrEqual(y, last - 1e-9, "\(points)")
                XCTAssertFalse(y.isNaN)
                last = y
            }
        }
    }

    func testTheMacsOwnCurveIsShapedAtThreeSpeeds() {
        let c = PointerCurves()
        XCTAssertEqual(c.handles.count, 3)
        XCTAssertEqual(c.handles, c.handles.sorted())
        XCTAssertLessThan(c.handles.last!, c.span)
        // Its three points make a curve close to it.
        let fitted = PointerCurves.fit(c.handles.map { .init($0, c.pointerSpeed(at: $0, acceleration: 1)) })
        for x in c.handles { XCTAssertEqual(fitted.speed(at: x), c.pointerSpeed(at: x, acceleration: 1), accuracy: 1e-6) }
    }

    func testScalingKeepsTheMacsCurveExactly() {
        for curves in [generic, parametric] {
            let fast = curves.scaled(1.6)
            for a in [0.0, 0.5, 1.0, 1.25, 2.0] {
                for x in stride(from: 0.25, through: curves.span * 1.2, by: 0.75) {
                    XCTAssertEqual(fast.pointerSpeed(at: x, acceleration: a), 1.6 * curves.pointerSpeed(at: x, acceleration: a),
                                   accuracy: 1e-6 * max(1, curves.pointerSpeed(at: x, acceleration: a)), "x \(x), a \(a)")
                }
            }
        }
        // A curve of the user's own scales through its dots, and stays the same shape.
        let points: [PointerCurves.Point] = [.init(5, 20), .init(15, 90), .init(30, 150)]
        let c = PointerCurves.fit(points), doubled = PointerCurves.fit(points.map { .init($0.x, $0.y * 2) })
        for x in [1.0, 7.0, 15.0, 22.0, 40.0] { XCTAssertEqual(doubled.speed(at: x), 2 * c.speed(at: x), accuracy: 1e-6) }
    }

    func testTablesGoBackToTheSystemInTheFormItReads() {
        XCTAssertEqual(PointerCurves.tables(from: PointerCurves.data(PointerCurves.builtInTable)), PointerCurves.builtInTable)
        // Byte for byte the table macOS uses for a mouse without one.
        XCTAssertEqual([UInt8](PointerCurves.data(PointerCurves.builtInTable)).prefix(30),
                       [0x00, 0x00, 0x80, 0x00, 0x40, 0x32, 0x30, 0x30, 0x00, 0x02,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
                        0x00, 0x01, 0x00, 0x00, 0x00, 0x09])
    }

    func testTheMiddleDotMakesTheMacsCurveFasterOrSlower() {
        let mac = PointerInfo(acceleration: 1, linear: false, curves: nil)
        var s = Settings()
        s.pointerScale = 1.5
        XCTAssertTrue(s.pointerCustomized)
        let o = Pointer.override(s, mac: mac)!
        XCTAssertEqual(o.scale, 1.5)
        XCTAssertNil(o.curve)
        XCTAssertEqual(Pointer.speed(at: 12, o, curves: generic), 1.5 * 95, accuracy: 1e-9)
        // A curve of the user's own replaces it; with acceleration off it doesn't apply.
        s.pointerCurve = [.init(5, 20), .init(15, 90), .init(30, 150)]
        XCTAssertEqual(Pointer.override(s, mac: mac)?.scale, 1)
        s.pointerCurve = nil
        s.pointerAcceleration = false
        XCTAssertEqual(Pointer.speed(at: 3, Pointer.override(s, mac: mac)!, curves: generic), 3 * 400 / 96, accuracy: 1e-9)
        // Hand-edited values stay in range.
        let decoded = try? JSONDecoder().decode(Settings.self, from: Data(#"{"pointerScale":40}"#.utf8))
        XCTAssertEqual(decoded?.pointerScale, Pointer.scaleRange.upperBound)
    }

    func testOnlyAppleMiceAreLeftForExternalOnly() {
        XCTAssertTrue(Pointer.isApple(vendor: 0x05AC))
        XCTAssertTrue(Pointer.isApple(vendor: 0x004C))
        XCTAssertFalse(Pointer.isApple(vendor: 0x046D))
    }
}

final class ShortcutTests: XCTestCase {

    private func bit(_ t: CGEventType) -> CGEventMask { 1 << CGEventMask(t.rawValue) }
    private let cmdW = KeyCombo(keyCode: 13, modifiers: CGEventFlags.maskCommand.rawValue, key: "W")

    func testShortcutsNeedButtonEventsEvenWithScrollingOff() {
        var s = Settings()
        s.enabled = false
        s.buttonShortcuts = [ButtonShortcut(trigger: .button(5), keys: cmdW)]
        let c = EngineConfig(s)
        XCTAssertEqual(c.eventMask, bit(.otherMouseDown) | bit(.otherMouseUp))
        XCTAssertEqual(c.buttonKeys[5], cmdW)
    }

    func testSideWheelShortcutsNeedScrollEvents() {
        var s = Settings()
        s.enabled = false
        s.buttonShortcuts = [ButtonShortcut(trigger: .wheel(left: false), keys: cmdW)]
        let c = EngineConfig(s)
        XCTAssertEqual(c.eventMask, bit(.scrollWheel))
        XCTAssertEqual(c.wheelKeys(left: false), cmdW)
        XCTAssertNil(c.wheelKeys(left: true))
    }

    func testSideButtonsGoBackAndForwardByDefault() {
        let c = EngineConfig(Settings())
        XCTAssertEqual(c.buttonKeys[3]?.name, "Back")
        XCTAssertEqual(c.buttonKeys[4]?.name, "Forward")
        XCTAssertNotEqual(c.eventMask & bit(.otherMouseDown), 0)
    }

    func testArrowShortcutsCarryTheFlagsAKeyboardSends() {
        let missionControl = KeyCombo.presets.first { $0.name == "Mission Control" }!.keys
        let fn = CGEventFlags.maskSecondaryFn.rawValue, pad = CGEventFlags.maskNumericPad.rawValue
        XCTAssertEqual(missionControl.eventFlags, CGEventFlags.maskControl.rawValue | fn | pad)
        XCTAssertEqual(cmdW.eventFlags, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(cmdW.name, "⌘W")
    }

    func testUnsetOrSwitchedOffShortcutsCostNothing() {
        var s = Settings()
        s.enabled = false
        s.buttonShortcuts = [ButtonShortcut(trigger: .button(5))]
        XCTAssertEqual(EngineConfig(s).eventMask, 0)
        s.buttonShortcuts = [ButtonShortcut(trigger: .button(5), keys: cmdW)]
        s.buttonShortcutsOn = false
        XCTAssertEqual(EngineConfig(s).eventMask, 0)
        XCTAssertTrue(EngineConfig(s).buttonKeys.isEmpty)
    }

    func testExcludedPathsEndInASlash() {
        var s = Settings()
        s.excludedApps = [ExcludedApp(bundleID: "a.b", name: "B", path: "/Applications/B.app")]
        XCTAssertEqual(EngineConfig(s).excludedPaths, ["/Applications/B.app/"])
        XCTAssertEqual(EngineConfig(s, excludedPaths: ["/Users/x/Applications/B.app/"]).excludedPaths, ["/Users/x/Applications/B.app/"])
    }

    func testHandEditedListsAreCleanedUp() throws {
        var s = Settings()
        s.buttonShortcuts = [ButtonShortcut(trigger: .button(1)), ButtonShortcut(trigger: .button(3), keys: cmdW),
                             ButtonShortcut(trigger: .button(3)), ButtonShortcut(trigger: .wheel(left: true))]
        s.excludedApps = [ExcludedApp(bundleID: "a", name: "A", path: "/A.app"), ExcludedApp(bundleID: "a", name: "A", path: "/B.app")]
        s.pointerSpeed = 9
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.buttonShortcuts, [ButtonShortcut(trigger: .button(3), keys: cmdW), ButtonShortcut(trigger: .wheel(left: true))])
        XCTAssertEqual(decoded.excludedApps.map(\.path), ["/A.app"])
        XCTAssertEqual(decoded.pointerSpeed, 3)
        // Older settings have none of these.
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertNil(old.pointerAcceleration)
        XCTAssertNil(old.pointerSpeed)
        XCTAssertNil(old.pointerCurve)
        XCTAssertEqual(old.buttonShortcuts, Settings().buttonShortcuts)
        // A curve needs three usable points.
        let bad = #"{"pointerCurve":[{"x":1,"y":2},{"x":-3,"y":3},{"x":4,"y":5}]}"#
        XCTAssertNil(try JSONDecoder().decode(Settings.self, from: Data(bad.utf8)).pointerCurve)
        let short = #"{"pointerCurve":[{"x":1,"y":2}]}"#
        XCTAssertNil(try JSONDecoder().decode(Settings.self, from: Data(short.utf8)).pointerCurve)
    }

    func testLabels() {
        XCTAssertEqual(cmdW.displayName, "⌘W")
        let all = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertEqual(KeyCombo(keyCode: 30, modifiers: all, key: "]").displayName, "⌃⌥⇧⌘ ]")
        XCTAssertEqual(KeyCombo(keyCode: 122, modifiers: 0, key: "F1").displayName, "F1")
        XCTAssertEqual(MouseTrigger.button(3).displayName, "Back side button")
        XCTAssertEqual(MouseTrigger.button(5).displayName, "Button 6")
    }

    func testSideWheelDirectionAllowsForNaturalScrolling() {
        XCTAssertTrue(SideWheel.turnedLeft(delta: 1, inverted: false))
        XCTAssertFalse(SideWheel.turnedLeft(delta: 1, inverted: true))
        XCTAssertFalse(SideWheel.turnedLeft(delta: -2, inverted: false))
        XCTAssertTrue(SideWheel.turnedLeft(delta: -2, inverted: true))
    }

    func testPointerInfoCrossesThePipe() throws {
        var state = SettingsState()
        state.pointer = PointerInfo(acceleration: 1.25, linear: false, curves: PointerCurves())
        let line = try XCTUnwrap(SettingsLink.encode(ToSettings.state(state)))
        XCTAssertEqual(SettingsLink.decode(ToSettings.self, from: line.dropLast()), .state(state))
    }
}
