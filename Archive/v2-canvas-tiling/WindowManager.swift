import AppKit
import ApplicationServices
import Combine

/// A real window, either free-floating on the infinite desktop canvas or docked in the tree.
final class ManagedWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let appName: String
    let icon: NSImage?
    var title = ""

    /// Where a floating window lives on the canvas (AX coordinates when offset == 0).
    var canvasFrame: CGRect
    /// Where the window actually is on screen right now.
    var realFrame: CGRect

    /// Pinned windows stick to the screen and ignore panning and zooming (like pinned tabs).
    var pinned = false
    /// Hidden windows are "parked" in a screen corner with a 1px sliver showing.
    var parked = false
    /// Visible on the current Space (not minimized, not hidden, not on another Space).
    var present = true

    var lastTarget: CGPoint?
    var lastActual: CGPoint?

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.element = element
        let app = NSRunningApplication(processIdentifier: pid)
        self.appName = app?.localizedName ?? "App"
        self.icon = app?.icon
        self.canvasFrame = frame
        self.realFrame = frame
    }

    var displayTitle: String { title.isEmpty ? appName : title }
}

final class WindowManager: ObservableObject {
    static let shared = WindowManager()
    private var ws: Workspace { Workspace.shared }

    /// Desktop canvas viewport position. real = canvas - offset.
    @Published private(set) var offset: CGPoint = .zero
    /// Bumped whenever anything changes, so views redraw.
    @Published private(set) var revision = 0

    private(set) var records: [CGWindowID: ManagedWindow] = [:]
    private var order: [CGWindowID] = []

    private var appElements: [pid_t: AXUIElement] = [:]
    private var refreshTimer: Timer?
    private var panTimer: Timer?
    private var flyTimer: Timer?
    private var frameAnim: Timer?
    private var pendingPan = CGPoint.zero
    private var lastPanTime = Date.distantPast
    private var lastFocusedID: CGWindowID?
    private var saveWork: DispatchWorkItem?
    private var saved: SavedState?

    var windows: [ManagedWindow] { order.compactMap { records[$0] }.filter(\.present) }
    var canvasWindows: [ManagedWindow] { windows.filter { !$0.pinned && !ws.isDocked($0.id) } }
    var pinnedWindows: [ManagedWindow] { windows.filter(\.pinned) }
    var isMoving: Bool { flyTimer != nil || panTimer != nil || frameAnim != nil }

    // MARK: Lifecycle

