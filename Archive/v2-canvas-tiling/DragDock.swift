import AppKit

/// Drag-to-dock, tiling-WM style. While dragging a window:
///  • over a docked pane → it splits toward the nearest side of that pane
///  • near an edge of the screen → it docks across that whole side
/// The other windows in that row/column reflow live to make room (equal shares), and the slot
/// the window will land in lights up. Let go to commit; move away and everything springs back.
/// Dragging freely around the desktop pane does nothing special.
final class DragDock {
    static let shared = DragDock()
    private var wm: WindowManager { WindowManager.shared }
    private var ws: Workspace { Workspace.shared }

    var enabled = true
    private(set) var active = false
    private var downPoint: CGPoint = .zero
    private var candidate: ManagedWindow?
    private var startOrigin: CGPoint = .zero
    private var lastProbe = Date.distantPast

    private var target: DropTarget?
    private var targetKey = ""
    private var previewKey = ""          // what the real windows currently show
    private var reflowWork: DispatchWorkItem?
    private let overlay = DropOverlay()

    /// Pixels from the screen edge that count as "dock across this side".
    private let edgeBand: CGFloat = 48

    // MARK: Mouse events (from the event-tap thread, delivered on main)

    func mouseDown(at p: CGPoint, clickCount: Int) {
        reset(restore: false)
        downPoint = p
        let top = topWindow(at: p)
        if clickCount == 2, top == nil, isEmptyDesktop(at: p) {
            ws.desktopDoubleClicked(at: p)
            return
        }
        guard enabled, let (id, bounds) = top, let mw = wm.records[id], !mw.pinned else { return }
        guard p.y - bounds.minY < 56 else { return }   // title-bar-ish drags only
        candidate = mw
        startOrigin = AX.position(mw.element) ?? bounds.origin
    }

    // Drag events arrive at 120Hz+; collapse them to one main-thread update at a time.
    private let dragLock = NSLock()
    private var pendingDrag: CGPoint?

