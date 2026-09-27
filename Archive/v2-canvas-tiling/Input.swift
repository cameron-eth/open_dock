import AppKit
import Carbon

/// Global hotkeys via Carbon (needs no extra permission).
final class Hotkeys {
    static let shared = Hotkeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    func setup() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Hotkeys.shared.handlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)

        let wm = WindowManager.shared
        let ws = Workspace.shared
        let co = UInt32(controlKey | optionKey)
        let cos = co | UInt32(shiftKey)

        // Hierarchy
        register(49, co) { ws.toggleOverview() }                        // space
        register(2, co) { ws.toggleDesktop() }                          // D
        register(3, co) { ws.toggleFocusFront() }                       // F
        register(27, co) { ws.zoomOut() }                               // -
        register(24, co) { ws.zoomIn() }                                // =
        register(33, co) { ws.goBack() }                                // [
        register(30, co) { ws.goForward() }                             // ]
        register(32, co) { ws.undockFront() }                           // U
        register(123, cos) { ws.dockFront(.left) }                      // ⇧←
        register(124, cos) { ws.dockFront(.right) }                     // ⇧→
        register(126, cos) { ws.dockFront(.top) }                       // ⇧↑
        register(125, cos) { ws.dockFront(.bottom) }                    // ⇧↓

        // Desktop canvas
        register(123, co) { wm.step(-1, 0) }                            // ←
        register(124, co) { wm.step(1, 0) }                             // →
        register(125, co) { wm.step(0, 1) }                             // ↓
        register(126, co) { wm.step(0, -1) }                            // ↑
        register(29, co) { wm.home() }                                  // 0
        register(46, co) { OverviewController.shared.toggle() }         // M  canvas map
        register(5, co) { wm.gatherAll(); Toast.show("Gathered floating windows here") } // G

        // Misc
        register(35, co) { wm.togglePinFront() }                        // P
        register(11, co) { DockController.shared.toggle() }             // B  bar

        let digits: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]     // 1…9
        for (i, key) in digits.enumerated() {
            let n = i + 1
            register(key, co) { ws.jumpFrame(n) }
            register(key, cos) { ws.saveFrame(n) }
        }
    }

    private func register(_ key: UInt32, _ mods: UInt32, _ fn: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key, mods, EventHotKeyID(signature: OSType(0x4652_4354), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            handlers[id] = fn
            refs.append(ref)
        } else {
            NSLog("Fractal: hotkey \(key) already taken by another app")
        }
    }
}

/// Event tap:
///  • ⌃⌥ + scroll        → step in/out of the hierarchy (consumed)
///  • ⌃⌥⌘ + scroll       → pan the infinite desktop canvas (consumed)
///  • mouse down/drag/up → drag-to-dock + double-click desktop (observed, never consumed)
final class EventTap {
    static let shared = EventTap()
    fileprivate var scrollTap: CFMachPort?
    fileprivate var mouseTap: CFMachPort?

    /// Taps run on their own thread so nothing Fractal does can ever delay your mouse.
    func start() {
        let thread = Thread { [weak self] in
            self?.install()
            CFRunLoopRun()
        }
        thread.name = "fractal.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func install() {
        // Scroll: may consume the event (⌃⌥ held), so it has to be an active tap.
        scrollTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                      callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = EventTap.shared.scrollTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let f = event.flags
            guard type == .scrollWheel, f.contains(.maskControl), f.contains(.maskAlternate) else {
                return Unmanaged.passUnretained(event)
            }
            var dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            var dx = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            if f.contains(.maskCommand) {
                if !continuous { dx *= 6; dy *= 6 }
                // Windows follow your fingers, like dragging paper.
                DispatchQueue.main.async { WindowManager.shared.panBy(dx: dx * 1.6, dy: dy * 1.6) }
            } else {
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
                let lineDelta = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                let delta = continuous ? dy : lineDelta
                DispatchQueue.main.async {
                    Workspace.shared.scrollStep(delta, continuous: continuous, momentum: momentum)
                }
            }
            return nil
        }, userInfo: nil)

        // Mouse: observe only — clicks and drags pass straight through untouched.
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        mouseTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                     eventsOfInterest: types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) },
                                     callback: { _, type, event, _ in
            let p = event.location
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = EventTap.shared.mouseTap { CGEvent.tapEnable(tap: t, enable: true) }
            case .leftMouseDown:
                let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
                DispatchQueue.main.async { DragDock.shared.mouseDown(at: p, clickCount: clicks) }
            case .leftMouseDragged:
                DragDock.shared.enqueueDrag(p)
            case .leftMouseUp:
                DispatchQueue.main.async { DragDock.shared.mouseUp(at: p) }
            default: break
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)

        for tap in [scrollTap, mouseTap] {
            guard let tap else { NSLog("Fractal: could not create event tap"); continue }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
