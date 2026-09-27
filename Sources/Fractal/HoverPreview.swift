import AppKit
import SwiftUI

/// Hovering an app in the dock shows its windows, each with one-click steering.
/// Stays open while the pointer is on the dock icon or the preview itself.
/// A panel that can take keyboard focus for the reply field, without pulling focus from your app otherwise.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Any click inside (used to mark the widget as "in use" so it stops auto-closing).
    var onMouseDown: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?() }
        super.sendEvent(event)
    }
}

final class HoverPreview {
    static let shared = HoverPreview()
    static let focusComposer = Notification.Name("MonoFocusComposer")

    /// Clicking a steerable app's icon opens its widget and keeps it open, ready to type.
    func pin(_ app: AppGroup, on screen: NSScreen) {
        if showing == app.pid, typing { hide(now: true, force: true); return }   // click again to close
        showWork?.cancel()
        hideWork?.cancel()
        present(app, screen: screen, anchorX: NSEvent.mouseLocation.x)
        beginTyping()
        NotificationCenter.default.post(name: Self.focusComposer, object: nil)
    }
    private var panel: NSPanel?
    /// Once you've clicked into the widget (or opened it by clicking the icon) it stays until you dismiss it:
    /// Esc, its ×, clicking the icon again, or clicking elsewhere with nothing typed.
    private(set) var typing = false
    private var resignObserver: Any?
    /// Something is typed in the message box: never throw it away by closing on our own.
    var hasDraft = false

    func beginTyping() {
        hideWork?.cancel()
        panel?.makeKey()
        guard !typing else { return }
        typing = true
        if let panel {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: panel, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Clicked elsewhere: put the widget away — unless there's a half-written message in it.
                if !self.hasDraft { self.hide(now: true, force: true) }
            }
        }
    }

    func endTyping() {
        typing = false
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    }
    private var showing: pid_t?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    func show(_ app: AppGroup, on screen: NSScreen) {
        if typing { return }
        hideWork?.cancel()
        showWork?.cancel()
        let delay = showing == nil ? 0.15 : 0.06       // quick to open; tiny pause when sweeping across icons
        let x = NSEvent.mouseLocation.x
        let work = DispatchWorkItem { [weak self] in self?.present(app, screen: screen, anchorX: x) }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide(now: Bool = false, force: Bool = false) {
        showWork?.cancel()
        hideWork?.cancel()
        if force { endTyping() }
        if typing { return }
        guard !now else { close(); return }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)   // forgiving: room to move into it
    }

    /// The pointer is over the preview itself.
    func keepOpen() { hideWork?.cancel() }

    /// Where the widget is on screen (for placing cards beside it).
    var frame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// Content grew or shrank: resize, keeping the bottom edge anchored above the dock.
    /// Measure after SwiftUI has laid out the change (and once more after late content settles).
    func refitSoon() {
        DispatchQueue.main.async { self.refit() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refit() }
    }

    func refit() {
        guard let p = panel, let v = p.contentView else { return }
        v.layoutSubtreeIfNeeded()
        var size = v.fittingSize
        if let screen = p.screen ?? NSScreen.screens.first {
            size.height = min(size.height, screen.visibleFrame.maxY - p.frame.minY - 8)   // never past the top of the screen
        }
        guard abs(size.height - p.frame.height) > 4 || abs(size.width - p.frame.width) > 4 else { return }
        let frame = NSRect(x: p.frame.minX, y: p.frame.minY, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame, display: true)
        }
    }

    private func close() {
        PeekPanel.shared.hide()
        endTyping()
        hasDraft = false
        showing = nil
        guard let p = panel else { return }
        panel = nil
        // Fade out rather than vanish.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }) {
            if self.panel !== p { p.orderOut(nil); p.alphaValue = 1 }
        }
    }

    /// One container per panel; switching apps changes what it shows (cross-fade) instead of rebuilding it.
    private let model = PreviewModel()

    private var shownScreen: NSScreen?

    private func present(_ app: AppGroup, screen: NSScreen, anchorX: CGFloat) {
        guard !app.windows.isEmpty || Steerable.alwaysHasWidget(app)
                || Sources.source(for: app).map({ !$0.projects.isEmpty }) == true else { close(); return }
        // Already showing this app here: keep it exactly as it is (no rebuild, no reload, no jump).
        if let p = panel, p.isVisible, showing == app.pid, shownScreen == screen {
            p.orderFrontRegardless()
            return
        }
        let reuse = panel != nil && panel!.isVisible && panel!.alphaValue > 0.5
        let p = panel ?? {
            let p = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = FirstMouseHostingView(rootView: PreviewContainer(model: model))
            return p
        }()
        (p as? KeyablePanel)?.onMouseDown = { [weak self] in self?.beginTyping() }
        withAnimation(reuse ? .easeOut(duration: 0.16) : nil) {
            model.app = app
            model.screen = screen
        }
        // Size once SwiftUI has laid out the new content, then glide (or rise in) to the new spot.
        DispatchQueue.main.async {
            guard let v = p.contentView else { return }
            v.layoutSubtreeIfNeeded()
            let size = v.fittingSize
            let vf = screen.visibleFrame
            let x = min(max(anchorX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
            let frame = NSRect(x: x.rounded(), y: DockController.shared.dockTop(for: screen) - 2, width: size.width, height: size.height)
            if reuse {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    p.animator().setFrame(frame, display: true)
                }
            } else {
                p.setFrame(frame.offsetBy(dx: 0, dy: -8), display: false)
                p.alphaValue = 0
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    p.animator().setFrame(frame, display: true)
                    p.animator().alphaValue = 1
                }
            }
        }
        p.orderFrontRegardless()
        panel = p
        showing = app.pid
        shownScreen = screen
    }
}

