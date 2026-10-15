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

    func testMeowseLeavesTheMacsSettingUntilAskedOtherwise() {
        let mac = PointerInfo(acceleration: 1, linear: false, curves: nil)
        var s = Settings()
        XCTAssertNil(Pointer.value(s, mac: mac))
        s.pointerSpeed = 2
        XCTAssertEqual(Pointer.value(s, mac: mac), 2)
        s.pointerAcceleration = false
        XCTAssertEqual(Pointer.value(s, mac: mac), -1)
        s.pointerSpeed = nil
        s.pointerAcceleration = true
        XCTAssertEqual(Pointer.value(s, mac: mac), 1)  // the Mac's speed
        // Acceleration turned off the old way: turning it on starts at 1.
        XCTAssertEqual(Pointer.value(s, mac: PointerInfo(acceleration: -1, linear: false, curves: nil)), 1)
        // Off in System Settings: only the speed can change.
        let linear = PointerInfo(acceleration: 0.5, linear: true, curves: nil)
        XCTAssertFalse(linear.accelerates)
        XCTAssertEqual(Pointer.value(s, mac: linear), 0.5)
        s.pointerSpeed = 2
        XCTAssertEqual(Pointer.value(s, mac: linear), 2)
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
        XCTAssertTrue(old.buttonShortcuts.isEmpty)
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
