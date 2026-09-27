import AppKit

// MARK: - Docking tree

enum Axis: String, Codable { case row, column }

enum Edge: CaseIterable {
    case left, right, top, bottom
    var axis: Axis { self == .left || self == .right ? .row : .column }
    var leading: Bool { self == .left || self == .top }
}

/// A node in a screen's docking hierarchy. Splits nest forever — that's the fractal.
final class Node {
    enum Kind { case split(Axis), window(CGWindowID), desktop }

    let id: UUID
    var kind: Kind
    weak var parent: Node?
    var children: [Node] = []
    var weights: [CGFloat] = []

    init(_ kind: Kind, id: UUID = UUID()) {
        self.kind = kind
        self.id = id
    }

    var windowID: CGWindowID? { if case .window(let w) = kind { return w }; return nil }
    var isDesktop: Bool { if case .desktop = kind { return true }; return false }
    var axis: Axis? { if case .split(let a) = kind { return a }; return nil }
    var leaves: [Node] { axis == nil ? [self] : children.flatMap(\.leaves) }
    var all: [Node] { [self] + children.flatMap(\.all) }

    func find(_ id: UUID) -> Node? { all.first { $0.id == id } }

    /// True if `self` is `n` or one of its ancestors.
    func contains(_ n: Node) -> Bool {
        var c: Node? = n
        while let x = c { if x === self { return true }; c = x.parent }
        return false
    }

    func setChildren(_ kids: [Node], _ w: [CGFloat]) {
        children = kids
        weights = w
        kids.forEach { $0.parent = self }
    }

    func index(of child: Node) -> Int? { children.firstIndex { $0 === child } }
}

struct NodeData: Codable {
    var id: UUID
    var kind: String
    var axis: Axis?
    var window: CGWindowID?
    var weights: [CGFloat]
    var children: [NodeData]

    init(_ n: Node) {
        id = n.id
        weights = n.weights
        children = n.children.map(NodeData.init)
        switch n.kind {
        case .split(let a): kind = "split"; axis = a
        case .window(let w): kind = "window"; window = w
        case .desktop: kind = "desktop"
        }
    }

    func build() -> Node {
        let k: Node.Kind
        switch kind {
        case "split": k = .split(axis ?? .row)
        case "window": k = .window(window ?? 0)
        default: k = .desktop
        }
        let n = Node(k, id: id)
        n.setChildren(children.map { $0.build() }, weights)
        return n
    }
}

/// Each display has its own tree, focus, and history.
final class ScreenSpace {
    let displayID: String
    var root: Node
    var focus: Node
    var remembered: [UUID: UUID] = [:]   // split → child we last zoomed through
    var back: [UUID] = []
    var forward: [UUID] = []
    var rects: [UUID: CGRect] = [:]      // last layout of the focused subtree (AX coords)
    var visibleLeaves: [(Node, CGRect)] = []
    var liveDesktop: CGRect?             // where floating/canvas windows may appear

    init(displayID: String, root: Node, focus: Node? = nil) {
        self.displayID = displayID
        self.root = root
        self.focus = focus ?? root
    }

    var desktop: Node {
        if let d = root.leaves.first(where: \.isDesktop) { return d }
        // Should never happen, but never lose the desktop.
        let d = Node(.desktop)
        let split = Node(.split(.row))
        split.setChildren([root, d], [0.7, 0.3])
        root = split
        return d
    }
}

enum DropTarget {
    case pane(ScreenSpace, Node, Edge)
    case edge(ScreenSpace, Edge)
}

struct SavedFrame: Codable {
    var focus: [String: UUID]
    var offset: CGPoint
}

// MARK: - Workspace

final class Workspace {
    static let shared = Workspace()
    private var wm: WindowManager { WindowManager.shared }