    func enqueueDrag(_ p: CGPoint) {
        dragLock.lock()
        let schedule = pendingDrag == nil
        pendingDrag = p
        dragLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            self.dragLock.lock()
            let point = self.pendingDrag
            self.pendingDrag = nil
            self.dragLock.unlock()
            if let point { self.mouseDragged(at: point) }
        }
    }

    func mouseDragged(at p: CGPoint) {
        guard let mw = candidate else { return }
        if !active {
            guard (p - downPoint).length > 6, Date().timeIntervalSince(lastProbe) > 0.08 else { return }
            lastProbe = Date()
            guard let pos = AX.position(mw.element), (pos - startOrigin).length > 2 else { return }
            active = true
            ws.excludedWindow = mw.id
        }
        let (screen, sp) = ws.space(containing: p)
        let (t, key) = zone(at: p, screen: screen, space: sp, dragging: mw)
        guard key != targetKey else { return }
        targetKey = key
        target = t
        scheduleReflow(mw)
    }

    func mouseUp(at p: CGPoint) {
        guard active, let mw = candidate else { reset(restore: false); return }
        reflowWork?.cancel()
        overlay.hide()
        let t = target
        let hadPreview = !previewKey.isEmpty
        active = false
        candidate = nil
        ws.excludedWindow = nil
        target = nil
        targetKey = ""
        previewKey = ""
        if let t {
            ws.dock(mw, t)
        } else if ws.isDocked(mw.id), let pos = AX.position(mw.element), (pos - startOrigin).length > 40 {
            ws.undock(mw, keepPosition: true)
        } else if hadPreview {
            ws.applyAll(animated: false)
        }
    }

    private func reset(restore: Bool) {
        reflowWork?.cancel()
        let hadPreview = !previewKey.isEmpty
        active = false
        candidate = nil
        target = nil
        targetKey = ""
        previewKey = ""
        lastProbe = .distantPast
        ws.excludedWindow = nil
        overlay.hide()
        if restore && hadPreview { ws.applyAll(animated: false) }
    }

    // MARK: Zones

    private func zone(at p: CGPoint, screen: NSScreen, space sp: ScreenSpace, dragging mw: ManagedWindow) -> (DropTarget?, String) {
        let area = ws.tileArea(screen)
        // Screen edges: span the whole side of what you're looking at.
        let edges: [(Edge, CGFloat)] = [(.left, p.x - area.minX), (.right, area.maxX - p.x),
                                        (.top, p.y - area.minY), (.bottom, area.maxY - p.y)]
        if let (e, _) = edges.filter({ $0.1 < edgeBand }).min(by: { $0.1 < $1.1 }) {
            return (.edge(sp, e), "edge:\(sp.displayID):\(e)")
        }
        // A docked pane under the cursor: split toward its nearest side.
        guard let (node, r) = sp.visibleLeaves.first(where: { $0.1.contains(p) && $0.0.windowID != mw.id }) else {
            return (nil, "")
        }
        if node.isDesktop { return (nil, "") }
        // Only the outer band of a pane docks; the middle is free movement (floating windows sit over tiles).
        let nx = (p.x - r.minX) / max(r.width, 1)
        let ny = (p.y - r.minY) / max(r.height, 1)
        let sides: [(Edge, CGFloat)] = [(.left, nx), (.right, 1 - nx), (.top, ny), (.bottom, 1 - ny)]
        let (e, d) = sides.min { $0.1 < $1.1 }!
        guard d < 0.25 else { return (nil, "") }
        return (.pane(sp, node, e), "pane:\(node.id):\(e)")
    }

    /// Reflow once the cursor settles on a zone for a moment, so sweeping across panes doesn't thrash apps.
    private func scheduleReflow(_ mw: ManagedWindow) {
        reflowWork?.cancel()
        let key = targetKey
        let t = target
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, key == self.targetKey else { return }
            if let t, let pv = self.ws.preview(mw, t) {
                self.wm.animateFrames(pv.frames, animated: false) {}
                self.previewKey = key
                self.overlay.show(slot: pv.slot)
            } else {
                self.overlay.hide()
                if !self.previewKey.isEmpty {
                    self.previewKey = ""
                    self.ws.applyAll(animated: false)
                }
            }
        }
        reflowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (t == nil ? 0.05 : 0.09), execute: work)
    }

    // MARK: Hit testing the real screen

    /// Frontmost normal window under a point (AX/CG coordinates).
    private func topWindow(at p: CGPoint) -> (CGWindowID, CGRect)? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for d in info {
            guard let layer = d[kCGWindowLayer as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(p) else { continue }
            if (d[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            let owner = d[kCGWindowOwnerPID as String] as? pid_t
            if owner == getpid() || layer < 0 { return nil }   // our own bar/panels, or bare desktop
            if layer > 0 { continue }                          // menu bar, overlays
            return (d[kCGWindowNumber as String] as? CGWindowID ?? 0, rect)
        }
        return nil
    }

    /// True if nothing but bare desktop (not an icon) is under the point.
    private func isEmptyDesktop(at p: CGPoint) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for d in info {
            guard let layer = d[kCGWindowLayer as String] as? Int, layer >= 0,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(p),
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { continue }
            return false
        }
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
              let el else { return true }
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        return !["AXImage", "AXTextField", "AXStaticText", "AXButton"].contains(role)
    }
}

// MARK: - Slot highlight

/// A glowing rounded rect where the dragged window will land. Drawn by Core Animation, click-through.
final class DropOverlay {
    private var panel: NSPanel?
    private var slotLayer: CALayer?
    private var screenID: String?

    func show(slot: CGRect) {
        let screen = NSScreen.screens.first { $0.axFrame.intersects(slot) } ?? NSScreen.underMouse
        let id = Workspace.displayID(screen)
        if panel == nil || screenID != id {
            hide()
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.setFrame(screen.frame, display: false)
            let root = CALayer()
            root.isGeometryFlipped = true
            root.frame = CGRect(origin: .zero, size: screen.frame.size)
            let v = NSView(frame: root.frame)
            v.layer = root
            v.wantsLayer = true
            p.contentView = v

            let l = CALayer()
            l.cornerRadius = 14
            l.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            l.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
            l.borderWidth = 2.5
            l.opacity = 0
            root.addSublayer(l)

            p.orderFrontRegardless()
            panel = p
            slotLayer = l
            screenID = id
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.frame = local(slot, screen).insetBy(dx: 30, dy: 30)
            CATransaction.commit()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1))
        slotLayer?.frame = local(slot, screen)
        slotLayer?.opacity = 1
        CATransaction.commit()
    }

    private func local(_ r: CGRect, _ screen: NSScreen) -> CGRect {
        r.offsetBy(dx: -screen.axFrame.minX, dy: -screen.axFrame.minY)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        slotLayer = nil
        screenID = nil
    }
}