final class PreviewModel: ObservableObject {
    @Published var app: AppGroup?
    @Published var screen: NSScreen?
}

/// Holds whichever app's widget is showing; switching apps cross-fades.
struct PreviewContainer: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let app = model.app, let screen = model.screen {
                PreviewView(app: app, screen: screen)
                    .id(app.pid)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity))
            }
        }
    }
}

struct PreviewView: View {
    let app: AppGroup
    let screen: NSScreen
    @ObservedObject private var tracker = Tracker.shared
    @ObservedObject private var search = SearchEngine.shared

    /// Chrome with a search showing: results get the room, tabs and windows step aside.
    private var searching: Bool { app.app.bundleIdentifier == ChromeTabs.shared.bundleID && search.active }

    var body: some View {
        let _ = tracker.revision
        let key = Tracker.key(screen)
        let here = app.windows.filter { $0.screenKey == key }
        let elsewhere = app.windows.filter { $0.screenKey != key }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(app.name).font(.system(size: 12, weight: .semibold))
                if let b = app.badge {
                    Text(b).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).background(Capsule().fill(.red))
                }
                if app.playingAudio { Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                if app.busy { Text("busy").font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                Button { HoverPreview.shared.hide(now: true, force: true) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .keyboardShortcut(.cancelAction)
                if Steerable.check(app) {
                    Button("Open \(app.name)") { HoverPreview.shared.hide(now: true, force: true); Steer.click(app, on: screen) }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .help("Open the full app (or double-click its dock icon)")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)

            if !searching {
            ForEach(here) { w in WindowRow(window: w, app: app, note: nil) }
            }
            if !elsewhere.isEmpty && !searching {
                Text("On other displays").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).padding(.top, 4)
                ForEach(elsewhere) { w in WindowRow(window: w, app: app, note: nil) }
            }
            if SpotifyControl.isSpotify(app) {
                NowPlayingCard()
            }
            if app.app.bundleIdentifier == ChromeTabs.shared.bundleID {
                GoogleSearchCard()
            }
            if let source = Sources.source(for: app), !source.projects.isEmpty, !searching {
                SessionList(source: source)
            }
        }
        .padding(8)
        .frame(width: 340, alignment: .leading)
        .modifier(Glass(cornerRadius: 14))
        .padding(10)
        .id(app.pid)
        .onHover { h in h ? HoverPreview.shared.keepOpen() : HoverPreview.shared.hide() }
        .onChange(of: tracker.revision) { _, _ in DispatchQueue.main.async { HoverPreview.shared.refit() } }
    }
}