    private(set) var spaces: [String: ScreenSpace] = [:]
    private var dockedIndex: [CGWindowID: (ScreenSpace, Node)] = [:]
    private var lastAssigned: [CGWindowID: CGRect] = [:]
    private var floatingSizes: [CGWindowID: CGSize] = [:]
    private(set) var frames: [Int: SavedFrame] = [:]
    private var appliedOnce = false
    private var presenceSignature = ""
    private var stepAccum: CGFloat = 0
    private var lastStep = Date.distantPast

    let minTile = CGSize(width: 240, height: 150)
    let gap: CGFloat = 6

    // MARK: Screens & Spaces
    //
    // Every macOS desktop (Space) on every display gets its own layout. The key is
    // "<display number>:<space id>". Layouts for desktops you're not on are dormant, never touched.

    static func displayNumber(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
    }

    private static var spaceCache: [String: UInt64] = [:]

    /// Re-read which Space is showing on each display. Call when Spaces or displays change.
    static func refreshSpaceIDs() {
        let cid = CGSMainConnectionID()
        var out: [String: UInt64] = [:]
        for s in NSScreen.screens {
            let num = displayNumber(s)
            var space: UInt64 = 0
            if let n = UInt32(num), let uuid = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue(),
               let str = CFUUIDCreateString(nil, uuid) {
                space = CGSManagedDisplayGetCurrentSpace(cid, str)
            }
            if space == 0 { space = CGSManagedDisplayGetCurrentSpace(cid, "Main" as CFString) }   // "Displays have separate Spaces" off
            out[num] = space
        }
        spaceCache = out
    }

    /// Layout key for what this display is showing right now.
    static func displayID(_ s: NSScreen) -> String {
        let num = displayNumber(s)
        if spaceCache[num] == nil { refreshSpaceIDs() }
        return "\(num):\(spaceCache[num] ?? 0)"
    }

    func screen(for sp: ScreenSpace) -> NSScreen? {
        NSScreen.screens.first { Self.displayID($0) == sp.displayID }
    }

    func space(for screen: NSScreen) -> ScreenSpace {
        let id = Self.displayID(screen)
        if let sp = spaces[id] { return sp }
        let sp = ScreenSpace(displayID: id, root: Node(.desktop))
        spaces[id] = sp
        return sp
    }

    var mouseSpace: ScreenSpace { space(for: NSScreen.underMouse) }

    func space(containing p: CGPoint) -> (NSScreen, ScreenSpace) {
        let s = NSScreen.screens.first { $0.axFrame.contains(p) } ?? NSScreen.underMouse
        return (s, space(for: s))
    }

    /// Regions where free-floating (canvas) windows are allowed to show.
    var liveRects: [CGRect] {
        guard appliedOnce else { return NSScreen.screens.map(\.axFrame) }
        return NSScreen.screens.compactMap { spaces[Self.displayID($0)]?.liveDesktop }
    }

    func tileArea(_ screen: NSScreen) -> CGRect {
        var r = screen.axVisibleFrame
        if DockController.shared.visible { r.size.height -= DockController.reserve }
        return r.insetBy(dx: gap, dy: gap).integral
    }

    func start() {
        load()
        syncScreens()
    }

    /// Make sure every connected display has a space. Spaces for displays that went away are kept
    /// dormant (not destroyed), so unplugging, swapping or re-arranging monitors never loses a layout.
    func syncScreens() {
        for s in NSScreen.screens { _ = space(for: s) }
        reindex()
    }

    /// While macOS is rearranging windows after a display change, don't mistake its moves for yours.
    private(set) var suppressUntil = Date.distantPast
    var isSettling: Bool { Date() < suppressUntil }
    private var screenWork: DispatchWorkItem?

    /// Displays were added, removed, rearranged, rescaled, or changed resolution.
    func screensChanged() {
        suppressUntil = Date().addingTimeInterval(2.5)
        screenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleScreens() }
        screenWork = work
        // The system sends a burst of notifications; act once it calms down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// You switched desktops (Spaces). Show that desktop's layout; leave the others untouched.
    func spaceChanged() {
        suppressUntil = Date().addingTimeInterval(1.0)
        Self.refreshSpaceIDs()
        syncScreens()
        let live = Set(NSScreen.screens.map(Self.displayID))
        for id in spaces.keys where !live.contains(id) { Surfaces.shared.clear(displayID: id) }
        DockController.shared.rebuild()
        wm.refresh()
        applyAll(animated: false)
    }

