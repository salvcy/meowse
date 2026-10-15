import XCTest
@testable import MeowseCore

final class StatusTests: XCTestCase {

    private func pause(trusted: Bool = true, enabled: Bool = true, engine: EngineStatus = .active,
                       device: ScrollDevice? = nil, touch: TouchKind? = nil) -> ScrollingPause? {
        ScrollingPause(trusted: trusted, enabled: enabled, engine: engine, device: device, touch: touch)
    }

    func testRunningHasNoReason() {
        XCTAssertNil(pause())
        XCTAssertNil(pause(device: .wheel))
        // Nothing to do (every feature off) isn't a problem to show.
        XCTAssertNil(pause(engine: .off))
    }

    func testReasonsInOrderOfWhatTheUserMustFixFirst() {
        XCTAssertEqual(pause(trusted: false, enabled: false, engine: .failed), .waitingForAccess)
        XCTAssertEqual(pause(enabled: false, engine: .off), .paused)
        XCTAssertEqual(pause(engine: .failed, device: .touch), .failed)
        XCTAssertEqual(pause(device: .touch, touch: .magicMouse), .idle(.magicMouse))
    }

    func testLabelsMatchSettings() {
        XCTAssertEqual(ScrollingPause.idle(.trackpad).label, "Idle (trackpad)")
        XCTAssertEqual(ScrollingPause.idle(nil).label, "Idle")
        XCTAssertEqual(ScrollingPause.paused.label, "Paused")
    }

    func testHotkeysThatActTogether() {
        XCTAssertTrue(Hotkey.modifier(.option).overlaps(.modifier(.leftOption)))
        XCTAssertTrue(Hotkey.modifier(.rightShift).overlaps(.modifier(.rightShift)))
        XCTAssertTrue(Hotkey.mouseButton(3).overlaps(.mouseButton(3)))
    }

    func testHotkeysThatDont() {
        XCTAssertFalse(Hotkey.modifier(.leftOption).overlaps(.modifier(.rightOption)))
        XCTAssertFalse(Hotkey.modifier(.option).overlaps(.modifier(.command)))
        XCTAssertFalse(Hotkey.mouseButton(3).overlaps(.mouseButton(4)))
        XCTAssertFalse(Hotkey.none.overlaps(.none))
    }
}
