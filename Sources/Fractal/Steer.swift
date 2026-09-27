import AppKit

/// Everything you can do to a window, kept to a small, predictable set.
enum Steer {
    static let gap: CGFloat = 6
    private static var tracker: Tracker { Tracker.shared }

    /// The usable part of a display: above Fractal's dock, below the menu bar.
    static func area(_ screen: NSScreen) -> CGRect {
        var r = screen.axVisibleFrame
        if DockController.shared.visible { r.size.height -= DockController.reserve }
        return r.insetBy(dx: gap, dy: gap).integral
    }

    // MARK: Focus

    static func focus(_ w: TrackedWindow) {
        guard let app = tracker.apps[w.pid] else { return }
        if w.minimized { AX.setMinimized(w.element, false) }
        bringForward(app.app, window: w.element)
    }

    /// Bring an app to the front from the background. Since macOS 14 a background app can't simply
    /// `activate()` another one (the request is silently dropped), so: tell the app it's frontmost via
    /// Accessibility and raise the window; if that didn't take, ask LaunchServices like the Dock does.
    static func bringForward(_ app: NSRunningApplication, window: AXUIElement?) {
        if app.isHidden { app.unhide() }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window { AX.raise(window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                launch(app)
                if let window { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { AX.raise(window) } }
            }
            tracker.scanSoon()
        }
    }

    /// Same as clicking it in the macOS Dock: activates it, and reopens a window if it has none.
    static func launch(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// Clicking an app in the dock: bring it forward on this display; click again to cycle its windows.
    static func click(_ app: AppGroup, on screen: NSScreen) {
        let here = app.windows(on: Tracker.key(screen))
        let open = here.filter { !$0.minimized }
        if open.isEmpty {
            if let m = here.first { focus(m); return }                               // restore a minimized one
            if let other = app.windows.min(by: { $0.z < $1.z }) { focus(other); return }
            if app.hidden { app.app.unhide() }
            launch(app.app)                                                          // no windows: reopen, like the Dock
            tracker.scanSoon()
            return
        }
        if app.pid == tracker.frontPID, open.count > 1,
           let i = open.firstIndex(where: { $0.id == tracker.focusedWindowID }) {
            focus(open[(i + 1) % open.count])
        } else {
            focus(open.min { $0.z < $1.z }!)
        }
    }

    // MARK: Layout

    enum Placement { case left, right, maximize }

    static func place(_ w: TrackedWindow, _ p: Placement) {
        guard let screen = Tracker.screen(for: w.frame) else { return }
        let a = area(screen)
        let half = (a.width - gap) / 2
        let r: CGRect
        switch p {
        case .left: r = CGRect(x: a.minX, y: a.minY, width: half, height: a.height)
        case .right: r = CGRect(x: a.maxX - half, y: a.minY, width: half, height: a.height)
        case .maximize: r = a
        }
        if w.minimized { AX.setMinimized(w.element, false) }
        AX.setFrame(w.element, r.integral)
        tracker.scanSoon()
    }

    /// Move a window to the next display, keeping its relative size and position.
    static func toNextScreen(_ w: TrackedWindow) {
        let screens = NSScreen.screens.sorted { ($0.axFrame.minX, $0.axFrame.minY) < ($1.axFrame.minX, $1.axFrame.minY) }
        guard screens.count > 1, let from = Tracker.screen(for: w.frame), let i = screens.firstIndex(of: from) else { return }
        let to = screens[(i + 1) % screens.count]
        let a = area(from), b = area(to)
        let f = w.frame
        let rx = (f.minX - a.minX) / a.width, ry = (f.minY - a.minY) / a.height
        let rw = min(f.width / a.width, 1), rh = min(f.height / a.height, 1)
        var r = CGRect(x: b.minX + rx * b.width, y: b.minY + ry * b.height, width: rw * b.width, height: rh * b.height)
        r.origin.x = min(max(r.minX, b.minX), b.maxX - r.width)
        r.origin.y = min(max(r.minY, b.minY), b.maxY - r.height)
        AX.setFrame(w.element, r.integral)
        focus(w)
    }

    /// Lay out every open window on a display in an equal grid that uses all the space.
    static func tile(_ screen: NSScreen) {
        let key = Tracker.key(screen)
        let wins = tracker.orderedApps.filter { !$0.hidden }
            .flatMap { $0.windows(on: key) }.filter { !$0.minimized }
            .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        guard !wins.isEmpty else { return }
        let a = area(screen)
        let n = wins.count
        let cols = n <= 3 ? n : Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cellH = (a.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var i = 0
        for row in 0..<rows {
            let inRow = row == rows - 1 ? n - cols * (rows - 1) : cols      // last row stretches to fill
            let cellW = (a.width - gap * CGFloat(inRow - 1)) / CGFloat(inRow)
            for col in 0..<inRow {
                let r = CGRect(x: a.minX + CGFloat(col) * (cellW + gap), y: a.minY + CGFloat(row) * (cellH + gap),
                               width: cellW, height: cellH)
                AX.setFrame(wins[i].element, r.integral)
                i += 1
            }
        }
        tracker.scanSoon()
    }

    static func toggleMinimize(_ w: TrackedWindow) {
        if w.minimized { focus(w) } else { AX.setMinimized(w.element, true); tracker.scanSoon() }
    }

    static func close(_ w: TrackedWindow) {
        AX.close(w.element)
        tracker.scanSoon()
    }

    // MARK: Front window (hotkeys)

    static func front(_ p: Placement) {
        guard let w = tracker.frontWindow else { NSSound.beep(); return }
        place(w, p)
    }

    static func frontToNextScreen() {
        guard let w = tracker.frontWindow else { NSSound.beep(); return }
        toNextScreen(w)
    }
}