    private func settleScreens() {
        Self.refreshSpaceIDs()
        suppressUntil = Date().addingTimeInterval(1.5)
        syncScreens()
        lastAssigned.removeAll()
        Surfaces.shared.resetWallpapers()
        let live = Set(NSScreen.screens.map(Self.displayID))
        for id in spaces.keys where !live.contains(id) { Surfaces.shared.clear(displayID: id) }
        DockController.shared.rebuild()
        wm.repark()
        applyAll(animated: false)
        // macOS sometimes keeps nudging windows for a moment; lay out once more after it's done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.lastAssigned.removeAll()
            self?.wm.repark()
            self?.applyAll(animated: false)
        }
    }

    private func reindex() {
        dockedIndex = [:]
        for sp in spaces.values {
            for l in sp.root.leaves { if let w = l.windowID { dockedIndex[w] = (sp, l) } }
        }
    }

    func isDocked(_ id: CGWindowID) -> Bool { dockedIndex[id] != nil }
    func leaf(for id: CGWindowID) -> (ScreenSpace, Node)? { dockedIndex[id] }

    // MARK: Layout

    func hasWindows(_ n: Node) -> Bool {
        n.leaves.contains { $0.windowID != nil && !isEmpty($0) }
    }

    func isEmpty(_ n: Node) -> Bool {
        switch n.kind {
        case .desktop: return false
        case .window(let id):
            guard let mw = wm.records[id] else { return true }
            return !mw.present || mw.pinned
        case .split: return n.children.allSatisfy(isEmpty)
        }
    }

    /// Lays out `n` inside `r`. Empty (minimized/closed) panes collapse away.
    func layout(_ n: Node, _ r: CGRect, gap g: CGFloat, rects: inout [UUID: CGRect], leaves: inout [(Node, CGRect)]) {
        rects[n.id] = r
        guard let axis = n.axis else { leaves.append((n, r)); return }
        // The desktop never takes tile space away from windows: a branch holding only the desktop
        // is dropped whenever a sibling has real windows. Docked windows always fill the screen.
        let nonEmpty = n.children.indices.filter { !isEmpty(n.children[$0]) }
        let withWindows = nonEmpty.filter { hasWindows(n.children[$0]) }
        let kids = withWindows.isEmpty ? nonEmpty : withWindows
        guard !kids.isEmpty else { return }
        let total = kids.reduce(CGFloat(0)) { $0 + max(n.weights[$1], 0.01) }
        let length = axis == .row ? r.width : r.height
        let avail = max(0, length - g * CGFloat(kids.count - 1))
        var cursor = axis == .row ? r.minX : r.minY
        for i in kids {
            let len = avail * max(n.weights[i], 0.01) / total
            let cr = axis == .row
                ? CGRect(x: cursor, y: r.minY, width: len, height: r.height)
                : CGRect(x: r.minX, y: cursor, width: r.width, height: len)
            layout(n.children[i], cr.integral, gap: g, rects: &rects, leaves: &leaves)
            cursor += len + g
        }
    }

    /// A window being dragged by the user: layout never touches it.
    var excludedWindow: CGWindowID?

    struct Plan {
        let space: ScreenSpace
        let screen: NSScreen
        var targets: [(ManagedWindow, CGRect)] = []
        var hides: [ManagedWindow] = []
        var chips: [(Node, CGRect)] = []
        var tile: (Node, CGRect)?
    }

    func applyAll(animated: Bool = true) {
        applySpaces(animated: animated) { [weak self] in self?.finishApply() }
    }

    /// Compute every screen's layout, then commit it — behind a smooth morph when animated.
    private func applySpaces(animated: Bool, then: (() -> Void)? = nil) {
        let plans = spaces.values.compactMap { sp -> Plan? in
            guard let screen = screen(for: sp) else { return nil }
            return plan(sp, screen: screen)
        }
        appliedOnce = true
        let commit = { [weak self] in
            guard let self else { return }
            for p in plans { for mw in p.hides where !mw.parked { self.wm.park(mw) } }
            let targets = plans.flatMap(\.targets)
            self.wm.animateFrames(targets, animated: false) {
                for (mw, _) in targets { self.lastAssigned[mw.id] = mw.realFrame }
            }
            for p in plans { Surfaces.shared.set(space: p.space, screen: p.screen, chips: p.chips, tile: p.tile) }
            then?()
        }
        commit()
    }

    private func finishApply() {
        wm.apply()
        wm.bump()
    }

    private func plan(_ sp: ScreenSpace, screen: NSScreen) -> Plan {
        if !sp.root.contains(sp.focus) { sp.focus = sp.root }
        while isEmpty(sp.focus), let p = sp.focus.parent { sp.focus = p }

        let area = tileArea(screen)
        var rects: [UUID: CGRect] = [:]
        var leaves: [(Node, CGRect)] = []
        layout(sp.focus, area, gap: gap, rects: &rects, leaves: &leaves)
        sp.rects = rects
        sp.visibleLeaves = leaves
        // Floating windows live on the desktop layer underneath the tiles. They're visible whenever
        // you're looking at a level that includes the desktop, and hidden when you zoom into docked windows.
        sp.liveDesktop = sp.focus.contains(sp.desktop) ? screen.axVisibleFrame : nil

        var plan = Plan(space: sp, screen: screen)
        var shown = Set<CGWindowID>()
        for (n, r) in leaves {
            if n.isDesktop {
                continue
            } else if let id = n.windowID, let mw = wm.records[id] {
                if r.width >= minTile.width && r.height >= minTile.height {
                    shown.insert(id)
                    if id != excludedWindow { plan.targets.append((mw, r)) }
                } else {
                    plan.chips.append((n, r))
                }
            }
        }
        for leaf in sp.root.leaves {
            guard let id = leaf.windowID, id != excludedWindow, !shown.contains(id),
                  let mw = wm.records[id], mw.present, !mw.pinned else { continue }
            plan.hides.append(mw)
        }
        return plan
    }

    /// What the layout would be if `mw` were dropped on `t` — used to reflow live while dragging.
    func preview(_ mw: ManagedWindow, _ t: DropTarget) -> (frames: [(ManagedWindow, CGRect)], slot: CGRect)? {
        let sp: ScreenSpace
        switch t { case .pane(let s, _, _), .edge(let s, _): sp = s }
        guard let screen = screen(for: sp) else { return nil }
        let clone = ScreenSpace(displayID: sp.displayID, root: NodeData(sp.root).build())
        clone.focus = clone.root.find(sp.focus.id) ?? clone.root
        if let leaf = clone.root.leaves.first(where: { $0.windowID == mw.id }) { remove(clone, leaf) }
        let node = Node(.window(mw.id))
        switch t {
        case .pane(_, let target, let edge):
            insert(node, clone, relativeTo: clone.root.find(target.id) ?? clone.focus, edge, edgeMode: false)
        case .edge(_, let edge):
            insert(node, clone, relativeTo: clone.focus, edge, edgeMode: true)
        }
        var rects: [UUID: CGRect] = [:]
        var leaves: [(Node, CGRect)] = []
        layout(clone.focus, tileArea(screen), gap: gap, rects: &rects, leaves: &leaves)
        var frames: [(ManagedWindow, CGRect)] = []
        for (n, r) in leaves {
            guard let id = n.windowID, id != mw.id, let w = wm.records[id],
                  r.width >= minTile.width, r.height >= minTile.height else { continue }
            frames.append((w, r))
        }
        guard let slot = rects[node.id] else { return nil }
        return (frames, slot)
    }

    // MARK: Sync with reality

    /// Called after every WindowManager refresh.
    func refreshed(allIDs: Set<CGWindowID>, failedPids: Set<pid_t>) {
        var pruned = false
        for sp in spaces.values where screen(for: sp) != nil {   // other desktops' windows aren't visible to us; leave them be
            for leaf in sp.root.leaves {
                guard let id = leaf.windowID, !allIDs.contains(id) else { continue }
                if let mw = wm.records[id], failedPids.contains(mw.pid) { continue }
                remove(sp, leaf)
                lastAssigned[id] = nil
                pruned = true
            }
        }
        // A docked window that shows up on a desktop other than its own (moved there, or set to
        // "All Desktops") becomes a normal floating window here.
        for (id, (sp, leaf)) in dockedIndex where screen(for: sp) == nil {
            guard let mw = wm.records[id], mw.present else { continue }
            remove(sp, leaf)
            lastAssigned[id] = nil
            wm.adoptFloating(mw)
            pruned = true
        }
        if pruned { reindex() }
        let sig = dockedIndex.keys.sorted().map { "\($0):\(wm.records[$0]?.present ?? false)" }.joined(separator: ",")
        if pruned || sig != presenceSignature || pendingApply {
            presenceSignature = sig
            pendingApply = false
            applyAll(animated: false)   // background changes shouldn't flash a transition
        }
    }

    private var pendingApply = false

    /// A docked window changed on its own: user resized it (adjust split) or something moved it (snap back).
    func observeDocked(_ mw: ManagedWindow, real: CGRect) {
        guard !DragDock.shared.active, !wm.isMoving, !isSettling, !mw.parked, let assigned = lastAssigned[mw.id],
              let (sp, leaf) = dockedIndex[mw.id], screen(for: sp) != nil else { return }
        let dSize = abs(real.width - assigned.width) + abs(real.height - assigned.height)
        let dPos = (real.origin - assigned.origin).length
        if dSize > 10 {
            adjustWeights(sp, leaf, from: assigned, to: real)
            lastAssigned[mw.id] = real
            pendingApply = true
        } else if dPos > 30 {
            pendingApply = true
        }
    }

    private func adjustWeights(_ sp: ScreenSpace, _ leaf: Node, from a: CGRect, to r: CGRect) {
        for axis in [Axis.row, .column] {
            let (a0, a1, r0, r1) = axis == .row ? (a.minX, a.maxX, r.minX, r.maxX) : (a.minY, a.maxY, r.minY, r.maxY)
            if abs(a1 - r1) > 4 { moveBoundary(sp, leaf, axis, trailing: true, to: r1) }
            if abs(a0 - r0) > 4 { moveBoundary(sp, leaf, axis, trailing: false, to: r0) }
        }
    }

    private func moveBoundary(_ sp: ScreenSpace, _ leaf: Node, _ axis: Axis, trailing: Bool, to pos: CGFloat) {
        var c = leaf
        while let s = c.parent {
            if s.axis == axis, let i = s.index(of: c) {
                let j = trailing ? i + 1 : i - 1
                if j >= 0, j < s.children.count, let cr = sp.rects[c.id], let nr = sp.rects[s.children[j].id] {
                    let lo = axis == .row ? min(cr.minX, nr.minX) : min(cr.minY, nr.minY)
                    let hi = axis == .row ? max(cr.maxX, nr.maxX) : max(cr.maxY, nr.maxY)
                    let p = min(max(pos, lo + 120), hi - 120)
                    let cLen = trailing ? p - lo : hi - p
                    let total = s.weights[i] + s.weights[j]
                    let frac = cLen / max(hi - lo, 1)
                    s.weights[i] = total * frac
                    s.weights[j] = total * (1 - frac)
                    save()
                    return
                }
            }
            c = s
        }
    }

    // MARK: Tree edits

    private func replace(_ sp: ScreenSpace, _ old: Node, with new: Node) {
        if let gp = old.parent, let i = gp.index(of: old) {
            gp.children[i] = new
            new.parent = gp
        } else {
            sp.root = new
            new.parent = nil
        }
        if sp.focus === old { sp.focus = new }
    }

    private func remove(_ sp: ScreenSpace, _ leaf: Node) {
        guard let p = leaf.parent, let i = p.index(of: leaf) else { return }
        p.children.remove(at: i)
        p.weights.remove(at: i)
        equalize(p)
        if sp.focus === leaf { sp.focus = p }
        if p.children.count == 1 { replace(sp, p, with: p.children[0]) }
        if p.children.isEmpty, p.parent != nil { remove(sp, p) }
    }

    /// Every pane in a row/column gets an equal share — grids stay symmetrical.
    private func equalize(_ n: Node) {
        n.weights = Array(repeating: 1, count: n.children.count)
    }

    private func insert(_ new: Node, _ sp: ScreenSpace, relativeTo target: Node, _ edge: Edge, edgeMode: Bool) {
        let axis = edge.axis
        if edgeMode, target.axis == axis {
            if edge.leading { target.children.insert(new, at: 0) } else { target.children.append(new) }
            new.parent = target
            equalize(target)
            return
        }
        if !edgeMode, target !== sp.focus, let p = target.parent, p.axis == axis, let i = p.index(of: target) {
            p.children.insert(new, at: edge.leading ? i : i + 1)
            new.parent = p
            equalize(p)
            return
        }
        let split = Node(.split(axis))
        replace(sp, target, with: split)
        split.setChildren(edge.leading ? [new, target] : [target, new], [1, 1])
    }

    func dock(_ mw: ManagedWindow, _ t: DropTarget) {
        if mw.pinned { mw.pinned = false }
        if !isDocked(mw.id) { floatingSizes[mw.id] = mw.realFrame.size }
        if let (sp, leaf) = dockedIndex[mw.id] { remove(sp, leaf) }
        let node = Node(.window(mw.id))
        switch t {
        case .pane(let sp, let target, let edge):
            let tgt = sp.root.contains(target) ? target : sp.focus
            insert(node, sp, relativeTo: tgt, edge, edgeMode: false)
        case .edge(let sp, let edge):
            insert(node, sp, relativeTo: sp.focus, edge, edgeMode: true)
        }
        mw.parked = false
        reindex()
        save()
        applyAll()
    }

    /// Dock the front window against an edge of what you're looking at.
    func dockFront(_ edge: Edge) {
        guard let mw = wm.frontWindow() else { NSSound.beep(); return }
        dock(mw, .edge(mouseSpace, edge))
    }

    func undockFront() {
        guard let mw = wm.frontWindow(), isDocked(mw.id) else { NSSound.beep(); return }
        undock(mw, keepPosition: false)
    }

    /// Take a window out of the tree and back onto the free-floating desktop.
    func undock(_ mw: ManagedWindow, keepPosition: Bool) {
        guard let (sp, leaf) = dockedIndex[mw.id] else { return }
        remove(sp, leaf)
        reindex()
        lastAssigned[mw.id] = nil
        // Make sure there's a desktop to land on.
        var c: Node? = sp.focus
        while let n = c, !n.contains(sp.desktop) { c = n.parent }
        sp.focus = c ?? sp.root
        applySpaces(animated: false)
        if sp.liveDesktop == nil { sp.focus = sp.desktop; applySpaces(animated: false) }

        if let s = floatingSizes.removeValue(forKey: mw.id) { AX.setSize(mw.element, s) }
        let size = AX.size(mw.element) ?? mw.realFrame.size
        let live = sp.liveDesktop ?? NSScreen.underMouse.axVisibleFrame
        var origin = AX.position(mw.element) ?? mw.realFrame.origin
        if !keepPosition || !live.intersects(CGRect(origin: origin, size: size)) {
            origin = CGPoint(x: live.midX - size.width / 2, y: max(live.minY, live.midY - size.height / 2))
        }
        AX.setPosition(mw.element, origin)
        wm.adoptFloating(mw)
        save()
        finishApply()
    }

    /// Pinning takes a window out of the tree silently.
    func detach(_ mw: ManagedWindow) {
        guard let (sp, leaf) = dockedIndex[mw.id] else { return }
        remove(sp, leaf)
        reindex()
        lastAssigned[mw.id] = nil
        if let s = floatingSizes.removeValue(forKey: mw.id) { AX.setSize(mw.element, s) }
        save()
        applyAll()
    }

    // MARK: Navigation

    func setFocus(_ sp: ScreenSpace, _ n: Node, record: Bool = true, apply: Bool = true) {
        guard n !== sp.focus, sp.root.contains(n) else { return }
        if record {
            sp.back.append(sp.focus.id)
            if sp.back.count > 50 { sp.back.removeFirst() }
            sp.forward.removeAll()
        }
        var c = n
        while let p = c.parent { sp.remembered[p.id] = c.id; c = p }
        sp.focus = n
        if apply { save(); applyAll() }
    }

    func focus(nodeID: UUID, displayID: String) {
        guard let sp = spaces[displayID], let n = sp.root.find(nodeID) else { return }
        setFocus(sp, n)
        if let id = n.windowID, let mw = wm.records[id] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.wm.focus(mw) }
        }
    }

    func zoomOut(_ sp: ScreenSpace? = nil) {
        let sp = sp ?? mouseSpace
        guard let p = sp.focus.parent else { Toast.show("Top level"); return }
        setFocus(sp, p)
    }

    func zoomIn(_ sp: ScreenSpace? = nil) {
        let sp = sp ?? mouseSpace
        guard sp.focus.axis != nil else { return }
        let kids = sp.focus.children.enumerated().filter { !isEmpty($0.element) && hasWindows($0.element) }
        guard !kids.isEmpty else { return }
        let child = kids.first { $0.element.id == sp.remembered[sp.focus.id] }?.element
            ?? kids.first { $0.element.contains(sp.desktop) }?.element
            ?? kids[0].element
        setFocus(sp, child)
    }

    /// ⌃⌥ + scroll: one notch = one level.
    func scrollStep(_ dy: CGFloat, continuous: Bool, momentum: Bool) {
        guard !momentum else { return }
        if Date().timeIntervalSince(lastStep) < 0.4 { stepAccum = 0; return }
        stepAccum += continuous ? dy : dy * 40
        guard abs(stepAccum) >= 28 else { return }
        let dir = stepAccum
        stepAccum = 0
        lastStep = Date()
        dir > 0 ? zoomIn() : zoomOut()
    }

    func toggleOverview() {
        let sp = mouseSpace
        if sp.focus !== sp.root { setFocus(sp, sp.root) } else { goBack() }
    }

    func toggleDesktop() {
        let sp = mouseSpace
        if sp.focus !== sp.desktop { setFocus(sp, sp.desktop) } else if sp.root !== sp.desktop { setFocus(sp, sp.root) }
    }

    /// Double-clicking empty desktop: focus it; again: back out to the overview.
    func desktopDoubleClicked(at p: CGPoint) {
        let (_, sp) = space(containing: p)
        guard let live = sp.liveDesktop, live.contains(p) else { return }
        if sp.focus === sp.desktop {
            if sp.root !== sp.desktop { setFocus(sp, sp.root) }
        } else {
            setFocus(sp, sp.desktop)
        }
    }

    func toggleFocusFront() {
        guard let mw = wm.frontWindow(), let (sp, leaf) = dockedIndex[mw.id] else {
            Toast.show("Front window isn't docked — drag it onto a dock target")
            return
        }
        if sp.focus === leaf { goBack(sp) } else { setFocus(sp, leaf) }
    }

    func goBack(_ sp: ScreenSpace? = nil) {
        let sp = sp ?? mouseSpace
        while let id = sp.back.popLast() {
            if let n = sp.root.find(id), n !== sp.focus {
                sp.forward.append(sp.focus.id)
                setFocus(sp, n, record: false)
                return
            }
        }
        if sp.focus !== sp.root { setFocus(sp, sp.root, record: false) }
    }

    func goForward(_ sp: ScreenSpace? = nil) {
        let sp = sp ?? mouseSpace
        while let id = sp.forward.popLast() {
            if let n = sp.root.find(id), n !== sp.focus {
                sp.back.append(sp.focus.id)
                setFocus(sp, n, record: false)
                return
            }
        }
    }

    /// cmd-tab to a docked window that's hidden or tiny: zoom into it.
    func revealDocked(_ mw: ManagedWindow) {
        guard let (sp, leaf) = dockedIndex[mw.id] else { return }
        if let r = sp.visibleLeaves.first(where: { $0.0 === leaf })?.1,
           r.width >= minTile.width, r.height >= minTile.height { return }
        setFocus(sp, leaf)
    }

    /// Floating windows need a live desktop on screen.
    func ensureDesktopLive() {
        let sp = mouseSpace
        if sp.liveDesktop == nil { setFocus(sp, sp.desktop) }
    }

    // MARK: Frames (saved views)

    func saveFrame(_ n: Int) {
        var focus: [String: UUID] = [:]
        for (id, sp) in spaces { focus[id] = sp.focus.id }
        frames[n] = SavedFrame(focus: focus, offset: wm.offset)
        save()
        wm.bump()
        Toast.show("Saved frame \(n)")
    }

    func jumpFrame(_ n: Int) {
        guard let f = frames[n] else { Toast.show("Frame \(n) is empty — ⌃⌥⇧\(n) saves one"); return }
        for (id, nodeID) in f.focus {
            if let sp = spaces[id], let node = sp.root.find(nodeID) { setFocus(sp, node, apply: false) }
        }
        save()
        applyAll()
        wm.fly(to: f.offset)
    }

    // MARK: Quit

    /// Zoom every screen out to its overview so docked windows are all on screen.
    func prepareForQuit() {
        for sp in spaces.values { sp.focus = sp.root }
        applyAll(animated: false)
        save()
    }

    // MARK: Persistence

    private struct SpaceData: Codable { var root: NodeData; var focus: UUID; var remembered: [UUID: UUID] }
    private struct State: Codable {
        var spaces: [String: SpaceData]
        var frames: [String: SavedFrame]
        var floatingSizes: [String: CGSize]
    }

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fractal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspace.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        Self.refreshSpaceIDs()
        for (rawID, d) in s.spaces {
            // Older saves were keyed by display only: attach them to that display's current desktop.
            let id = rawID.contains(":") ? rawID
                : (NSScreen.screens.first { Self.displayNumber($0) == rawID }.map(Self.displayID) ?? rawID)
            let root = d.root.build()
            let sp = ScreenSpace(displayID: id, root: root, focus: root.find(d.focus))
            sp.remembered = d.remembered
            spaces[id] = sp
        }
        frames = Dictionary(uniqueKeysWithValues: s.frames.compactMap { k, v in Int(k).map { ($0, v) } })
        floatingSizes = Dictionary(uniqueKeysWithValues: s.floatingSizes.compactMap { k, v in CGWindowID(k).map { ($0, v) } })
    }

    func save() {
        let s = State(
            spaces: spaces.mapValues { SpaceData(root: NodeData($0.root), focus: $0.focus.id, remembered: $0.remembered) },
            frames: Dictionary(uniqueKeysWithValues: frames.map { (String($0), $1) }),
            floatingSizes: Dictionary(uniqueKeysWithValues: floatingSizes.map { (String($0), $1) })
        )
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url) }
    }

    // MARK: Labels

    func name(_ n: Node) -> String {
        switch n.kind {
        case .desktop: return "Desktop"
        case .window(let id): return wm.records[id]?.appName ?? "Window"
        case .split: return n.parent == nil ? "Overview" : "\(n.leaves.filter { !isEmpty($0) }.count) panes"
        }
    }

    func path(_ sp: ScreenSpace) -> [Node] {
        var out: [Node] = []
        var c: Node? = sp.focus
        while let n = c { out.insert(n, at: 0); c = n.parent }
        return out
    }
}