struct WindowRow: View {
    let window: TrackedWindow
    let app: AppGroup
    let note: String?
    @State private var hover = false
    @ObservedObject private var tracker = Tracker.shared

    var body: some View {
        let focused = window.id == tracker.focusedWindowID && app.pid == tracker.frontPID
        HStack(spacing: 6) {
            Circle().fill(focused ? Color.accentColor : .clear).frame(width: 5, height: 5)
            Text(window.title.isEmpty ? app.name : window.title)
                .font(.system(size: 12))
                .foregroundStyle(window.minimized ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if window.titleChangedAt.map({ Date().timeIntervalSince($0) < 8 }) ?? false {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            if hover {
                RowButton("rectangle.lefthalf.filled", "Left half") { Steer.place(window, .left) }
                RowButton("rectangle.righthalf.filled", "Right half") { Steer.place(window, .right) }
                RowButton("rectangle.fill", "Maximize") { Steer.place(window, .maximize) }
                if NSScreen.screens.count > 1 {
                    RowButton("arrow.right.square", "Move to next display") { Steer.toNextScreen(window) }
                }
                RowButton(window.minimized ? "arrow.up.square" : "minus", window.minimized ? "Restore" : "Minimize") {
                    Steer.toggleMinimize(window)
                }
                RowButton("xmark", "Close window") { Steer.close(window) }
            } else if window.minimized {
                Text("minimized").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(hover ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { Steer.focus(window); HoverPreview.shared.hide(now: true) }
    }
}

struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(hover ? 0.15 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Claude sessions

struct SessionList: View {
    let source: SessionSource
    @ObservedObject private var tracker = Tracker.shared
    @State private var target: String?
    @State private var picked = false            // you clicked a row (Claude may switch to it to read it)
    @State private var focusToken = 0
    @State private var draft = ""

    var body: some View {
        let _ = tracker.revision
        let projects = source.projects
        let chosen = source.all.first { $0.id == target } ?? source.defaultReplyTarget
        Divider().padding(.vertical, 4)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(projects) { p in
                    HStack {
                        Text(p.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if p.newSession != nil {
                            RowButton("plus", "New session in \(p.name)") { source.newSession(in: p) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 5)
                    ForEach(p.sessions) { s in
                        SessionRow(session: s, source: source, isTarget: s.id == chosen?.id) {
                            target = s.id
                            picked = true
                            focusToken += 1
                        }
                    }
                }
            }
        }
        .frame(height: min(260, Self.height(projects)))
        if let chosen, !(source is ChromeTabs) {
            ContextCard(session: chosen, source: source, explicit: picked && chosen.id == target) { suggestion in
                draft = suggestion
                focusToken += 1
            }
            HStack(alignment: .bottom, spacing: 6) {
                Composer(session: chosen, source: source, focusToken: focusToken, draft: $draft)
                Button {
                    MainActor.assumeIsolated {
                        Assistant.shared.attached = [.conversation(chosen, source)]
                        HoverPreview.shared.hide(now: true, force: true)
                        AssistantPanel.shared.show()
                    }
                } label: {
                    Pinwheel(size: 18, spinning: false).frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Ask Mono about this conversation")
            }
        }
    }

    /// Fixed, predictable height (no layout ping-pong between the scroll view and the panel).
    static func height(_ projects: [SessionProject]) -> CGFloat {
        let summaries = MainActor.assumeIsolated { Assistant.shared.summaries }
        return projects.reduce(0) { total, p in
            total + 23 + p.sessions.reduce(0) { $0 + 27 + (summaries[$1.id] != nil ? 28 : 0) }
        }
    }
}

/// The latest messages of the chosen conversation, plus an on-device summary or suggested reply.
struct ContextCard: View {
    let session: AgentSession
    let source: SessionSource
    let explicit: Bool
    let onSuggest: (String) -> Void
    @State private var result: ContextResult?
    @State private var expanded = false
    @State private var summary: String?
    @State private var working = false

    /// Fixed sizes: the card never changes height as content arrives, so nothing around it jumps.
    private static let collapsed: CGFloat = 132
    private static let open: CGFloat = 300

    private var msgs: [ContextMessage] { if case .messages(let m)? = result { return m }; return [] }

    /// Changes whenever what's shown changes, to drive the cross-fade.
    private var stateKey: String {
        switch result {
        case nil: return "loading"
        case .notice(let t, _)?: return "n:" + t
        case .messages(let m)?: return "m:\(m.count):\(m.last?.text.count ?? 0):\(summary ?? "")"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                content
                    .id(stateKey)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: expanded ? Self.open : Self.collapsed, alignment: .top)
            .clipped()
            .animation(.easeOut(duration: 0.18), value: stateKey)

            HStack(spacing: 10) {
                Button(expanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .opacity(msgs.count > 2 ? 1 : 0)
                Spacer()
                if working { Pinwheel(size: 12, spinning: true) }
                Button("Summarize") {
                    let m = msgs
                    run { await Assistant.shared.summarize(m, title: session.title) } then: { s in
                        withAnimation(.easeOut(duration: 0.18)) { summary = s }
                    }
                }
                Button("Suggest reply") {
                    let m = msgs
                    run { await Assistant.shared.suggestReply(m, title: session.title, toAgent: !(source is MessagesChats)) } then: { onSuggest($0) }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .disabled(working || msgs.isEmpty)
            .opacity(msgs.isEmpty ? 0.4 : 1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
        .padding(.top, 6)
        .task(id: session.id) { await load() }
        .onChange(of: explicit) { _, now in
            // You clicked the row: only reload if we couldn't show anything yet.
            if now, case .messages? = result {} else if now { Task { await load() } }
        }
        .onChange(of: expanded) { _, _ in refit() }
    }

    @ViewBuilder private var content: some View {
        switch result {
        case nil:
            // Placeholder lines in the same shape as real messages.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.1)).frame(width: 48, height: 9)
                        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(height: 9)
                        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(width: 220, height: 9)
                    }
                }
            }
        case .notice(let text, let action)?:
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                if let action {
                    Button(action.title) { NSWorkspace.shared.open(action.url) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
            }
        case .messages(let m)?:
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if let summary {
                        HStack(alignment: .top, spacing: 6) {
                            Pinwheel(size: 12, spinning: false)
                            Text(summary).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.1)))
                    }
                    ForEach(m.suffix(expanded ? 6 : 2)) { msg in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(msg.from).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(msg.isMe ? Color.accentColor : Color.secondary)
                            Text(msg.text).font(.system(size: 11)).lineLimit(expanded ? 14 : (summary == nil ? 3 : 2))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .scrollDisabled(!expanded)
            .defaultScrollAnchor(.bottom)
        }
    }

    private func refit() { DispatchQueue.main.async { HoverPreview.shared.refit() } }

    private func load() async {
        summary = nil
        if let cached = ContextCache.shared.get(session.id) {
            result = cached                                // instant, no "Loading…" flash
        } else {
            result = nil
            expanded = false
        }
        let r = await withCheckedContinuation { c in source.context(for: session, explicit: explicit) { c.resume(returning: $0) } }
        // A notice (e.g. "click to load") shouldn't replace messages we already have.
        if case .notice = r, case .messages? = result { return }
        ContextCache.shared.put(session.id, r)
        if !Self.same(r, result) { result = r; refit() }
    }

    private static func same(_ a: ContextResult?, _ b: ContextResult?) -> Bool {
        switch (a, b) {
        case (.messages(let x)?, .messages(let y)?): return x.map(\.text) == y.map(\.text)
        case (.notice(let x, _)?, .notice(let y, _)?): return x == y
        default: return false
        }
    }

    private func run(_ work: @escaping () async -> String, then done: @escaping (String) -> Void) {
        working = true
        Task { let out = await work(); working = false; done(out) }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let source: SessionSource
    let isTarget: Bool
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        let summary = MainActor.assumeIsolated { Assistant.shared.summaries[session.id] }
        HStack(alignment: summary == nil ? .center : .top, spacing: 7) {
            StatusDot(status: session.status)
                .padding(.top, summary == nil ? 0 : 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: isTarget ? .semibold : .regular))
                    .lineLimit(1)
                if let summary {
                    Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isTarget {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 10)).foregroundStyle(Color.accentColor)
            } else if source is ChromeTabs {
                if session.status == .running { Text("current").font(.system(size: 10)).foregroundStyle(.secondary) }
            } else if session.status != .other {
                Text(session.status.rawValue.lowercased())
                    .font(.system(size: 10, weight: session.status.wantsYou ? .semibold : .regular))
                    .foregroundStyle(session.status.wantsYou ? Color.orange : Color.secondary)
            }
        }
        .frame(height: summary == nil ? 17 : 45)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isTarget ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hover ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { source.open(session); HoverPreview.shared.endTyping(); HoverPreview.shared.hide(now: true) }
        .onTapGesture(count: 1) { pick() }
        .help("Click to reply here. Double-click to open it in the app.")
    }
}

/// Always-visible message box: type, press Return, and it goes to the highlighted session.
struct Composer: View {
    let session: AgentSession
    let source: SessionSource
    let focusToken: Int
    @Binding var draft: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(source.placeholder(for: session), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand {
                    if draft.isEmpty { HoverPreview.shared.hide(now: true, force: true) } else { draft = "" }
                }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send  (Return)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.accentColor.opacity(0.8) : .clear))
        .padding(.top, 6)
        .onChange(of: focused) { _, f in if f { HoverPreview.shared.beginTyping() } }
        .onChange(of: draft) { _, d in HoverPreview.shared.hasDraft = !d.trimmingCharacters(in: .whitespaces).isEmpty }
        .onChange(of: focusToken) { _, _ in
            HoverPreview.shared.beginTyping()
            DispatchQueue.main.async { focused = true }
        }
        .onTapGesture { HoverPreview.shared.beginTyping(); focused = true }
        .onReceive(NotificationCenter.default.publisher(for: HoverPreview.focusComposer)) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        focused = false
        HoverPreview.shared.endTyping()
        HoverPreview.shared.hide(now: true)
        source.send(text, to: session)
    }
}

struct StatusDot: View {
    let status: AgentSession.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .running: return .green
        case .waiting, .needsInput, .unread: return .orange
        case .idle, .other: return .secondary.opacity(0.5)
        }
    }
}

/// Recently loaded conversation context, so reopening the widget is instant.
final class ContextCache {
    static let shared = ContextCache()
    private var items: [String: ContextResult] = [:]
    func get(_ id: String) -> ContextResult? { items[id] }
    func put(_ id: String, _ r: ContextResult) {
        if case .messages = r { items[id] = r }
    }
}

/// Apps whose dock icon opens a steering widget instead of the app itself.
enum Steerable {
    static func check(_ app: AppGroup) -> Bool { Sources.source(for: app) != nil || SpotifyControl.isSpotify(app) }
    static func alwaysHasWidget(_ app: AppGroup) -> Bool {
        SpotifyControl.isSpotify(app) || app.app.bundleIdentifier == ChromeTabs.shared.bundleID
    }
}
