import AppKit
import QuartzCore
import MeowseCore

/// Owns the event taps, the display links and all scroll state.
///
/// Everything runs on a dedicated user-interactive thread whose run loop
/// serialises the tap callback, display-link callbacks and config updates, so
/// no locks are needed and a busy main thread never delays scrolling. Other
/// threads reach the engine only through `perform`.
final class Engine: NSObject {

    static let shared = Engine()

    struct ScreenLink {
        let bounds: CGRect  // global display coordinates, same space as CGEvent.location
        let link: CADisplayLink
    }

    typealias TapStatus = EngineStatus

    /// Called on the main thread when the tap status changes.
    var onStatusChange: ((TapStatus) -> Void)?
    /// Called on the main thread when scrolling switches to another device,
    /// with a touch surface's registry ID.
    var onDeviceChange: ((ScrollDevice, UInt64) -> Void)?

    private var thread: Thread?
    private var runLoop: CFRunLoop?

    // MARK: Engine-thread state

    private var config = EngineConfig(Settings())
    private var trusted = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Listen-only, and enabled only while a glide is in flight.
    private var clickTap: CFMachPort?
    private var clickSource: CFRunLoopSource?
    private var installedMask: CGEventMask = 0
    private var reportedStatus: TapStatus?
    /// The device behind the last hardware scroll since the tap was installed.
    private var device: ScrollDevice?
    /// The glide in flight carries trackpad phases.
    private var phased = false
    /// Registry ID of the touch surface behind `device == .touch`.
    private var touchSender: Int64 = 0
    /// Holds the registry ID of the device that sent an event. Undocumented,
    /// so it's only used to name the touch surface.
    private let senderField = CGEventField(rawValue: 87)!

    private var animator = ScrollAnimator()
    /// The last swallowed wheel event, reused for every synthetic frame.
    private var template: CGEvent?
    private var targetPID: pid_t = 0
    /// Registry ID of the wheel behind the glide. The frames carry it; the
    /// system's copies of them carry the coasting trackpad's.
    private var glideSender: Int64 = 0
    private var heldButtons: UInt32 = 0
    /// Buttons whose press became a shortcut, so their release is swallowed too.
    private var shortcutButtons: UInt32 = 0
    /// When a side wheel last ticked toward a shortcut, and which way.
    private var wheelTickTime = 0.0
    private var wheelTickLeft = false
    private var keySource: CGEventSource?
    private var targets = TargetCache()
    private var screens: [ScreenLink] = []
    private var activeScreen = -1
    private var linkRunning = false

    // MARK: - Lifecycle (main thread)

