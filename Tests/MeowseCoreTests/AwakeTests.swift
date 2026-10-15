import XCTest
@testable import MeowseCore

final class AwakeTests: XCTestCase {

    func testWiggleOnlyWhenIdle() {
        // User active 10 s ago with a 60 s interval: don't wiggle, check again when they'd hit 60 s.
        let active = Awake.wigglePlan(idle: 10, interval: 60)
        XCTAssertFalse(active.wiggleNow)
        XCTAssertEqual(active.nextCheck, 50)

        let idle = Awake.wigglePlan(idle: 61, interval: 60)
        XCTAssertTrue(idle.wiggleNow)
        XCTAssertEqual(idle.nextCheck, 60)
    }

    func testWiggleToleratesTimerLeeway() {
        // A timer that fired a little early must not skip a whole cycle.
        XCTAssertTrue(Awake.wigglePlan(idle: 58, interval: 60).wiggleNow)
    }

    func testWiggleNeverSchedulesBusyLoop() {
        XCTAssertGreaterThanOrEqual(Awake.wigglePlan(idle: 56.9, interval: 60).nextCheck, 1)
    }

    func testWhileUserIsActiveTimerWakesAtMostOncePerInterval() {
        // The user is constantly active (idle ≈ 0): every check is a full interval away.
        XCTAssertEqual(Awake.wigglePlan(idle: 0, interval: 120).nextCheck, 120)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: h, minute: m, second: s))!
    }

    func testUntilStartsAnHourAheadOnAQuarterHour() {
        XCTAssertEqual(Awake.untilStart(now: at(16, 10, 20), calendar: utc), at(17, 15))
        XCTAssertEqual(Awake.untilStart(now: at(16, 45), calendar: utc), at(17, 45))
    }

    func testUntilStepsByQuarterHours() {
        let now = at(16, 10)
        XCTAssertEqual(Awake.untilStep(at(17, 15), up: true, now: now, calendar: utc), at(17, 30))
        XCTAssertEqual(Awake.untilStep(at(17, 15), up: false, now: now, calendar: utc), at(17, 0))
        XCTAssertEqual(Awake.untilStep(at(17, 20), up: true, now: now, calendar: utc), at(17, 30))
        XCTAssertEqual(Awake.untilStep(at(17, 20), up: false, now: now, calendar: utc), at(17, 15))
    }

    func testUntilStaysBetweenAQuarterHourAndADayAhead() {
        let now = at(16, 10)
        XCTAssertEqual(Awake.untilStep(at(16, 30), up: false, now: now, calendar: utc), at(16, 30))
        let dayAhead = now.addingTimeInterval(24 * 3600)
        XCTAssertLessThanOrEqual(Awake.untilStep(dayAhead, up: true, now: now, calendar: utc), dayAhead)
    }

    func testLidLetsGoOnLowBattery() {
        XCTAssertTrue(Lid.shouldHold(keepAwake: true, enabled: true, onBattery: false, charge: 5))
        XCTAssertTrue(Lid.shouldHold(keepAwake: true, enabled: true, onBattery: true, charge: 21))
        XCTAssertFalse(Lid.shouldHold(keepAwake: true, enabled: true, onBattery: true, charge: 20))
        XCTAssertFalse(Lid.shouldHold(keepAwake: false, enabled: true, onBattery: false, charge: 100))
        XCTAssertFalse(Lid.shouldHold(keepAwake: true, enabled: false, onBattery: false, charge: 100))
    }

    func testLidServiceIsNamedForTheApp() {
        XCTAssertEqual(Lid.service(forApp: "app.meowse.Meowse"), "app.meowse.Meowse.lid")
    }

    func testLabels() {
        XCTAssertEqual(Awake.durationLabel(0), "Until Turned Off")
        XCTAssertEqual(Awake.durationLabel(15 * 60), "15 Minutes")
        XCTAssertEqual(Awake.durationLabel(3600), "1 Hour")
        XCTAssertEqual(Awake.durationLabel(8 * 3600), "8 Hours")
        XCTAssertEqual(Awake.intervalLabel(30), "30 Seconds")
        XCTAssertEqual(Awake.intervalLabel(60), "1 Minute")
        XCTAssertEqual(Awake.shortLabel(0), "Indefinitely")
        XCTAssertEqual(Awake.shortLabel(15 * 60), "15m")
        XCTAssertEqual(Awake.shortLabel(2 * 3600), "2h")
        XCTAssertEqual(Awake.remainingLabel(30), "1m left")
        XCTAssertEqual(Awake.remainingLabel(52 * 60), "52m left")
        XCTAssertEqual(Awake.remainingLabel(65 * 60), "1h 5m left")
        XCTAssertEqual(Awake.remainingLabel(2 * 3600), "2h left")
    }

    func testOldSettingsGainAwakeDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: #"{"speed": 3, "awakeDuration": 3600}"#.data(using: .utf8)!)
        XCTAssertFalse(s.awakeLidClosed)
        XCTAssertEqual(s.wiggleInterval, 60)
        XCTAssertFalse(s.awakeAllowDisplaySleep)
    }

    func testNonScrollSettingsDoNotChangeEngineConfig() {
        var changed = Settings()
        changed.awakeLidClosed = true
        changed.wiggleInterval = 30
        changed.checkForUpdates = false
        XCTAssertEqual(EngineConfig(Settings()), EngineConfig(changed), "non-scroll settings must not rebuild the event tap")
    }
}
