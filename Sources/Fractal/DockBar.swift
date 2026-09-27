import AppKit
import Combine
import SwiftUI

/// Frosted background for Mono Dock's floating surfaces.
///
/// Uses the classic behind-window blur rather than SwiftUI's Liquid Glass: in a transparent window,
/// Liquid Glass also samples the window's own content, so it shows blurred "ghost" copies of the
/// icons along its edges. The behind-window blur only ever sees what's behind the window.
struct Glass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Frost(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }
}

struct Frost: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = Self.mask(cornerRadius)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded-rect mask (behind-window blur can't be clipped by SwiftUI shapes).
    static func mask(_ r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Mono Dock positions and sizes every panel itself (anchored above the dock). Left on, SwiftUI would
    /// resize the window to fit its content keeping the *top* edge fixed — so growing content pushes the
    /// panel down past the dock and off the bottom of the screen.
    required init(rootView: V) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]      // report size, but never resize the window
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Controller: one dock per display

final class DockController {
    static let shared = DockController()
    /// Height kept clear at the bottom of each display, so tiled windows never sit under the dock.
    static let reserve: CGFloat = 60

    private var panels: [(NSPanel, NSScreen)] = []
    private var cancellable: AnyCancellable?
    private(set) var visible = true
    private var rebuildWork: DispatchWorkItem?

    func toggle() {
        visible.toggle()
        rebuild()
    }

    /// Displays changed (plugged in, rearranged, rescaled). Wait for the burst of notifications to end.
    func screensChanged() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func rebuild() {
        panels.forEach { $0.0.orderOut(nil) }
        panels = []
        HoverPreview.shared.hide(now: true)
        guard visible else { return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: Self.reserve),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = FirstMouseHostingView(rootView: DockView(screen: screen))
            panels.append((panel, screen))
            layout(panel, screen)
            panel.orderFrontRegardless()
        }
        cancellable = Tracker.shared.$revision.sink { [weak self] _ in
            DispatchQueue.main.async { self?.relayout() }
        }
    }

    private func relayout() {
        for (p, s) in panels { layout(p, s) }
    }

    private func layout(_ panel: NSPanel, _ screen: NSScreen) {
        guard let v = panel.contentView else { return }
        let size = v.fittingSize
        let vf = screen.visibleFrame
        let w = min(size.width, vf.width - 16)
        // A few points off the bottom edge, clear of where the system reveals hidden docks.
        let frame = NSRect(x: (vf.midX - w / 2).rounded(), y: vf.minY + 4, width: w, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Top edge of the dock on a display, in AppKit coordinates (for placing the hover preview).
    func dockTop(for screen: NSScreen) -> CGFloat {
        panels.first { $0.1 == screen }?.0.frame.maxY ?? screen.visibleFrame.minY + Self.reserve
    }
}

// MARK: - Dock

struct DockView: View {
    @ObservedObject var tracker = Tracker.shared
    let screen: NSScreen

    var body: some View {
        let _ = tracker.revision
        let apps = tracker.apps(for: screen)
        HStack(spacing: 4) {
            ForEach(apps) { app in AppItem(app: app, screen: screen) }
            if apps.isEmpty {
                Text("No windows on this display")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            Divider().frame(height: 30).padding(.horizontal, 2)
            TileButton(screen: screen)
            MonoButton()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .modifier(Glass(cornerRadius: 18))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .fixedSize()
    }
}

struct AppItem: View {
    let app: AppGroup
    let screen: NSScreen
    @ObservedObject private var tracker = Tracker.shared
    @State private var hover = false

    var body: some View {
        let key = Tracker.key(screen)
        let here = app.windows(on: key)
        let isFront = app.pid == tracker.frontPID
        let open = here.filter { !$0.minimized }.count

        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .opacity(app.hidden || (open == 0 && !here.isEmpty) ? 0.45 : 1)
                    .scaleEffect(hover ? 1.08 : 1)
                    .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hover)
                if let badge = app.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(.red))
                        .offset(x: 5, y: -4)
                }
            }
            .overlay(alignment: .topLeading) { ActivityMarks(app: app) }

            // One dot per window on this display (hollow = minimized).
            HStack(spacing: 3) {
                ForEach(Array(here.prefix(4).enumerated()), id: \.offset) { _, w in
                    Circle()
                        .strokeBorder(.primary.opacity(0.8), lineWidth: w.minimized ? 1 : 0)
                        .background(Circle().fill(w.minimized ? .clear : .primary.opacity(isFront ? 0.95 : 0.55)))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 5).padding(.top, 5).padding(.bottom, 3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.primary.opacity(isFront ? 0.14 : (hover ? 0.07 : 0))))
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            if h { HoverPreview.shared.show(app, on: screen) } else { HoverPreview.shared.hide() }
        }
        .gesture(tap)
        .contextMenu { AppMenu(app: app, screen: screen) }
        .help(app.name)
    }
}

