import Foundation
import CoreGraphics

/// Asculta global tastele (inclusiv fn) printr-un CGEventTap rulat pe un thread dedicat,
/// ca tastarea in alte aplicatii sa nu fie niciodata blocata de UI-ul nostru.
/// Necesita permisiunea Accessibility (sau Input Monitoring pentru modul listen-only).
final class HotkeyMonitor: @unchecked Sendable {
    /// Callback-urile sunt apelate pe main thread.
    var onEvent: ((HotkeyEvent) -> Void)?
    var onEscape: (() -> Void)?
    var onCaptureProgress: ((Set<ModifierKey>) -> Void)?
    var onCaptureFinished: ((Hotkey?) -> Void)?

    private let lock = NSLock()
    private var machine: HotkeyStateMachine
    private var capture: HotkeyCapture?
    private var swallowEscape = false

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private(set) var isRunning = false
    private(set) var isListenOnly = false

    private static let escapeKeyCode: Int64 = 53

    /// Marcaj pus pe evenimentele de tastatura generate de hau-di (vezi TextInserter),
    /// ca lipirea unui text sa nu anuleze o dictare noua inceputa intre timp.
    static let syntheticEventMarker: Int64 = 0x4841_5544 // "HAUD"

    init(hotkey: Hotkey, handsFreeEnabled: Bool) {
        machine = HotkeyStateMachine(hotkey: hotkey, handsFreeEnabled: handsFreeEnabled)
    }

    deinit {
        stop()
    }

    // MARK: - Configurare (thread-safe)

    func update(hotkey: Hotkey, handsFreeEnabled: Bool) {
        lock.lock()
        machine.updateConfiguration(hotkey: hotkey, handsFreeEnabled: handsFreeEnabled)
        lock.unlock()
    }

    /// Cat timp e activ, Esc e consumat de noi (anulare) si nu mai ajunge la aplicatia din fata.
    func setEscapeCapture(_ enabled: Bool) {
        lock.lock()
        swallowEscape = enabled
        lock.unlock()
    }

    func resetStateMachine() {
        lock.lock()
        machine.reset()
        lock.unlock()
    }

    func beginCapture() {
        lock.lock()
        capture = HotkeyCapture()
        lock.unlock()
    }

    func cancelCapture() {
        lock.lock()
        capture = nil
        lock.unlock()
    }

    // MARK: - Pornire / oprire

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let mask = (CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var createdTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: hotkeyEventTapCallback, userInfo: refcon)
        isListenOnly = false
        if createdTap == nil {
            // Fara Accessibility, un tap pasiv merge cu permisiunea Input Monitoring.
            createdTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: hotkeyEventTapCallback, userInfo: refcon)
            isListenOnly = createdTap != nil
        }
        guard let eventTap = createdTap else {
            Log.hotkey.error("CGEvent.tapCreate a esuat (lipsesc permisiunile)")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return false
        }
        tap = eventTap

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            self?.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "hau-di.HotkeyMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        self.thread = thread
        isRunning = true
        Log.hotkey.info("Hotkey monitor pornit (listenOnly: \(self.isListenOnly))")
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        isRunning = false
    }

    // MARK: - Procesarea evenimentelor (thread-ul tap-ului)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let pressed = ModifierKey.pressedKeys(flags: event.flags.rawValue, changedKeyCode: keyCode)
            let now = ProcessInfo.processInfo.systemUptime

            var events: [HotkeyEvent] = []
            var captureProgress: Set<ModifierKey>?
            var captured: Hotkey?
            var captureEnded = false

            lock.lock()
            if var current = capture {
                if let result = current.update(pressed) {
                    captured = result
                    captureEnded = true
                    capture = nil
                } else {
                    captureProgress = current.collected
                    capture = current
                }
            } else {
                events = machine.modifiersChanged(pressed, at: now)
            }
            lock.unlock()

            if captureEnded || captureProgress != nil || !events.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let progress = captureProgress { self.onCaptureProgress?(progress) }
                    if captureEnded { self.onCaptureFinished?(captured) }
                    for item in events { self.onEvent?(item) }
                }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let now = ProcessInfo.processInfo.systemUptime

            let isEscape = keyCode == Self.escapeKeyCode
            lock.lock()
            let capturing = capture != nil
            if capturing && isEscape { capture = nil }
            let escapeActive = swallowEscape && isEscape
            let events = (capturing || isRepeat) ? [] : machine.keyDown(at: now)
            lock.unlock()

            if capturing && isEscape {
                DispatchQueue.main.async { [weak self] in self?.onCaptureFinished?(nil) }
                return isListenOnly ? Unmanaged.passUnretained(event) : nil
            }
            if escapeActive && !isRepeat {
                DispatchQueue.main.async { [weak self] in self?.onEscape?() }
            }
            let swallow = escapeActive && !isListenOnly
            if !events.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    for item in events { self?.onEvent?(item) }
                }
            }
            return swallow ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Callback C pentru CGEventTap: delega catre instanta HotkeyMonitor din `userInfo`.
private func hotkeyEventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                    userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
