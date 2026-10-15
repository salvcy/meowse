import XCTest
import CoreGraphics
@testable import MeowseCore

final class RouterAndConfigTests: XCTestCase {

    private let lShift: UInt64 = CGEventFlags.maskShift.rawValue | 0x2
    private let rShift: UInt64 = CGEventFlags.maskShift.rawValue | 0x4
    private let lCmd: UInt64 = CGEventFlags.maskCommand.rawValue | 0x8
    private let lAlt: UInt64 = CGEventFlags.maskAlternate.rawValue | 0x20

    /// Scroll settings alone: the side buttons' default actions are tested with the shortcuts.
    private func cfg(_ edit: (inout Settings) -> Void = { _ in }) -> EngineConfig {
        var s = Settings()
        s.buttonShortcutsOn = false
        edit(&s)
        return EngineConfig(s)
    }

    private func bit(_ t: CGEventType) -> CGEventMask { 1 << CGEventMask(t.rawValue) }

    // MARK: Event mask

    func testDefaultMaskIsJustScrollWheel() {
        // No keyboard events ever; clicks come from a tap that's on only mid-glide.
        XCTAssertEqual(cfg().eventMask, bit(.scrollWheel))
    }

    func testStopOnClickNeedsSmoothing() {
        XCTAssertTrue(cfg().stopsOnClick)
        XCTAssertFalse(cfg { $0.stopOnClick = false }.stopsOnClick)
        XCTAssertFalse(cfg { $0.smooth = false }.stopsOnClick)
        XCTAssertFalse(cfg { $0.enabled = false }.stopsOnClick)
    }

    func testNothingEnabledMeansNoTap() {
        XCTAssertEqual(cfg { $0.smooth = false; $0.reverseVertical = false; $0.reverseHorizontal = false }.eventMask, 0)
        XCTAssertEqual(cfg { $0.enabled = false }.eventMask, 0)
    }

    func testReverseOnlyNeedsJustScrollWheel() {
        XCTAssertEqual(cfg { $0.smooth = false }.eventMask, bit(.scrollWheel))
    }

    func testMouseButtonHotkeyAddsOtherMouseEvents() {
        let m = cfg { $0.fasterKey = .mouseButton(3) }.eventMask
        XCTAssertNotEqual(m & bit(.otherMouseDown), 0)
        XCTAssertNotEqual(m & bit(.otherMouseUp), 0)
    }

    func testInactiveMouseBindingsDoNotSubscribeButSidewaysStillDoes() {
        for key in [\Settings.fasterKey, \Settings.unsmoothedKey, \Settings.sidewaysKey] {
            for smooth in [false, true] {
                for reverse in [false, true] {
                    var settings = Settings()
                    settings.buttonShortcutsOn = false
                    settings.smooth = smooth
                    settings.reverseVertical = reverse
                    settings.reverseHorizontal = reverse
                    settings[keyPath: key] = .mouseButton(3)
                    let subscribed = EngineConfig(settings).eventMask & bit(.otherMouseDown) != 0
                    XCTAssertEqual(subscribed, smooth)
                }
            }
        }
        XCTAssertEqual(cfg { $0.fasterKey = .mouseButton(3); $0.fasterFactor = 1 }.eventMask, bit(.scrollWheel))
        let c = cfg {
            $0.smooth = false; $0.reverseVertical = false; $0.reverseHorizontal = true
            $0.sidewaysKey = .mouseButton(3)
        }
        XCTAssertNotEqual(c.eventMask & bit(.otherMouseDown), 0)
        XCTAssertFalse(route(1, 0, c).reverseY)
        XCTAssertTrue(route(1, 0, buttons: 1 << 3, c).reverseY)
    }

    func testHandEditedHotkeysFallBackToDefaults() throws {
        // A button number the UI never offers would crash its label or never be held.
        let json = #"{"fasterKey":{"mouseButton":{"_0":9223372036854775807}},"sidewaysKey":{"mouseButton":{"_0":0}},"unsmoothedKey":{"mouseButton":{"_0":3}}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.fasterKey, Settings().fasterKey)
        XCTAssertEqual(s.sidewaysKey, Settings().sidewaysKey)
        XCTAssertEqual(s.unsmoothedKey, .mouseButton(3))
    }

    // MARK: Modifiers

    func testSidedModifiers() {
        XCTAssertTrue(ModifierKey.leftShift.isHeld(flags: lShift))
        XCTAssertFalse(ModifierKey.leftShift.isHeld(flags: rShift))
        XCTAssertTrue(ModifierKey.shift.isHeld(flags: rShift))
        XCTAssertFalse(ModifierKey.leftShift.isHeld(flags: lCmd))
        // Generic flag without side bits (synthetic source) still matches.
        XCTAssertTrue(ModifierKey.rightShift.isHeld(flags: CGEventFlags.maskShift.rawValue))
    }

