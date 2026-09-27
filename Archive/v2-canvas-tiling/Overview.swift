import AppKit
import Combine

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class OverviewController {
    static let shared = OverviewController()
    private var panel: KeyPanel?
    var isShown: Bool { panel != nil }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard panel == nil else { return }
        let wm = WindowManager.shared
        wm.refresh()
        let screen = NSScreen.underMouse
        let p = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.setFrame(screen.frame, display: false)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        let view = OverviewView(frame: blur.bounds, screenAX: screen.axFrame)
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        p.contentView = blur

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(view)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; p.animator().alphaValue = 1 }
        panel = p

        Thumbnails.shared.refresh(ids: Set(wm.windows.map(\.id))) { [weak view] in view?.needsDisplay = true }
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }
}

/// Zoomable, pannable map of the entire canvas. Grid lines nest at every 4× scale — zoom forever.
final class OverviewView: NSView {
    private let wm = WindowManager.shared
    private let screenAX: CGRect
    private var center: CGPoint = .zero
    private var scale: CGFloat = 0.2
    private var hovered: CGWindowID?
    private var viewportPreview: CGPoint?
    private var permissionButton: CGRect?
    private var cancellable: AnyCancellable?

    private enum Drag {
        case none
        case camera(CGPoint)
        case window(ManagedWindow, CGPoint)
        case viewport(CGPoint)
        case pinned(ManagedWindow)
    }
    private var drag: Drag = .none
    private var downPoint: CGPoint = .zero
    private var moved = false

