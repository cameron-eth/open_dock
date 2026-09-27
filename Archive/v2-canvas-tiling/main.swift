import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var started = false

    func applicationDidFinishLaunching(_ n: Notification) {
        setupStatusItem()
        setupSignals()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            start()
        } else {
            Toast.show("Fractal needs Accessibility access to move windows")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.start() }
            }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        Workspace.shared.start()
        WindowManager.shared.start()
        Hotkeys.shared.setup()
        EventTap.shared.start()
        DockController.shared.rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            Workspace.shared.screensChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            Workspace.shared.spaceChanged()
        }
        Toast.show("Fractal is on · drag a window to dock it")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bringEverythingBack()
        return .terminateNow
    }

    private func bringEverythingBack() {
        guard started else { return }
        WindowManager.shared.gatherAll(forQuit: true)
        WindowManager.shared.saveNow(keepWindows: false)
    }

    /// Never strand windows off-screen, even if killed from the terminal.
    private func setupSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.bringEverythingBack()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.on.square.dashed", accessibilityDescription: "Fractal")
        let wm = WindowManager.shared
        let menu = NSMenu()
        let ws = Workspace.shared
        menu.addItem(ClosureMenuItem("Overview  ⌃⌥Space") { ws.toggleOverview() })
        menu.addItem(ClosureMenuItem("Desktop  ⌃⌥D") { ws.toggleDesktop() })
        menu.addItem(ClosureMenuItem("Pin Front Window  ⌃⌥P") { wm.togglePinFront() })
        menu.addItem(ClosureMenuItem("Undock Front Window  ⌃⌥U") { ws.undockFront() })
        menu.addItem(.separator())

        let more = NSMenu()
        more.addItem(ClosureMenuItem("Zoom Into Front Window  ⌃⌥F") { ws.toggleFocusFront() })
        more.addItem(ClosureMenuItem("Infinite Desktop Map  ⌃⌥M") { OverviewController.shared.toggle() })
        more.addItem(ClosureMenuItem("Gather Floating Windows  ⌃⌥G") { wm.gatherAll() })
        more.addItem(ClosureMenuItem("Show / Hide Bar  ⌃⌥B") { DockController.shared.toggle() })
        let toggleTargets = ClosureMenuItem("Dock While Dragging") {}
        toggleTargets.state = .on
        toggleTargets.onFire = { [weak toggleTargets] in
            DragDock.shared.enabled.toggle()
            toggleTargets?.state = DragDock.shared.enabled ? .on : .off
        }
        more.addItem(toggleTargets)
        more.addItem(.separator())
        for line in ["⌃⌥ scroll · zoom in/out a level",
                     "⌃⌥[  ⌃⌥] · back / forward",
                     "⌃⌥⇧ arrows · dock front window to an edge",
                     "⌃⌥⇧1–9 · save frame   ⌃⌥1–9 · go to it",
                     "⌃⌥⌘ scroll · pan the infinite desktop"] {
            let i = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            i.isEnabled = false
            more.addItem(i)
        }
        let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(moreItem)

        let tip = NSMenuItem(title: "Drag a window to a screen edge or onto another window to dock it", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Fractal (brings all windows back)", key: "q") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
