import AppKit
import Combine
import IOKit.pwr_mgt
import MeowseCore

/// Keep Awake and Wiggle Cursor. Main thread only.
///
/// Keep Awake is a single power assertion whose timeout is enforced by the
/// system, so a timed session ends on schedule even if the app doesn't run;
/// the local one-shot timer only updates the menu bar badge.
///
/// Wiggle re-arms a one-shot timer for the time left until the user would be
/// idle, and removes it entirely while the screen is locked or asleep.
final class AwakeController: ObservableObject {

    static let shared = AwakeController()

    /// Called on every state change.
    var onChange: (() -> Void)?

    private func notify() {
        objectWillChange.send()
        onChange?()
    }

    // MARK: - Keep Awake

    /// How a session was started, for the menu to show which pill is on.
    enum Session: Equatable {
        case indefinite
        case length(TimeInterval)
        case until(Date)
    }

    private var assertion: IOPMAssertionID = 0
    private var expiryTimer: DispatchSourceTimer?
    private(set) var session: Session?
    /// When a timed session ends; nil while off or until turned off.
    private(set) var awakeUntil: Date?
    var isAwake: Bool { assertion != 0 }

    /// A `duration` of 0 runs until turned off.
    func startAwake(duration: TimeInterval, allowDisplaySleep: Bool) {
        start(duration > 0 ? .length(duration) : .indefinite,
              until: duration > 0 ? Date(timeIntervalSinceNow: duration) : nil, allowDisplaySleep: allowDisplaySleep)
    }

    func startAwake(until end: Date, allowDisplaySleep: Bool) {
        start(.until(end), until: end, allowDisplaySleep: allowDisplaySleep)
    }

    /// Keeps a running session, with or without the display.
    func setAllowDisplaySleep(_ allow: Bool) {
        guard isAwake, let session else { return }
        start(session, until: awakeUntil, allowDisplaySleep: allow)
    }

    private func start(_ session: Session, until end: Date?, allowDisplaySleep: Bool) {
        releaseAssertion()
        let type = allowDisplaySleep ? kIOPMAssertPreventUserIdleSystemSleep : kIOPMAssertPreventUserIdleDisplaySleep
        var props: [String: Any] = [
            kIOPMAssertionTypeKey: type,
            kIOPMAssertionNameKey: "Meowse: Keep Awake",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
        ]
        let duration = end.map { max(1, $0.timeIntervalSinceNow) }
        if let duration {
            props[kIOPMAssertionTimeoutKey] = duration
            props[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
        }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithProperties(props as CFDictionary, &id) == kIOReturnSuccess else {
            NSLog("Meowse: could not create power assertion")
            notify()
            return
        }
        assertion = id
        self.session = session
        if let end, let duration {
            awakeUntil = end
            let t = DispatchSource.makeTimerSource(queue: .main)
            // Wall-clock time keeps counting while the Mac sleeps; uptime would end the session late.
            t.schedule(wallDeadline: .now() + duration, repeating: .never, leeway: .seconds(2))
            t.setEventHandler { [weak self] in self?.stopAwake() }
            t.resume()
            expiryTimer = t
        }
        notify()
    }

    func stopAwake() {
        releaseAssertion()
        notify()
    }

    var awakeRemaining: TimeInterval? {
        awakeUntil.map { max(0, $0.timeIntervalSinceNow) }
    }

    private func releaseAssertion() {
        expiryTimer?.cancel()
        expiryTimer = nil
        awakeUntil = nil
        session = nil
        if assertion != 0 {
            // May already have been released by the timeout.
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    // MARK: - Wiggle Cursor

    private(set) var isWiggling = false
    private(set) var wiggleInterval: TimeInterval = 60
    private var wiggleTimer: DispatchSourceTimer?
    private var suspendReasons: Set<String> = []
    private lazy var eventSource = CGEventSource(stateID: .hidSystemState)
    private static let anyInput = CGEventType(rawValue: ~0)!

    func startWiggle(interval: TimeInterval) {
        isWiggling = true
        wiggleInterval = interval
        armWiggle(after: interval)
        notify()
    }

    func stopWiggle() {
        isWiggling = false
        disarmWiggle()
        notify()
    }

    private func armWiggle(after delay: TimeInterval) {
        guard isWiggling, suspendReasons.isEmpty else { return disarmWiggle() }
        let t: DispatchSourceTimer
        if let existing = wiggleTimer {
            t = existing
        } else {
            t = DispatchSource.makeTimerSource(queue: .main)
            t.setEventHandler { [weak self] in self?.wiggleFired() }
            t.resume()
            wiggleTimer = t
        }
        t.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(Int(delay * 100)))
    }

    private func disarmWiggle() {
        wiggleTimer?.cancel()
        wiggleTimer = nil
    }

    private func wiggleFired() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
        let plan = Awake.wigglePlan(idle: idle, interval: wiggleInterval)
        if plan.wiggleNow { wiggleCursor() }
        armWiggle(after: plan.nextCheck)
    }

    /// Moves the pointer 1 pt and back. Absolute positions prevent drift at
    /// screen edges; HID-level events reset the system idle time.
    private func wiggleCursor() {
        guard let here = CGEvent(source: nil)?.location else { return }
        let out = CGPoint(x: here.x + 1, y: here.y)
        for (point, dx) in [(out, Int64(1)), (here, Int64(-1))] {
            guard let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                                     mouseCursorPosition: point, mouseButton: .left) else { continue }
            move.setIntegerValueField(.mouseEventDeltaX, value: dx)
            move.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Suspension

    func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(NSNotification.Name, NSNotification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "displaySleep"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session"),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "systemSleep"),
        ]
        for (off, on, reason) in pairs {
            ws.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in self?.suspend(reason) }
            ws.addObserver(forName: on, object: nil, queue: .main) { [weak self] _ in self?.resume(reason) }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.suspend("locked")
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.resume("locked")
        }
    }

    private func suspend(_ reason: String) {
        suspendReasons.insert(reason)
        disarmWiggle()
    }

    private func resume(_ reason: String) {
        guard suspendReasons.remove(reason) != nil, suspendReasons.isEmpty, isWiggling else { return }
        armWiggle(after: wiggleInterval)
    }

    deinit {
        releaseAssertion()
    }
}