    init(frame: NSRect, screenAX: CGRect) {
        self.screenAX = screenAX
        super.init(frame: frame)
        fitAll()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        cancellable = wm.$revision.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Coordinates

    private var viewOffset: CGPoint { viewportPreview ?? wm.offset }
    private var viewports: [CGRect] { (wm.viewportRects.isEmpty ? wm.screenRects : wm.viewportRects).map { $0.offsetBy(dx: viewOffset.x, dy: viewOffset.y) } }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - center.x) * scale + bounds.midX, y: (p.y - center.y) * scale + bounds.midY)
    }
    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }
    private func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.midX) / scale + center.x, y: (p.y - bounds.midY) / scale + center.y)
    }

    private func fitAll() {
        var box = viewports.reduce(CGRect.null) { $0.union($1) }
        for w in wm.canvasWindows { box = box.union(w.canvasFrame) }
        box = box.insetBy(dx: -box.width * 0.1 - 150, dy: -box.height * 0.1 - 150)
        scale = min(bounds.width / box.width, bounds.height / box.height, 0.55)
        center = box.mid
        needsDisplay = true
    }

    private func zoom(by f: CGFloat, at p: CGPoint) {
        let before = toCanvas(p)
        scale = min(max(scale * f, 0.004), 2.5)
        let after = toCanvas(p)
        center = center + (before - after)
        needsDisplay = true
    }

    // MARK: Hit testing

    private func pinnedRect(_ w: ManagedWindow) -> CGRect {
        w.realFrame.offsetBy(dx: viewOffset.x, dy: viewOffset.y)
    }

    private func hit(_ c: CGPoint) -> ManagedWindow? {
        if let p = wm.pinnedWindows.reversed().first(where: { pinnedRect($0).contains(c) }) { return p }
        return wm.canvasWindows.reversed().first { $0.canvasFrame.contains(c) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        drawGrid()
        drawHome()
        drawBookmarks()
        drawViewports()
        for w in wm.canvasWindows { drawWindow(w, rect: toView(w.canvasFrame), pinned: false) }
        for w in wm.pinnedWindows { drawWindow(w, rect: toView(pinnedRect(w)), pinned: true) }
        drawHUD()
    }

    private func drawGrid() {
        let tl = toCanvas(.zero)
        let br = toCanvas(CGPoint(x: bounds.maxX, y: bounds.maxY))
        var s: CGFloat = 25
        while s < 1e8 {
            let px = s * scale
            if px > 7 {
                let fadeIn = min(1, (px - 7) / 60)
                let fadeOut = 1 - min(1, max(0, (px - 500) / 1500))
                let alpha = 0.10 * fadeIn * fadeOut
                if alpha > 0.004 {
                    NSColor.white.withAlphaComponent(alpha).setStroke()
                    let path = NSBezierPath()
                    path.lineWidth = 1
                    var x = (tl.x / s).rounded(.down) * s
                    while x <= br.x { let v = toView(CGPoint(x: x, y: 0)).x.rounded() + 0.5
                        path.move(to: CGPoint(x: v, y: 0)); path.line(to: CGPoint(x: v, y: bounds.maxY)); x += s }
                    var y = (tl.y / s).rounded(.down) * s
                    while y <= br.y { let v = toView(CGPoint(x: 0, y: y)).y.rounded() + 0.5
                        path.move(to: CGPoint(x: 0, y: v)); path.line(to: CGPoint(x: bounds.maxX, y: v)); y += s }
                    path.stroke()
                }
            }
            s *= 4
        }
    }

    private func drawHome() {
        let r = toView(CGRect(origin: .zero, size: screenAX.size))
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.stroke()
        label("⌂ home", at: CGPoint(x: r.minX + 4, y: r.maxY + 4), size: 11, alpha: 0.4)
    }

    private func drawBookmarks() {
        for (n, off) in Workspace.shared.frames.mapValues(\.offset).sorted(by: { $0.key < $1.key }) {
            let r = toView(screenAX.offsetBy(dx: off.x, dy: off.y))
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            path.setLineDash([2, 5], count: 2, phase: 0)
            NSColor.systemYellow.withAlphaComponent(0.5).setStroke()
            path.stroke()
            label("★ \(n)", at: CGPoint(x: r.minX + 4, y: r.minY - 18), size: 12, alpha: 0.75, color: .systemYellow)
        }
    }

    private func drawViewports() {
        for (i, v) in viewports.enumerated() {
            let r = toView(v)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
            label(viewports.count > 1 ? "you are here · display \(i + 1)" : "you are here",
                  at: CGPoint(x: r.minX + 6, y: r.minY - 18), size: 12, alpha: 0.9, color: .controlAccentColor)
        }
    }

    private func drawWindow(_ w: ManagedWindow, rect r: CGRect, pinned: Bool) {
        guard r.intersects(bounds.insetBy(dx: -40, dy: -40)) else { return }
        let radius = min(10, max(2, 12 * scale))
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let alpha: CGFloat = pinned ? 0.55 : 1

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let img = Thumbnails.shared.images[w.id] {
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        } else {
            color(for: w.appName).withAlphaComponent(0.5 * alpha).setFill()
            path.fill()
            if let icon = w.icon {
                let s = min(72, r.width * 0.45, r.height * 0.45)
                if s > 6 {
                    icon.draw(in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s),
                              from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let hot = hovered == w.id
        (hot ? NSColor.white : NSColor.white.withAlphaComponent(0.25)).setStroke()
        path.lineWidth = hot ? 2.5 : 1
        path.stroke()

        if r.width > 70 {
            let title = pinned ? "📌 \(w.displayTitle)" : w.displayTitle
            if let icon = w.icon {
                icon.draw(in: CGRect(x: r.minX, y: r.minY - 19, width: 16, height: 16), from: .zero,
                          operation: .sourceOver, fraction: 0.9, respectFlipped: true, hints: nil)
            }
            label(title, at: CGPoint(x: r.minX + 19, y: r.minY - 18), size: 11, alpha: hot ? 1 : 0.75, maxWidth: r.width - 19)
        }
    }

    private func drawHUD() {
        let pct = Int((scale * 100).rounded())
        label("FRACTAL   \(pct)%   \(wm.canvasWindows.count) windows on canvas · \(wm.pinnedWindows.count) pinned",
              at: CGPoint(x: 24, y: 22), size: 13, alpha: 0.85, weight: .semibold)

        let hint = "scroll pan  ·  pinch / ⌘-scroll zoom  ·  drag windows to rearrange  ·  drag the blue frame to move your view  ·  click a window to go there  ·  double-click empty space to fly there  ·  right-click for pin  ·  0 fit  ·  esc close"
        let attrs = textAttrs(size: 11, alpha: 0.7)
        let size = (hint as NSString).size(withAttributes: attrs)
        let box = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - size.height - 34,
                         width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (hint as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attrs)

        permissionButton = nil
        if !Thumbnails.shared.hasPermission {
            let text = "Enable live window previews →"
            let a = textAttrs(size: 12, alpha: 0.95, weight: .semibold)
            let s = (text as NSString).size(withAttributes: a)
            let r = CGRect(x: bounds.maxX - s.width - 48, y: 16, width: s.width + 24, height: s.height + 12)
            NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            (text as NSString).draw(at: CGPoint(x: r.minX + 12, y: r.minY + 6), withAttributes: a)
            permissionButton = r
        }
    }

    private func textAttrs(size: CGFloat, alpha: CGFloat, color: NSColor = .white, weight: NSFont.Weight = .medium) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color.withAlphaComponent(alpha),
                .paragraphStyle: para]
    }

    private func label(_ s: String, at p: CGPoint, size: CGFloat, alpha: CGFloat, color: NSColor = .white,
                       weight: NSFont.Weight = .medium, maxWidth: CGFloat = 2000) {
        guard maxWidth > 10 else { return }
        (s as NSString).draw(with: CGRect(x: p.x, y: p.y, width: maxWidth, height: size + 6),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: textAttrs(size: size, alpha: alpha, color: color, weight: weight))
    }

    private func color(for key: String) -> NSColor {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return NSColor(hue: CGFloat(h % 360) / 360, saturation: 0.45, brightness: 0.75, alpha: 1)
    }

    // MARK: Events

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { dx *= 10; dy *= 10 }
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            zoom(by: exp(dy * 0.01), at: p)
        } else {
            center = center - CGPoint(x: dx, y: dy) / scale
            needsDisplay = true
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, at: convert(e.locationInWindow, from: nil))
    }

    override func mouseMoved(with e: NSEvent) {
        let id = hit(toCanvas(convert(e.locationInWindow, from: nil)))?.id
        if id != hovered { hovered = id; needsDisplay = true }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        downPoint = p
        moved = false
        if let r = permissionButton, r.contains(p) {
            Thumbnails.shared.requestPermission()
            return
        }
        let c = toCanvas(p)
        if let w = hit(c) {
            drag = w.pinned ? .pinned(w) : .window(w, w.canvasFrame.origin)
        } else if viewports.contains(where: { $0.contains(c) }) {
            drag = .viewport(wm.offset)
        } else {
            drag = .camera(center)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let d = p - downPoint
        if d.length > 3 { moved = true }
        guard moved else { return }
        switch drag {
        case .camera(let c0): center = c0 - d / scale
        case .window(let w, let o0): w.canvasFrame.origin = o0 + d / scale
        case .viewport(let o0): viewportPreview = o0 + d / scale
        case .pinned, .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        defer { drag = .none; needsDisplay = true }
        switch drag {
        case .window(let w, _):
            if moved { wm.canvasFrameChanged(w) } else { goTo(w) }
        case .pinned(let w):
            if !moved { OverviewController.shared.hide(); wm.focus(w) }
        case .viewport:
            if moved, let o = viewportPreview { viewportPreview = nil; wm.fly(to: o) }
            else if e.clickCount >= 2 { OverviewController.shared.hide() }
        case .camera:
            if !moved && e.clickCount >= 2 {
                wm.center(on: toCanvas(p), screen: screenAX)
                OverviewController.shared.hide()
            }
        case .none: break
        }
    }

    private func goTo(_ w: ManagedWindow) {
        OverviewController.shared.hide()
        wm.reveal(w)
        wm.focus(w)
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let w = hit(toCanvas(convert(e.locationInWindow, from: nil))) else { return }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Go to \(w.appName)") { [weak self] in self?.goTo(w) })
        menu.addItem(ClosureMenuItem(w.pinned ? "Unpin from Screen" : "Pin to Screen") { [weak self] in
            WindowManager.shared.togglePin(w); self?.needsDisplay = true
        })
        menu.addItem(ClosureMenuItem("Bring Into View") { [weak self] in
            guard let self else { return }
            WindowManager.shared.bringHere(w, screen: self.screenAX); self.needsDisplay = true
        })
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    override func keyDown(with e: NSEvent) {
        let step = 300 / scale
        switch e.keyCode {
        case 53, 49: OverviewController.shared.hide()          // esc, space
        case 29: fitAll()                                      // 0
        case 4: wm.home()                                      // h
        case 123: center.x -= step; needsDisplay = true
        case 124: center.x += step; needsDisplay = true
        case 125: center.y += step; needsDisplay = true
        case 126: center.y -= step; needsDisplay = true
        case 24: zoom(by: 1.25, at: bounds.mid)                // =
        case 27: zoom(by: 0.8, at: bounds.mid)                 // -
        default: super.keyDown(with: e)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    var onFire: () -> Void
    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.onFire = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { onFire() }
}
