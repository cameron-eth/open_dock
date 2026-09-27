import AppKit
import Carbon
import SwiftUI

/// Global hotkeys (Carbon; needs no extra permission). Deliberately few.
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

        let co = UInt32(controlKey | optionKey)
        register(123, co) { Steer.front(.left) }                 // ⌃⌥←
        register(124, co) { Steer.front(.right) }                // ⌃⌥→
        register(126, co) { Steer.front(.maximize) }             // ⌃⌥↑
        register(45, co) { Steer.frontToNextScreen() }           // ⌃⌥N
        register(17, co) { Steer.tile(currentScreen()) }         // ⌃⌥T
        register(11, co) { DockController.shared.toggle() }      // ⌃⌥B
        register(49, co) { MainActor.assumeIsolated { AssistantPanel.shared.toggle() } }      // ⌃⌥Space  Mono
    }

    private func register(_ key: UInt32, _ mods: UInt32, _ fn: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(key, mods, EventHotKeyID(signature: OSType(0x4652_4354), id: id),
                               GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            handlers[id] = fn
            refs.append(ref)
        } else {
            NSLog("Fractal: hotkey \(key) is already used by another app")
        }
    }
}

/// The display you're working on: the front window's, else the one under the pointer.
func currentScreen() -> NSScreen {
    if let w = Tracker.shared.frontWindow, let s = Tracker.screen(for: w.frame) { return s }
    return NSScreen.underMouse
}

final class ClosureMenuItem: NSMenuItem {
    var onFire: () -> Void
    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        onFire = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { onFire() }
}

/// Mono Dock replaces the Apple Dock, so the Apple Dock auto-hides while Mono Dock runs
/// (on by default) and comes back exactly as it was when Mono Dock quits.
enum AppleDock {
    private static let prefs = UserDefaults.standard
    private static var autohides: Bool { UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false }

    /// The user's choice; defaults to hiding.
    static var hideWhileRunning: Bool {
        get { prefs.object(forKey: "hideAppleDock") as? Bool ?? true }
        set { prefs.set(newValue, forKey: "hideAppleDock"); newValue ? hide() : restore() }
    }

    static func applyOnLaunch() { if hideWhileRunning { hide() } }

    /// Hidden, and slow enough to reveal that it never slides up behind Mono Dock when you point at it.
    static func hide() {
        var cmds: [String] = []
        if !autohides {
            prefs.set(true, forKey: "weHidAppleDock")                  // remember to undo it
            cmds.append("defaults write com.apple.dock autohide -bool true")
        }
        if !prefs.bool(forKey: "weDelayedAppleDock") {
            let previous = UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "autohide-delay") as? Double
            prefs.set(previous ?? -1, forKey: "appleDockPreviousDelay")   // -1 = was never set
            prefs.set(true, forKey: "weDelayedAppleDock")
            cmds.append("defaults write com.apple.dock autohide-delay -float 1000")
        }
        run(cmds)
    }

    /// Put the Apple Dock back exactly as it was — only what Mono Dock changed.
    static func restore() {
        var cmds: [String] = []
        if prefs.bool(forKey: "weDelayedAppleDock") {
            prefs.set(false, forKey: "weDelayedAppleDock")
            let previous = prefs.double(forKey: "appleDockPreviousDelay")
            cmds.append(previous < 0 ? "defaults delete com.apple.dock autohide-delay"
                                     : "defaults write com.apple.dock autohide-delay -float \(previous)")
        }
        if prefs.bool(forKey: "weHidAppleDock") {
            prefs.set(false, forKey: "weHidAppleDock")
            cmds.append("defaults write com.apple.dock autohide -bool false")
        }
        run(cmds)
    }

    private static func run(_ cmds: [String]) {
        guard !cmds.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", (cmds + ["killall Dock"]).joined(separator: "; ")]
        try? p.run()
        p.waitUntilExit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var started = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationWillTerminate(_ notification: Notification) { AppleDock.restore() }

    /// Quitting from the terminal (kill) also gives the Apple Dock back.
    private func setupSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { AppleDock.restore(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        setupSignals()
        setupStatusItem()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            start()
        } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.start() }
            }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        AppleDock.applyOnLaunch()
        Tracker.shared.start()
        Activity.shared.start()
        Sources.start()
        SpotifyControl.shared.start()
        MainActor.assumeIsolated {
            Assistant.shared.prewarm()               // load the on-device model once, up front
            Assistant.shared.startAutoSummaries()    // keep "where things stand" fresh for chats waiting on you
        }
        Hotkeys.shared.setup()
        DockController.shared.rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            DockController.shared.screensChanged()
            Tracker.shared.scanSoon()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Mono Dock")
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Ask Mono  ⌃⌥Space") { MainActor.assumeIsolated { AssistantPanel.shared.show() } })
        menu.addItem(ClosureMenuItem("Tile This Display  ⌃⌥T") { Steer.tile(currentScreen()) })
        menu.addItem(ClosureMenuItem("Maximize Front Window  ⌃⌥↑") { Steer.front(.maximize) })
        menu.addItem(ClosureMenuItem("Left Half  ⌃⌥←") { Steer.front(.left) })
        menu.addItem(ClosureMenuItem("Right Half  ⌃⌥→") { Steer.front(.right) })
        menu.addItem(ClosureMenuItem("Move Front Window to Next Display  ⌃⌥N") { Steer.frontToNextScreen() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show / Hide Dock  ⌃⌥B") { DockController.shared.toggle() })
        let hideAppleDock = ClosureMenuItem("Hide the Apple Dock While Mono Dock Runs") {}
        hideAppleDock.state = AppleDock.hideWhileRunning ? .on : .off
        hideAppleDock.onFire = { [weak hideAppleDock] in
            AppleDock.hideWhileRunning.toggle()
            hideAppleDock?.state = AppleDock.hideWhileRunning ? .on : .off
        }
        menu.addItem(hideAppleDock)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Mono Dock", key: "q") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
