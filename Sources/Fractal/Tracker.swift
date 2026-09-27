import AppKit
import ApplicationServices
import Combine

/// A real window on the current desktop (or minimized).
final class TrackedWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    var title: String
    var frame: CGRect
    var minimized: Bool
    var screenKey = ""
    /// Position in the app's own front-to-back order (0 = frontmost).
    var z = 0
    /// Last time the title changed while the app was in the background — a sign something happened.
    var titleChangedAt: Date?

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, title: String, frame: CGRect, minimized: Bool) {
        self.id = id
        self.pid = pid
        self.element = element
        self.title = title
        self.frame = frame
        self.minimized = minimized
    }
}

/// A running app and its windows, plus activity signals.
final class AppGroup: Identifiable {
    let pid: pid_t
    var id: pid_t { pid }
    let app: NSRunningApplication
    let name: String
    let icon: NSImage
    var hidden = false
    var windows: [TrackedWindow] = []

    // Activity
    var badge: String?
    var playingAudio = false
    var busy = false

    init(_ app: NSRunningApplication) {
        self.app = app
        self.pid = app.processIdentifier
        self.name = app.localizedName ?? "App"
        self.icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    func windows(on screenKey: String) -> [TrackedWindow] { windows.filter { $0.screenKey == screenKey } }

    var recentActivity: Bool {
        windows.contains { w in w.titleChangedAt.map { Date().timeIntervalSince($0) < 8 } ?? false }
    }
}

/// Keeps an up-to-date picture of every app and window. All the slow asking-apps-about-their-windows
/// happens on a background queue; the main thread only merges results.
final class Tracker: ObservableObject {
    static let shared = Tracker()

    @Published private(set) var revision = 0
    private(set) var apps: [pid_t: AppGroup] = [:]
    private(set) var order: [pid_t] = []
    private(set) var frontPID: pid_t = 0
    private(set) var focusedWindowID: CGWindowID?
    private var byID: [CGWindowID: TrackedWindow] = [:]
    private var signature = ""

    private let queue = DispatchQueue(label: "fractal.scan", qos: .userInitiated)
    private var appElements: [pid_t: AXUIElement] = [:]   // only touched on `queue`
    private var scanning = false
    private var rescanQueued = false

    // MARK: Lifecycle