    func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [unowned self] in
            let rl = CFRunLoopGetCurrent()!
            // A run loop without sources returns immediately; this inert source keeps it parked.
            var ctx = CFRunLoopSourceContext()
            ctx.perform = { _ in }
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &ctx)
            CFRunLoopAddSource(rl, keepAlive, .commonModes)
            self.runLoop = rl
            ready.signal()
            while true { CFRunLoopRun() }
        }
        t.name = "meowse.engine"
        t.qualityOfService = .userInteractive
        t.stackSize = 512 * 1024
        thread = t
        t.start()
        ready.wait()
    }

    /// Runs `block` on the engine thread.
    func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    // MARK: - Main-thread API

    func apply(_ newConfig: EngineConfig) {
        perform { [self] in
            // A change in feel ends the glide under the settings it started with.
            if newConfig.trackpadPhases != config.trackpadPhases || !newConfig.smooth { endGlide() }
            if newConfig.excludedPaths != config.excludedPaths { targets.setExcluded(newConfig.excludedPaths) }
            config = newConfig
            animator.decay = newConfig.decay
            syncTap()
        }
    }

    func cancelGlide() {
        perform { [self] in endGlide() }
    }

    func setTrusted(_ value: Bool) {
        perform { [self] in
            trusted = value
            syncTap()
        }
    }

    /// Re-creates the tap if the system invalidated it, or turns it back on
    /// if it was disabled (after wake, or on retry).
    func revalidate() {
        perform { [self] in
            if let tap, !CFMachPortIsValid(tap) {
                removeTap()
            } else if let tap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if let clickTap, !CFMachPortIsValid(clickTap) {
                removeClickTap()
            }
            syncTap()
        }
    }

    /// Display links are created on the main thread (NSScreen requires it) and
    /// attached to the engine run loop here.
    func setScreens(_ newScreens: [ScreenLink]) {
        perform { [self] in
            endGlide()
            for s in screens { s.link.invalidate() }
            screens = newScreens
            activeScreen = -1
            linkRunning = false
            for s in screens {
                s.link.isPaused = true
                s.link.add(to: .current, forMode: .common)
            }
        }
    }

    // MARK: - Tap

    private func syncTap() {
        syncMainTap()
        syncClickTap()
    }

    private func syncMainTap() {
        let mask = trusted ? config.eventMask : 0
        if mask == installedMask && (tap != nil || mask == 0) {
            report(tap != nil ? .active : .off)
            return
        }
        removeTap()
        guard mask != 0 else {
            report(.off)
            return
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,  // annotated events carry the target PID
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: engineTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            report(.failed)
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        tapSource = source
        installedMask = mask
        report(.active)
    }

    /// Clicks that stop a glide come through a second tap. It only listens,
    /// so a click never waits for Meowse, and it's enabled only while a glide
    /// is in flight, so between glides clicks don't reach Meowse at all.
    private func syncClickTap() {
        let wanted = tap != nil && config.stopsOnClick
        guard wanted != (clickTap != nil) else { return }
        removeClickTap()
        guard wanted, let newTap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: 1 << CGEventMask(CGEventType.leftMouseDown.rawValue),
            callback: clickTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: linkRunning)
        clickTap = newTap
        clickSource = source
    }

    private func removeClickTap() {
        if let clickTap {
            CGEvent.tapEnable(tap: clickTap, enable: false)
            CFMachPortInvalidate(clickTap)
        }
        if let clickSource {
            CFRunLoopRemoveSource(runLoop, clickSource, .commonModes)
        }
        clickTap = nil
        clickSource = nil
    }

    private func report(_ status: TapStatus) {
        guard status != reportedStatus else { return }
        reportedStatus = status
        NSLog("Meowse: event tap %@ (mask 0x%llx, trusted %d)", "\(status)", installedMask, trusted ? 1 : 0)
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(status) }
    }

    private func removeTap() {
        endGlide()
        heldButtons = 0
        shortcutButtons = 0
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Otherwise the window server keeps the disabled tap until the process exits.
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(runLoop, tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
        installedMask = 0
        device = nil
        touchSender = 0
    }

    // MARK: - Events

    @inline(__always)
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .scrollWheel:
            return onScroll(event)
        case .otherMouseDown:
            let n = event.getIntegerValueField(.mouseEventButtonNumber)
            guard n >= 0 && n < 32 else { break }
            heldButtons |= 1 << UInt32(n)
            if let keys = config.buttonKeys[Int(n)] {
                shortcutButtons |= 1 << UInt32(n)
                press(keys)
                return nil
            }
        case .otherMouseUp:
            let n = event.getIntegerValueField(.mouseEventButtonNumber)
            guard n >= 0 && n < 32 else { break }
            heldButtons &= ~(1 << UInt32(n))
            if shortcutButtons & (1 << UInt32(n)) != 0 {
                shortcutButtons &= ~(1 << UInt32(n))
                return nil
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            heldButtons = 0
            shortcutButtons = 0
            endGlide()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Shortcuts

    /// Presses and releases a key combination, as a keyboard would.
    private func press(_ keys: KeyCombo) {
        if keySource == nil { keySource = CGEventSource(stateID: .privateState) }
        let flags = CGEventFlags(rawValue: keys.modifiers)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: keySource, virtualKey: keys.keyCode, keyDown: down) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// One press per turn of the wheel: ticks that follow within a moment,
    /// the same way, belong to the same turn.
    private func wheelTicked(_ keys: KeyCombo, left: Bool) {
        let now = CACurrentMediaTime()
        if left != wheelTickLeft || now - wheelTickTime > 0.3 { press(keys) }
        wheelTickTime = now
        wheelTickLeft = left
    }

    /// A click stops the glide in flight.
    fileprivate func clicked() {
        if animator.isActive { animator.stop { post($0) } }
    }

    @inline(__always)
    private func onScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Continuous events (trackpads, Magic Mouse, already-smooth remote
        // sessions, our own frames) pass through untouched.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            let sender = event.getIntegerValueField(senderField)
            if linkRunning && sender != glideSender && isMomentumEcho(event, continuous: true) { return nil }
            if device != .touch || sender != touchSender { noteDevice(event, continuous: true, sender: sender) }
            return Unmanaged.passUnretained(event)
        }
        // A discrete event with a gesture phase is the system's copy of a wheel
        // tick that ends a coasting touch surface's momentum, not a tick itself.
        // While glides are on, it goes through without the tick's motion: the
        // app still learns the momentum ended (Finder ignores the wheel until
        // it does), and the glide brings the motion.
        guard ScrollDevice.isWheelTick(
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        ) else {
            if config.smooth && isMomentumEcho(event, continuous: false) {
                clearAxis1(event)
                clearAxis2(event)
            }
            return Unmanaged.passUnretained(event)
        }
        if device != .wheel { noteDevice(event, continuous: false) }

        // The tick in lines, with the system's wheel acceleration applied.
        var dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        var dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if dy == 0 && dx == 0 {
            dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) / 10
            dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) / 10
            if dy == 0 && dx == 0 { return Unmanaged.passUnretained(event) }
        }

        // A side wheel with a shortcut presses it instead of scrolling.
        if dy == 0 && (config.wheelLeftKeys != nil || config.wheelRightKeys != nil) {
            let left = SideWheel.turnedLeft(delta: dx, inverted: event.getIntegerValueField(SideWheel.invertedField) != 0)
            if let keys = config.wheelKeys(left: left) {
                wheelTicked(keys, left: left)
                return nil
            }
        }

        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        if !config.excludedPaths.isEmpty && targets.isExcluded(pid) {
            if animator.isActive && pid != targetPID { endGlide() }
            return Unmanaged.passUnretained(event)
        }
        // Bypass is immediate: the glide in flight ends before this tick passes through.
        if animator.isActive && config.unsmoothedKey.isHeld(flags: event.flags.rawValue, heldButtons: heldButtons) {
            endGlide()
        }
        var route = WheelRouter.route(
            lines: dy, dx,
            flags: event.flags.rawValue,
            heldButtons: heldButtons,
            config: config,
            smoothingAllowedForTarget: true
        )
        // The target is looked up only when it could get a glide.
        if route.glides && (pid <= 1 || screens.isEmpty || targets.isDock(pid)) {
            route = WheelRouter.route(lines: dy, dx, flags: event.flags.rawValue, heldButtons: heldButtons,
                                      config: config, smoothingAllowedForTarget: false)
        }

        // A swallowed event's motion is rewritten by every frame, already reversed.
        if !route.swallow {
            if route.reverseY { negateAxis1(event) }
            if route.reverseX { negateAxis2(event) }
        }
        guard route.glides else { return Unmanaged.passUnretained(event) }

        // A swallowed event becomes the template as is; only a mixed event needs a copy.
        let tpl: CGEvent
        if route.swallow {
            tpl = event
        } else {
            guard let copy = event.copy() else { return Unmanaged.passUnretained(event) }
            tpl = copy
            if route.clearY { clearAxis1(event) }
            if route.clearX { clearAxis2(event) }
        }
        tpl.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        tpl.setIntegerValueField(.eventSourceUserData, value: ScrollDevice.frameTag)
        // A tick over another app starts a glide of its own; the rest of the
        // last one isn't carried into it.
        if pid != targetPID && animator.isActive { endGlide() }
        template = tpl
        targetPID = pid
        glideSender = event.getIntegerValueField(senderField)

        let wasIdle = !animator.isActive
        if wasIdle { phased = config.trackpadPhases }
        let now = CACurrentMediaTime()
        selectScreen(for: event.location)
        animator.input(dy: route.glideY, dx: route.glideX, now: now) { post($0) }
        if wasIdle {
            // Post the first frame now rather than at the next vsync.
            let s = screens[activeScreen]
            animator.step(now: now, dt: s.link.duration > 0 ? s.link.duration : 1.0 / 60) { post($0) }
            if animator.isActive { startLink() }
        }

        return route.swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Runs only for an event from a different device than the last one (or
    /// one of our own frames, which it ignores), so the main thread hears
    /// about switches, not events.
    @inline(never)
    private func noteDevice(_ event: CGEvent, continuous: Bool, sender: Int64 = 0) {
        guard let d = ScrollDevice.of(
            continuous: continuous,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            userData: event.getIntegerValueField(.eventSourceUserData),
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        ) else { return }
        // A gesture on a touch surface takes over from the glide.
        if d == .touch && animator.isActive { endGlide() }
        device = d
        touchSender = sender
        DispatchQueue.main.async { [weak self] in self?.onDeviceChange?(d, UInt64(bitPattern: sender)) }
    }

    @inline(never)
    private func isMomentumEcho(_ event: CGEvent, continuous: Bool) -> Bool {
        ScrollDevice.isMomentumEcho(
            continuous: continuous,
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            tagged: event.getIntegerValueField(.eventSourceUserData) == ScrollDevice.frameTag
        )
    }

    /// Display-link callback; runs only while a glide is in flight.
    @objc func tick(_ link: CADisplayLink) {
        guard animator.isActive else { stopLink(); return }
        // A link just handed off can still deliver one callback.
        guard activeScreen >= 0, screens[activeScreen].link === link else { return }
        var dt = link.targetTimestamp - link.timestamp
        if dt <= 0 { dt = link.duration }
        animator.step(now: CACurrentMediaTime(), dt: dt) { post($0) }
    }

    // MARK: - Posting

    @inline(__always)
    private func post(_ f: ScrollAnimator.Frame) {
        defer {
            if f.isFinal {
                stopLink()
                template = nil
            }
        }
        guard let ev = template, targetPID > 1 else { return }

        if f.isMarker {
            // Markers only close trackpad phases; plain glides have none.
            if phased {
                write(ev, f.dy, f.dx, f.scrollPhase, f.momentumPhase)
                ev.postToPid(targetPID)
            }
            return
        }

        if phased {
            write(ev, f.dy, f.dx, f.scrollPhase, f.momentumPhase)
        } else {
            setMotion(ev, f.dy, f.dx)
        }
        // Straight to the target process, so the glide stays with its window if the cursor moves.
        ev.postToPid(targetPID)
    }

    /// Fills all three delta fields per axis as CoreGraphics does for a pixel
    /// scroll, so apps reading line or fixed-point deltas see this frame's
    /// motion rather than the original notch's. The line delta goes first:
    /// setting it recomputes the other two.
    @inline(__always)
    private func setMotion(_ ev: CGEvent, _ dy: Double, _ dx: Double) {
        ev.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: ScrollMath.lineDelta(points: dy))
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy / 10)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        ev.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: ScrollMath.lineDelta(points: dx))
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx / 10)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
    }

    @inline(__always)
    private func write(_ ev: CGEvent, _ dy: Double, _ dx: Double, _ scroll: Double, _ momentum: Double) {
        setMotion(ev, dy, dx)
        ev.setDoubleValueField(.scrollWheelEventScrollPhase, value: scroll)
        ev.setDoubleValueField(.scrollWheelEventMomentumPhase, value: momentum)
    }

    /// Stops any glide now, posting its closing phase so the app isn't left
    /// mid-gesture.
    private func endGlide() {
        animator.stop { post($0) }
        template = nil
        stopLink()
    }

    // MARK: - Display links

    @inline(__always)
    private func selectScreen(for p: CGPoint) {
        if activeScreen >= 0 && screens[activeScreen].bounds.contains(p) { return }
        var idx = 0
        for i in screens.indices where screens[i].bounds.contains(p) {
            idx = i
            break
        }
        if idx == activeScreen { return }
        if linkRunning {
            // Hand the glide over to this screen's link.
            if activeScreen >= 0 { screens[activeScreen].link.isPaused = true }
            screens[idx].link.isPaused = false
        }
        activeScreen = idx
    }

    /// A glide begins: run the display link and listen for clicks.
    private func startLink() {
        guard !linkRunning, activeScreen >= 0 else { return }
        screens[activeScreen].link.isPaused = false
        linkRunning = true
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
    }

    private func stopLink() {
        guard linkRunning else { return }
        if activeScreen >= 0 { screens[activeScreen].link.isPaused = true }
        linkRunning = false
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: false) }
    }

    // MARK: - Field edits

    private func negateAxis1(_ e: CGEvent) {
        let fix = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let pt = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let fpt = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -fix)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -pt)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fpt)
    }

    private func negateAxis2(_ e: CGEvent) {
        let fix = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let pt = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let fpt = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -fix)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -pt)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fpt)
    }

    private func clearAxis1(_ e: CGEvent) {
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
    }

    private func clearAxis2(_ e: CGEvent) {
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
    }
}

/// The click tap's own trampoline. Turning the tap off between glides makes
/// the system report it disabled; only clicks matter here.
private func clickTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .leftMouseDown { Unmanaged<Engine>.fromOpaque(refcon!).takeUnretainedValue().clicked() }
    return Unmanaged.passUnretained(event)
}

/// C-convention trampoline. `refcon` is the unretained Engine singleton.
private func engineTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    Unmanaged<Engine>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
}