    // MARK: Routing

    private func route(_ dy: Double, _ dx: Double, flags: UInt64 = 0, buttons: UInt32 = 0, allowed: Bool = true, _ c: EngineConfig) -> WheelRoute {
        WheelRouter.route(lines: dy, dx, flags: flags, heldButtons: buttons, config: c, smoothingAllowedForTarget: allowed)
    }

    func testDefaultSmoothsAndReverses() {
        let r = route(1, 0, cfg())
        XCTAssertTrue(r.swallow)
        XCTAssertTrue(r.reverseY)
        XCTAssertEqual(r.glideY, -100, accuracy: 1e-9)
        XCTAssertEqual(r.glideX, 0)
    }

    func testUnsmoothedKeyPassesThroughReversed() {
        let r = route(1, 0, flags: lCmd, cfg())
        XCTAssertFalse(r.swallow)
        XCTAssertFalse(r.glides)
        XCTAssertTrue(r.reverseY)
    }

    func testFasterKeyMultiplies() {
        let r = route(1, 0, flags: lAlt, cfg { $0.reverseVertical = false })
        XCTAssertEqual(r.glideY, 100 * 3, accuracy: 1e-9)
    }

    func testDefaultHotkeysWorkWithEitherSide() {
        let rCmd = CGEventFlags.maskCommand.rawValue | 0x10
        XCTAssertFalse(route(1, 0, flags: rCmd, cfg()).glides)
        XCTAssertNotEqual(route(1, 0, flags: rShift, cfg()).glideX, 0)
    }

    func testSidewaysSwapsToHorizontalUsingHorizontalPrefs() {
        let r = route(1, 0, flags: lShift, cfg { $0.reverseVertical = false; $0.reverseHorizontal = true })
        XCTAssertEqual(r.glideY, 0)
        XCTAssertEqual(r.glideX, -100, accuracy: 1e-9)
        XCTAssertTrue(r.swallow)
    }

    func testMixedAxisClearsSmoothedAxisAndPassesOther() {
        let r = route(1, 1, cfg { $0.smoothHorizontal = false; $0.reverseVertical = false; $0.reverseHorizontal = false })
        XCTAssertFalse(r.swallow)
        XCTAssertTrue(r.clearY)
        XCTAssertFalse(r.clearX)
        XCTAssertNotEqual(r.glideY, 0)
        XCTAssertEqual(r.glideX, 0)
    }

    func testDisallowedTargetPassesThrough() {
        let r = route(1, 0, allowed: false, cfg())
        XCTAssertFalse(r.glides)
        XCTAssertFalse(r.swallow)
    }

    func testMouseButtonHotkey() {
        let c = cfg { $0.unsmoothedKey = .mouseButton(3) }
        XCTAssertTrue(route(1, 0, buttons: 1 << 3, c).editsEvent)
        XCTAssertFalse(route(1, 0, buttons: 1 << 3, c).glides)
        XCTAssertTrue(route(1, 0, buttons: 0, c).glides)
    }

    // MARK: Settings decoding

    func testDecodingPartialPayloadKeepsDefaults() throws {
        let json = #"{"notchDistance": 100, "unknownFutureKey": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(Settings.self, from: json)
        XCTAssertEqual(s.notchDistance, 100)
        XCTAssertEqual(s.glideTime, Settings().glideTime)
        XCTAssertEqual(s.fasterKey, .modifier(.option))
    }

    func testEarlierPayloadKeepsTheSettingsThatStillExist() throws {
        // Saved by 1.0.x: retired keys are ignored, and choices like turning
        // off update checks carry over.
        let json = #"{"checkForUpdates": false, "showMenuBarIcon": false, "reverseVertical": false, "step": 50, "speed": 3}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(s.checkForUpdates)
        XCTAssertFalse(s.showMenuBarIcon)
        XCTAssertFalse(s.reverseVertical)
        XCTAssertEqual(s.notchDistance, Settings().notchDistance)
    }

    func testDecodingClampsHandEditedValues() throws {
        let json = #"{"notchDistance": -5, "glideTime": 1e300, "fasterFactor": 0, "wiggleInterval": 0}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.notchDistance, Settings.notchDistanceRange.lowerBound)
        XCTAssertEqual(s.glideTime, Settings.glideTimeRange.upperBound)
        XCTAssertEqual(s.fasterFactor, Settings.fasterFactorRange.lowerBound)
        XCTAssertEqual(s.wiggleInterval, 30, "a zero interval would wiggle in a busy loop")
    }

    func testSettingsRoundTrip() throws {
        var s = Settings()
        s.sidewaysKey = .mouseButton(4)
        s.unsmoothedKey = .none
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