    func start() {
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        scan()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.scan() }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.frontPID = app.processIdentifier
                    self?.bump(force: true)
                }
                self?.scanSoon()
            }
        }
    }

    /// After you do something (focus, move, close), look again quickly so the dock reflects it.
    func scanSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.scan() }
    }

    // MARK: Queries

    var orderedApps: [AppGroup] { order.compactMap { apps[$0] } }

    /// Apps with windows on this display. The primary display also holds running apps with no windows.
    func apps(for screen: NSScreen) -> [AppGroup] {
        let key = Self.key(screen)
        let primary = screen == NSScreen.screens.first
        return orderedApps.filter { !$0.windows(on: key).isEmpty || (primary && $0.windows.isEmpty) }
    }

    func window(_ id: CGWindowID?) -> TrackedWindow? { id.flatMap { byID[$0] } }

    /// The window you're working in right now.
    var frontWindow: TrackedWindow? { window(focusedWindowID) }

    static func key(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
    }

    static func screen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let best = screens.max { a, b in
            let ia = a.axFrame.intersection(frame), ib = b.axFrame.intersection(frame)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
        if let best, best.axFrame.intersects(frame) { return best }
        return screens.min { ($0.axFrame.mid - frame.mid).length < ($1.axFrame.mid - frame.mid).length }
    }

    // MARK: Scanning

    private struct Item {
        let pid: pid_t, wid: CGWindowID, element: AXUIElement, frame: CGRect, title: String, minimized: Bool, z: Int
    }

    func scan() {
        guard AXIsProcessTrusted() else { return }
        guard !scanning else { rescanQueued = true; return }
        scanning = true
        let me = getpid()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        let targets = running.map { ($0.processIdentifier, $0.isHidden) }
        let front = frontPID
        queue.async { [weak self] in
            guard let self else { return }
            let (items, focused) = self.snapshot(targets, front: front)
            DispatchQueue.main.async {
                self.merge(running: running, items: items, focused: focused)
                self.scanning = false
                if self.rescanQueued { self.rescanQueued = false; self.scan() }
            }
        }
    }

    private func element(_ pid: pid_t) -> AXUIElement {
        if let e = appElements[pid] { return e }
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.15)
        appElements[pid] = e
        return e
    }

    private func snapshot(_ targets: [(pid_t, Bool)], front: pid_t) -> ([Item], CGWindowID?) {
        let onScreen: Set<CGWindowID> = {
            guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
            return Set(info.compactMap { ($0[kCGWindowLayer as String] as? Int) == 0 ? $0[kCGWindowNumber as String] as? CGWindowID : nil })
        }()
        var items: [Item] = []
        let live = Set(targets.map(\.0))
        appElements = appElements.filter { live.contains($0.key) }
        for (pid, hidden) in targets {
            guard let wins: [AXUIElement] = AX.attr(element(pid), kAXWindowsAttribute) else { continue }
            for (z, w) in wins.enumerated() {
                guard let wid = AX.windowID(w), AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { continue }
                let minimized = AX.bool(w, kAXMinimizedAttribute)
                // Windows on other desktops (Spaces) aren't ours to show.
                guard minimized || hidden || onScreen.contains(wid), let f = AX.frame(w) else { continue }
                items.append(Item(pid: pid, wid: wid, element: w, frame: f, title: AX.string(w, kAXTitleAttribute) ?? "",
                                  minimized: minimized, z: z))
            }
        }
        var focused: CGWindowID?
        if front != 0, let fw: AXUIElement = AX.attr(element(front), kAXFocusedWindowAttribute) { focused = AX.windowID(fw) }
        return (items, focused)
    }

    private func merge(running: [NSRunningApplication], items: [Item], focused: CGWindowID?) {
        focusedWindowID = focused
        var nextApps: [pid_t: AppGroup] = [:]
        for app in running { nextApps[app.processIdentifier] = apps[app.processIdentifier] ?? AppGroup(app) }

        var nextByID: [CGWindowID: TrackedWindow] = [:]
        var perApp: [pid_t: [TrackedWindow]] = [:]
        for it in items {
            let w: TrackedWindow
            if let old = byID[it.wid] {
                w = old
                if old.title != it.title, !old.title.isEmpty, it.pid != frontPID { w.titleChangedAt = Date() }
                w.title = it.title
                w.frame = it.frame
                w.minimized = it.minimized
            } else {
                w = TrackedWindow(id: it.wid, pid: it.pid, element: it.element, title: it.title, frame: it.frame, minimized: it.minimized)
            }
            w.z = it.z
            if let s = Self.screen(for: w.frame) { w.screenKey = Self.key(s) }
            nextByID[it.wid] = w
            perApp[it.pid, default: []].append(w)
        }
        for (pid, group) in nextApps {
            let fresh = perApp[pid] ?? []
            // Keep a stable order: windows we already knew, then new ones.
            let known = group.windows.compactMap { w in fresh.first { $0 === w } }
            group.windows = known + fresh.filter { w in !known.contains { $0 === w } }
            group.hidden = group.app.isHidden
        }
        byID = nextByID
        apps = nextApps
        // Dock order: keep what's there, add newcomers in launch order.
        order = order.filter { nextApps[$0] != nil }
        let newcomers = running.filter { !order.contains($0.processIdentifier) }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        order += newcomers.map(\.processIdentifier)
        bump()
    }

    /// Only redraw when something visible changed.
    func bump(force: Bool = false) {
        let sig = orderedApps.map { a in
            "\(a.pid)\(a.hidden)\(a.badge ?? "")\(a.playingAudio)\(a.busy)\(a.recentActivity)|"
                + a.windows.map { "\($0.id)\($0.minimized)\($0.screenKey)\($0.title)" }.joined(separator: ",")
        }.joined(separator: ";") + "\(frontPID)\(focusedWindowID ?? 0)"
        guard force || sig != signature else { return }
        signature = sig
        revision &+= 1
    }
}
