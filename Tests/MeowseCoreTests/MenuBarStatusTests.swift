import XCTest
@testable import MeowseCore

final class MenuBarStatusTests: XCTestCase {
    private func status(_ settings: Settings, trusted: Bool = true, engine: EngineStatus = .active,
                        device: ScrollDevice? = nil, touch: TouchKind? = nil, pointer: Bool = false,
                        awake: Bool = false, wiggling: Bool = false) -> MenuBarStatus {
        MenuBarStatus(configuration: EngineConfig(settings),
                      pause: ScrollingPause(trusted: trusted, enabled: settings.enabled, engine: engine,
                                            device: device, touch: touch),
                      trusted: trusted, engine: engine, pointerActive: pointer, awake: awake, wiggling: wiggling)
    }

    private var scrollingOnly: Settings {
        var s = Settings()
        s.buttonShortcutsOn = false
        return s
    }

    func testOriginalPRScrollingAndAwakeCombinations() {
        for scrolling in [false, true] {
            var s = scrollingOnly
            s.enabled = scrolling
            for awake in [false, true] {
                for wiggling in [false, true] {
                    let result = status(s, awake: awake, wiggling: wiggling)
                    XCTAssertEqual(result.wheel, scrolling)
                    XCTAssertEqual(result.dimmed, !scrolling && !awake && !wiggling)
                    XCTAssertEqual(result.scrollingLabel, scrolling ? "On" : "Paused")
                }
            }
        }
    }

    func testNothingEnabledDoesNotShowTheWheelEvenWithTheMasterSwitchOn() {
        var s = scrollingOnly
        s.smooth = false
        s.reverseVertical = false
        s.reverseHorizontal = false
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(EngineConfig(s).eventMask, 0)
        let result = status(s, engine: .off)
        XCTAssertFalse(result.wheel)
        XCTAssertTrue(result.dimmed)
        XCTAssertEqual(result.scrollingLabel, "Nothing enabled")
    }

    func testSmoothingWithBothAxesOffDoesNotShowTheWheel() {
        var s = scrollingOnly
        s.smoothVertical = false
        s.smoothHorizontal = false
        s.reverseVertical = false
        s.reverseHorizontal = false
        XCTAssertTrue(s.smooth)
        XCTAssertFalse(status(s, engine: .off).wheel)
    }

    func testEitherSmoothingAxisOrEitherReverseDirectionShowsTheWheel() {
        var s = scrollingOnly
        s.smoothVertical = false
        s.smoothHorizontal = false
        s.reverseVertical = false
        s.reverseHorizontal = false
        for key in [\Settings.smoothVertical, \.smoothHorizontal, \.reverseVertical, \.reverseHorizontal] {
            var active = s
            active[keyPath: key] = true
            XCTAssertTrue(status(active).wheel)
            XCTAssertFalse(status(active).dimmed)
        }
    }

    func testAnActiveButtonsOnlyTapDoesNotClaimToHandleScrolling() {
        var s = Settings()
        s.smooth = false
        s.reverseVertical = false
        s.reverseHorizontal = false
        let result = status(s)
        XCTAssertFalse(result.wheel)
        XCTAssertTrue(result.shortcuts)
        XCTAssertFalse(result.dimmed)
        XCTAssertEqual(result.scrollingLabel, "Nothing enabled")
    }

    func testPausingScrollingDoesNotDimWorkingSideButtons() {
        var s = Settings()
        s.enabled = false
        let result = status(s)
        XCTAssertFalse(result.wheel)
        XCTAssertTrue(result.shortcuts)
        XCTAssertFalse(result.dimmed)
        XCTAssertEqual(result.scrollingLabel, "Paused")
    }

    func testASideWheelShortcutAlsoKeepsTheIconActiveWhileScrollingIsPaused() {
        var s = Settings()
        s.enabled = false
        s.buttonShortcuts = [ButtonShortcut(trigger: .wheel(left: true), keys: .back)]
        XCTAssertTrue(status(s).shortcuts)
        XCTAssertFalse(status(s).dimmed)
        XCTAssertFalse(status(s).wheel)
    }

    func testTouchScrollingHidesTheWheelButLeavesOtherActivityVisible() {
        for touch in [TouchKind.trackpad, .magicMouse] {
            let idle = status(scrollingOnly, device: .touch, touch: touch)
            XCTAssertFalse(idle.wheel)
            XCTAssertTrue(idle.dimmed)
            XCTAssertEqual(idle.scrollingLabel, "Idle (\(touch.name))")
            XCTAssertFalse(status(scrollingOnly, device: .touch, touch: touch, awake: true).dimmed)
            XCTAssertFalse(status(scrollingOnly, device: .touch, touch: touch, wiggling: true).dimmed)
            XCTAssertFalse(status(Settings(), device: .touch, touch: touch).dimmed)
        }
    }

    func testRequestedShortcutsDoNotKeepTheIconActiveWithoutAWorkingTap() {
        for engine in [EngineStatus.off, .failed] {
            let result = status(Settings(), engine: engine)
            XCTAssertFalse(result.wheel)
            XCTAssertFalse(result.shortcuts)
            XCTAssertTrue(result.dimmed)
        }
        let untrusted = status(Settings(), trusted: false)
        XCTAssertFalse(untrusted.wheel)
        XCTAssertFalse(untrusted.shortcuts)
        XCTAssertTrue(untrusted.dimmed)
        XCTAssertEqual(untrusted.scrollingLabel, "Waiting for access")
        XCTAssertEqual(status(Settings(), engine: .failed).scrollingLabel, "Couldn’t start")
        XCTAssertEqual(status(Settings(), engine: .off).scrollingLabel, "Starting")
    }

    func testOnlyAppliedPointerSettingsKeepTheIconActive() {
        var s = scrollingOnly
        s.enabled = false
        s.pointerScale = 1.5
        XCTAssertTrue(status(s, engine: .off).dimmed)
        let applied = status(s, engine: .off, pointer: true)
        XCTAssertTrue(applied.pointer)
        XCTAssertFalse(applied.dimmed)
        XCTAssertFalse(applied.wheel)
        // Pointer settings are applied by HID, independently of the event tap.
        XCTAssertFalse(status(s, trusted: false, engine: .off, pointer: true).dimmed)
    }

    func testChangingScrollingConfigurationCanChangeTheIconWithoutRestartingTheTap() {
        var s = Settings()
        s.smooth = false
        s.reverseVertical = false
        s.reverseHorizontal = false
        XCTAssertFalse(status(s).wheel)
        s.smooth = true
        XCTAssertTrue(status(s).wheel)
        s.smoothVertical = false
        s.smoothHorizontal = false
        XCTAssertFalse(status(s).wheel)
        XCTAssertFalse(status(s).dimmed) // the buttons-only tap is still active
    }
}