    func start() {
        loadState()
        refresh()
        ws.applyAll(animated: false)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.isMoving, !DragDock.shared.active else { return }
            self.refreshInBackground()
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.followFocus(pid: app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.appElements[app.processIdentifier] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refreshInBackground() }
        }
    }

    // MARK: Screens

    var screenRects: [CGRect] { NSScreen.screens.map(\.axFrame) }
    /// Where floating windows can currently be seen (the live desktop pane on each screen).
    var viewportRects: [CGRect] { ws.liveRects }

    func isVisible(_ r: CGRect) -> Bool {
        viewportRects.contains { s in
            let i = s.intersection(r)
            return !i.isNull && i.width >= 80 && i.height >= 50
        }
    }

    /// A corner where a window can hide with nothing but a sliver showing and not spill onto another display.
    private var parkPoint: CGPoint {
        let screens = screenRects
        let sorted = screens.sorted { ($0.maxX + $0.maxY) > ($1.maxX + $1.maxY) }
        for s in sorted {
            let quadrant = CGRect(x: s.maxX - 1, y: s.maxY - 1, width: 20000, height: 20000)
            if !screens.contains(where: { $0 != s && $0.intersects(quadrant) }) {
                return CGPoint(x: s.maxX - 1, y: s.maxY - 1)
            }
        }
        let u = screens.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: u.maxX - 1, y: u.maxY - 1)
    }

    private var mouseViewport: CGRect { ws.mouseSpace.liveDesktop ?? NSScreen.underMouse.axVisibleFrame }

    // MARK: Discovery

    private func element(for pid: pid_t) -> AXUIElement {
        if let e = appElements[pid] { return e }
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.1)
        appElements[pid] = e
        return e
    }

    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(info.compactMap { d in
            (d[kCGWindowLayer as String] as? Int) == 0 ? (d[kCGWindowNumber as String] as? CGWindowID) : nil
        })
    }

    /// What the system looks like right now. Gathered off the main thread, because asking
    /// every app about its windows is slow and must never stall the UI or the mouse.
    private struct Snapshot {
        struct Item { let pid: pid_t; let wid: CGWindowID; let element: AXUIElement; let frame: CGRect; let title: String }
        var items: [Item] = []
        var all = Set<CGWindowID>()
        var failed = Set<pid_t>()
        var generation = 0
    }

    private let scanQueue = DispatchQueue(label: "fractal.scan", qos: .userInitiated)
    private var scanElements: [pid_t: AXUIElement] = [:]   // only touched on scanQueue
    private var scanning = false
    /// Bumped whenever we move a window; a snapshot taken before a move is stale.
    private var generation = 0

    private func takeSnapshot(apps: [(pid_t, Bool)], generation: Int) -> Snapshot {
        var s = Snapshot(generation: generation)
        let onScreen = Self.onScreenWindowIDs()
        for (pid, hidden) in apps {
            let appEl: AXUIElement
            if let e = scanElements[pid] { appEl = e } else {
                appEl = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appEl, 0.1)
                scanElements[pid] = appEl
            }
            guard let wins: [AXUIElement] = AX.attr(appEl, kAXWindowsAttribute) else { s.failed.insert(pid); continue }
            for w in wins {
                guard let wid = AX.windowID(w), AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { continue }
                s.all.insert(wid)
                guard !hidden, onScreen.contains(wid), !AX.bool(w, "AXFullScreen"),
                      let pos = AX.position(w), let size = AX.size(w) else { continue }
                s.items.append(.init(pid: pid, wid: wid, element: w, frame: CGRect(origin: pos, size: size),
                                     title: AX.string(w, kAXTitleAttribute) ?? ""))
            }
        }
        return s
    }

    private var scanApps: [(pid_t, Bool)] {
        let me = getpid()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map { ($0.processIdentifier, $0.isHidden) }
    }

    /// Periodic, non-blocking sync.
    func refreshInBackground() {
        guard AXIsProcessTrusted(), !scanning else { return }
        scanning = true
        let apps = scanApps
        let gen = generation
        scanQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.takeSnapshot(apps: apps, generation: gen)
            DispatchQueue.main.async {
                self.scanning = false
                // Discard if we moved windows meanwhile, or the user is mid-gesture.
                guard snap.generation == self.generation, !self.isMoving, !DragDock.shared.active else { return }
                self.process(snap)
            }
        }
    }

    /// Immediate sync, for explicit user actions that need fresh state.
    func refresh() {
        guard AXIsProcessTrusted() else { return }
        let apps = scanApps
        let gen = generation
        let snap = scanQueue.sync { takeSnapshot(apps: apps, generation: gen) }
        process(snap)
    }

    /// Syncs our model with the snapshot. Detects user moves, new/closed windows.
    private func process(_ snap: Snapshot) {
        var seen = Set<CGWindowID>()
        for it in snap.items {
            seen.insert(it.wid)
            if let mw = records[it.wid] {
                update(mw, real: it.frame, title: it.title)
            } else {
                adopt(wid: it.wid, pid: it.pid, element: it.element, real: it.frame, title: it.title)
            }
        }
        let all = snap.all
        let failed = snap.failed
        for (id, mw) in records where mw.present && !seen.contains(id) { mw.present = false }

        ws.refreshed(allIDs: all, failedPids: failed)

        // Forget closed windows.
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        for (id, mw) in records where !all.contains(id) && (!failed.contains(mw.pid) || !running.contains(mw.pid)) {
            records[id] = nil
        }
        order.removeAll { records[$0] == nil }

        checkFocusChange()
        changed()
    }

    private func adopt(wid: CGWindowID, pid: pid_t, element: AXUIElement, real: CGRect, title: String) {
        let mw = ManagedWindow(id: wid, pid: pid, element: element, frame: real)
        mw.title = title
        records[wid] = mw
        order.append(wid)
        if ws.isDocked(wid) { mw.lastActual = real.origin; return }
        if let s = saved?.windows[String(wid)] {
            // Resume a window we were managing before a relaunch.
            mw.pinned = s.pinned
            mw.parked = s.parked && !s.pinned
            if mw.parked {
                mw.canvasFrame = CGRect(origin: s.frame.origin, size: real.size)
                mw.lastActual = real.origin
                mw.lastTarget = real.origin
                place(mw, at: parkPoint)
                return
            }
        }
        rebase(mw, real)
    }

    private func update(_ mw: ManagedWindow, real: CGRect, title: String) {
        mw.title = title
        mw.realFrame = real
        let docked = ws.isDocked(mw.id)
        if !docked { mw.canvasFrame.size = real.size }

        if !mw.present {
            // Came back (unminimized, unhidden, returned from another Space).
            mw.present = true
            mw.lastActual = real.origin
            if docked { return }
            if mw.parked && !mw.pinned { place(mw, at: parkPoint) } else { rebase(mw, real) }
            return
        }
        if docked { ws.observeDocked(mw, real: real); return }
        if mw.pinned { return }
        guard let a = mw.lastActual, (a - real.origin).length > 2 else { return }
        if ws.isSettling { return }   // macOS shuffling windows after a display change, not you
        // The user (or the app) moved it.
        if mw.parked {
            if isVisible(real) { mw.parked = false; rebase(mw, real) } else { mw.lastActual = real.origin }
        } else {
            rebase(mw, real)
        }
    }

    /// Treat the window's current real position as the truth.
    private func rebase(_ mw: ManagedWindow, _ real: CGRect) {
        mw.canvasFrame = CGRect(origin: real.origin + offset, size: real.size)
        mw.lastActual = real.origin
        mw.lastTarget = real.origin
        mw.realFrame = real
    }

    /// Re-read a window from the system and make it a free-floating canvas window again.
    func adoptFloating(_ mw: ManagedWindow) {
        let pos = AX.position(mw.element) ?? mw.realFrame.origin
        let size = AX.size(mw.element) ?? mw.realFrame.size
        mw.parked = false
        rebase(mw, CGRect(origin: pos, size: size))
    }

    // MARK: Moving real windows

    /// Place floating windows according to the canvas offset and live desktop panes.
    func apply() {
        let park = parkPoint
        for mw in canvasWindows where mw.id != ws.excludedWindow { place(mw, at: park) }
    }

    private func place(_ mw: ManagedWindow, at spot: CGPoint) {
        let target = mw.canvasFrame.offsetBy(dx: -offset.x, dy: -offset.y)
        if isVisible(target) {
            if mw.parked || mw.lastTarget != target.origin {
                move(mw, to: target.origin)
                mw.parked = false
            }
        } else if !mw.parked {
            park(mw, at: spot)
        }
    }

    /// Display geometry changed: the old hiding corner may now be in the middle of a screen.
    func repark() {
        let p = parkPoint
        for mw in records.values where mw.parked { move(mw, to: p) }
    }

    func park(_ mw: ManagedWindow, at p: CGPoint? = nil) {
        move(mw, to: p ?? parkPoint)
        mw.parked = true
    }

    private func move(_ mw: ManagedWindow, to p: CGPoint) {
        generation &+= 1
        AX.setPosition(mw.element, p)
        mw.lastTarget = p
        let actual = AX.position(mw.element) ?? p
        mw.lastActual = actual
        mw.realFrame.origin = actual
    }

    private func setFrameNow(_ mw: ManagedWindow, _ r: CGRect) {
        generation &+= 1
        AX.setSize(mw.element, r.size)
        AX.setPosition(mw.element, r.origin)
        AX.setSize(mw.element, r.size)
        let pos = AX.position(mw.element) ?? r.origin
        let size = AX.size(mw.element) ?? r.size
        mw.realFrame = CGRect(origin: pos, size: size)
        mw.lastActual = pos
        mw.lastTarget = pos
        mw.parked = false
    }

    /// Put docked windows into their panes in one decisive step. Real apps re-layout on every
    /// resize, so interpolating frames looks like stutter, not animation. Windows already
    /// in place are left alone.
    func animateFrames(_ items: [(ManagedWindow, CGRect)], animated: Bool, done: @escaping () -> Void) {
        for (mw, r) in items {
            if !mw.parked, abs(mw.realFrame.minX - r.minX) < 1, abs(mw.realFrame.minY - r.minY) < 1,
               abs(mw.realFrame.width - r.width) < 1, abs(mw.realFrame.height - r.height) < 1 { continue }
            setFrameNow(mw, r)
        }
        done()
    }

    func bump() { changed() }

    private func changed() {
        revision &+= 1
        scheduleSave()
    }

    // MARK: Canvas navigation (inside the desktop pane)

    func setOffset(_ p: CGPoint) {
        offset = p
        apply()
        changed()
    }

    /// Continuous panning (trackpad). Coalesced to 60fps.
    func panBy(dx: CGFloat, dy: CGFloat) {
        if Date().timeIntervalSince(lastPanTime) > 0.4, !isMoving {
            ws.ensureDesktopLive()
        }
        lastPanTime = Date()
        cancelFly()
        pendingPan.x += dx
        pendingPan.y += dy
        guard panTimer == nil else { return }
        panTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.pendingPan == .zero {
                if Date().timeIntervalSince(self.lastPanTime) > 0.3 { t.invalidate(); self.panTimer = nil }
                return
            }
            let d = self.pendingPan
            self.pendingPan = .zero
            self.setOffset(self.offset - d)
        }
    }

    /// Animated move of the canvas viewport.
    func fly(to target: CGPoint, duration: Double = 0.3) {
        cancelFly()
        let start = offset
        guard (target - start).length > 0.5 else { return }
        let t0 = CACurrentMediaTime()
        flyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = min(1, (CACurrentMediaTime() - t0) / duration)
            let e = 1 - pow(1 - k, 3)
            self.setOffset(start + (target - start) * CGFloat(e))
            if k >= 1 { t.invalidate(); self.flyTimer = nil }
        }
    }

    private func cancelFly() {
        flyTimer?.invalidate()
        flyTimer = nil
    }

    /// Step the canvas by fractions of a screen (arrow hotkeys).
    func step(_ dx: CGFloat, _ dy: CGFloat) {
        ws.ensureDesktopLive()
        let s = mouseViewport
        fly(to: offset + CGPoint(x: dx * s.width * 0.8, y: dy * s.height * 0.8))
    }

    func home() {
        ws.ensureDesktopLive()
        fly(to: .zero)
    }

    /// Center the given screen's viewport on a canvas point.
    func center(on p: CGPoint, screen: CGRect) {
        fly(to: p - screen.mid)
    }

    func reveal(_ mw: ManagedWindow) {
        if ws.isDocked(mw.id) { ws.revealDocked(mw); return }
        guard !mw.pinned else { return }
        ws.ensureDesktopLive()
        let target = mw.canvasFrame.offsetBy(dx: -offset.x, dy: -offset.y)
        let s = mouseViewport
        if !mw.parked && s.contains(target) { return }
        let f = mw.canvasFrame
        let x = f.width <= s.width ? f.midX - s.midX : f.minX - s.minX
        let y = f.height <= s.height ? f.midY - s.midY : f.minY - s.minY
        fly(to: CGPoint(x: x, y: y))
    }

    func focus(_ mw: ManagedWindow) {
        AX.raise(mw.element)
        if let app = NSRunningApplication(processIdentifier: mw.pid) {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    // MARK: Focus following — cmd-tab to a hidden window takes you to it

    private func focusedWindow(pid: pid_t) -> ManagedWindow? {
        guard let fw: AXUIElement = AX.attr(element(for: pid), kAXFocusedWindowAttribute),
              let wid = AX.windowID(fw) else { return nil }
        return records[wid]
    }

    func frontWindow() -> ManagedWindow? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return nil }
        if let w = focusedWindow(pid: front.processIdentifier) { return w }
        refresh()
        return focusedWindow(pid: front.processIdentifier)
    }

    private func followFocus(pid: pid_t) {
        guard pid != getpid(), !DragDock.shared.active else { return }
        if focusedWindow(pid: pid) == nil { refresh() }
        guard let mw = focusedWindow(pid: pid) else { return }
        lastFocusedID = mw.id
        if mw.parked && !mw.pinned { reveal(mw) }
    }

    private func checkFocusChange() {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              let mw = focusedWindow(pid: front.processIdentifier), mw.id != lastFocusedID else { return }
        lastFocusedID = mw.id
        if mw.parked && !mw.pinned { reveal(mw) }
    }

    // MARK: Pinning

    func togglePinFront() {
        guard let mw = frontWindow() else { NSSound.beep(); return }
        togglePin(mw)
        Toast.show(mw.pinned ? "📌 Pinned \(mw.appName)" : "Unpinned \(mw.appName)")
    }

    func togglePin(_ mw: ManagedWindow) {
        if mw.pinned {
            mw.pinned = false
            adoptFloating(mw)
            if !isVisible(mw.realFrame) { ws.ensureDesktopLive() }
        } else {
            if ws.isDocked(mw.id) { ws.detach(mw) }
            let s = NSScreen.underMouse.axVisibleFrame
            if mw.parked || !s.intersects(mw.realFrame) {
                move(mw, to: CGPoint(x: s.midX - mw.realFrame.width / 2, y: max(s.minY, s.midY - mw.realFrame.height / 2)))
            }
            mw.parked = false
            mw.pinned = true
        }
        ws.applyAll()
    }

    /// After a window was dragged around in the canvas map.
    func canvasFrameChanged(_ mw: ManagedWindow) {
        mw.lastTarget = nil
        place(mw, at: parkPoint)
        changed()
    }

    /// Move a floating window onto the center of the viewport of the given screen.
    func bringHere(_ mw: ManagedWindow, screen: CGRect) {
        if mw.pinned { togglePin(mw) }
        if ws.isDocked(mw.id) { ws.undock(mw, keepPosition: false); return }
        let c = screen.mid + offset
        mw.canvasFrame.origin = CGPoint(x: c.x - mw.canvasFrame.width / 2, y: max(screen.minY + offset.y, c.y - mw.canvasFrame.height / 2))
        canvasFrameChanged(mw)
    }

    /// Pull every hidden floating window into view. On quit, docked ones too — nothing is ever lost.
    func gatherAll(forQuit: Bool = false) {
        if forQuit { ws.prepareForQuit() } else { ws.ensureDesktopLive() }
        let s = forQuit ? NSScreen.underMouse.axVisibleFrame : mouseViewport
        var i: CGFloat = 0
        for mw in records.values where !mw.pinned && (forQuit || !ws.isDocked(mw.id)) {
            let hidden = ws.isDocked(mw.id) ? mw.parked : (mw.parked || !isVisible(mw.canvasFrame.offsetBy(dx: -offset.x, dy: -offset.y)))
            guard hidden else { continue }
            if AX.size(mw.element).map({ $0.width < 400 || $0.height < 300 }) ?? false {
                AX.setSize(mw.element, CGSize(width: min(900, s.width * 0.6), height: min(700, s.height * 0.6)))
            }
            let p = CGPoint(x: s.minX + 40 + i.truncatingRemainder(dividingBy: 12) * 32,
                            y: s.minY + 30 + i.truncatingRemainder(dividingBy: 12) * 32)
            move(mw, to: p)
            mw.parked = false
            mw.canvasFrame.origin = p + offset
            i += 1
        }
        changed()
    }

    // MARK: Persistence (so a relaunch resumes the canvas)

    struct SavedWindow: Codable { var frame: CGRect; var pinned: Bool; var parked: Bool }
    struct SavedState: Codable {
        var offset: CGPoint
        var windows: [String: SavedWindow]
    }

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fractal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("canvas.json")
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        saved = s
        offset = s.offset
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow(keepWindows: Bool = true) {
        var wins: [String: SavedWindow] = [:]
        if keepWindows {
            for mw in records.values where (mw.parked || mw.pinned) && !ws.isDocked(mw.id) {
                wins[String(mw.id)] = SavedWindow(frame: mw.canvasFrame, pinned: mw.pinned, parked: mw.parked)
            }
        }
        let s = SavedState(offset: keepWindows ? offset : .zero, windows: wins)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL) }
    }
}