extension AppItem {
    /// Apps Mono Dock can steer open their widget on click (double-click opens the real app).
    /// Everything else just comes to the front.
    var tap: AnyGesture<Void> {
        if Steerable.check(app) {
            return AnyGesture(TapGesture(count: 2).onEnded { HoverPreview.shared.hide(now: true, force: true); Steer.click(app, on: screen) }
                .exclusively(before: TapGesture().onEnded {
                    let monoOpen = MainActor.assumeIsolated { AssistantPanel.shared.isShown }
                    if monoOpen, let src = Sources.source(for: app) {
                        MainActor.assumeIsolated { Assistant.shared.attach(.app(src)) }   // point Mono at it
                    } else {
                        HoverPreview.shared.pin(app, on: screen)
                    }
                })
                .map { _ in () })
        }
        return AnyGesture(TapGesture().onEnded { Steer.click(app, on: screen) })
    }
}

/// Small corner marks: 🔊 playing audio, orange = working hard, blue = something changed.
struct ActivityMarks: View {
    let app: AppGroup

    var body: some View {
        let source = Sources.source(for: app)
        let running = source?.runningCount ?? 0
        let needsYou = source?.needsYouCount ?? 0
        HStack(spacing: 2) {
            if needsYou > 0 {
                Text("\(needsYou)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(minWidth: 13, minHeight: 13).background(Circle().fill(.orange))
                    .help("\(needsYou) session(s) waiting for you")
            } else if running > 0 {
                Circle().fill(.green).frame(width: 7, height: 7)
                    .help("\(running) session(s) running")
            }
            if app.playingAudio {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 13, height: 13).background(Circle().fill(.black.opacity(0.65)))
            }
            if app.busy {
                Circle().fill(.orange).frame(width: 6, height: 6)
            } else if app.recentActivity {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        }
        .offset(x: -4, y: -4)
    }
}

struct AppMenu: View {
    let app: AppGroup
    let screen: NSScreen

    var body: some View {
        ForEach(app.windows) { w in
            Button(w.title.isEmpty ? app.name : w.title) { Steer.focus(w) }
        }
        if !app.windows.isEmpty { Divider() }
        if let source = Sources.source(for: app), !source.projects.isEmpty {
            ForEach(source.projects) { p in
                Menu(p.name) {
                    ForEach(p.sessions) { s in
                        Button((s.status == .other ? "" : s.status.rawValue + " · ") + s.title) { source.open(s) }
                    }
                    if p.newSession != nil { Divider(); Button("New Session") { source.newSession(in: p) } }
                }
            }
            Divider()
        }
        if let w = app.windows.min(by: { $0.z < $1.z }) {
            Button("Left Half") { Steer.place(w, .left) }
            Button("Right Half") { Steer.place(w, .right) }
            Button("Maximize") { Steer.place(w, .maximize) }
            if NSScreen.screens.count > 1 { Button("Move to Next Display") { Steer.toNextScreen(w) } }
            Divider()
        }
        Button(app.hidden ? "Show" : "Hide") { app.hidden ? app.app.unhide() : app.app.hide(); Tracker.shared.scanSoon() }
        Button("Quit \(app.name)") { app.app.terminate(); Tracker.shared.scanSoon() }
    }
}

struct TileButton: View {
    let screen: NSScreen
    @State private var hover = false

    var body: some View {
        Button { Steer.tile(screen) } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Tile every window on this display into an even grid  (⌃⌥T)")
    }
}

struct MonoButton: View {
    @State private var hover = false

    var body: some View {
        Button { AssistantPanel.shared.toggle() } label: {
            Pinwheel(size: 20, spinning: false)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Mono — ask, or see what needs you  (⌃⌥Space)")
    }
}

/// Mono's mark: a four-blade pinwheel. It spins only while Mono is thinking.
struct Pinwheel: View {
    let size: CGFloat
    let spinning: Bool
    @State private var angle = 0.0
    private static let colors: [Color] = [
        Color(red: 1.0, green: 0.42, blue: 0.62), Color(red: 1.0, green: 0.72, blue: 0.3),
        Color(red: 0.38, green: 0.78, blue: 1.0), Color(red: 0.62, green: 0.5, blue: 1.0),
    ]

    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = min(sz.width, sz.height) / 2
            for i in 0..<4 {
                var blade = Path()
                blade.move(to: .zero)
                blade.addLine(to: CGPoint(x: 0, y: -r))
                blade.addQuadCurve(to: CGPoint(x: r * 0.92, y: -r * 0.2), control: CGPoint(x: r * 0.95, y: -r * 0.95))
                blade.closeSubpath()
                let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(i) * .pi / 2)
                ctx.fill(blade.applying(t), with: .color(Self.colors[i]))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.12, y: c.y - r * 0.12, width: r * 0.24, height: r * 0.24)), with: .color(.white))
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .onAppear { if spinning { spin() } }
        .onChange(of: spinning) { _, on in on ? spin() : withAnimation(.easeOut(duration: 0.4)) { angle = 0 } }
    }

    private func spin() {
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { angle = 360 }
    }
}
