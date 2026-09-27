import AppKit
import Combine
import SwiftUI

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
    }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One floating bar per display.
final class DockController {
    static let shared = DockController()
    /// Space kept free at the bottom of each screen so tiled windows don't sit under the bar.
    static let reserve: CGFloat = 38

    private var panels: [(NSPanel, NSScreen)] = []
    private var cancellable: AnyCancellable?
    private var lastSignature = ""
    private(set) var visible = true

    func toggle() {
        visible.toggle()
        rebuild()
        Workspace.shared.applyAll()
    }

    func rebuild() {
        panels.forEach { $0.0.orderOut(nil) }
        panels = []
        lastSignature = ""
        guard visible else { return }
        for screen in NSScreen.screens {
            let host = FirstMouseHostingView(rootView: DockView(screenFrame: screen.axFrame, displayID: Workspace.displayID(screen)))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 70),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = host
            panels.append((panel, screen))
            layout(panel, screen)
            panel.orderFrontRegardless()
        }
        cancellable = WindowManager.shared.$revision.sink { [weak self] _ in
            DispatchQueue.main.async { self?.relayoutIfNeeded() }
        }
    }

    private func relayoutIfNeeded() {
        let ws = Workspace.shared
        let pinned = WindowManager.shared.pinnedWindows.map { "\($0.id):\($0.displayTitle.prefix(18))" }
        let crumbs = ws.spaces.values.map { ws.path($0).map(ws.name).joined(separator: ">") }.sorted()
        let sig = (pinned + crumbs + ws.frames.keys.sorted().map(String.init)).joined(separator: "|")
        guard sig != lastSignature else { return }
        lastSignature = sig
        for (p, s) in panels { layout(p, s) }
    }

    private func layout(_ panel: NSPanel, _ screen: NSScreen) {
        guard let v = panel.contentView else { return }
        let size = v.fittingSize
        let vf = screen.visibleFrame
        let w = min(size.width, vf.width - 20)
        let frame = NSRect(x: (vf.midX - w / 2).rounded(), y: vf.minY, width: w, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// Deliberately small: where you are, and how to go up or down a level. Everything else lives in
/// the menu bar menu and hotkeys, so the screen stays for your windows.
struct DockView: View {
    @ObservedObject var wm = WindowManager.shared
    let screenFrame: CGRect
    let displayID: String
    private var ws: Workspace { Workspace.shared }

    var body: some View {
        let _ = wm.revision
        HStack(spacing: 4) {
            if let sp = ws.spaces[displayID] {
                TreeMap(space: sp).frame(width: 40, height: 22)
                    .help("Your layout. Click a pane to zoom into it.")
                Breadcrumbs(space: sp)
                DockButton(symbol: "minus", help: "Zoom out  (⌃⌥ scroll, ⌃⌥-)") { ws.zoomOut(sp) }
                    .disabled(sp.focus.parent == nil)
                DockButton(symbol: "plus", help: "Zoom in  (⌃⌥ scroll, ⌃⌥=)") { ws.zoomIn(sp) }
                    .disabled(sp.focus.axis == nil)
            }
            if !wm.pinnedWindows.isEmpty {
                Divider().frame(height: 16)
                ForEach(wm.pinnedWindows) { w in PinnedTab(window: w) }
            }
            if !ws.frames.isEmpty {
                Divider().frame(height: 16)
                ForEach(ws.frames.keys.sorted(), id: \.self) { n in
                    Button { ws.jumpFrame(n) } label: {
                        Text("\(n)").font(.system(size: 10, weight: .bold, design: .rounded))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Saved frame \(n)  (⌃⌥\(n))")
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .modifier(GlassCapsule())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .fixedSize()
    }
}

struct Breadcrumbs: View {
    let space: ScreenSpace
    private var ws: Workspace { Workspace.shared }

    var body: some View {
        let path = ws.path(space)
        let shown = path.suffix(2)
        HStack(spacing: 2) {
            if path.count > shown.count {
                Text("…").foregroundStyle(.secondary).font(.system(size: 11))
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                if i > 0 || path.count > shown.count {
                    Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                let current = n === space.focus
                Button { ws.setFocus(space, n) } label: {
                    Text(ws.name(n))
                        .font(.system(size: 11, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(current ? 0.1 : 0)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 300)
    }
}

struct DockButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.primary.opacity(hover && enabled ? 0.14 : 0)))
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// A pinned window, shown as just its icon. Click to focus; right-click to unpin.
struct PinnedTab: View {
    let window: ManagedWindow
    @State private var hover = false

    var body: some View {
        Group {
            if let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "pin.fill").frame(width: 20, height: 20)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(hover ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { WindowManager.shared.focus(window) }
        .contextMenu { Button("Unpin \(window.appName)") { WindowManager.shared.togglePin(window) } }
        .help("\(window.displayTitle) (pinned). Click to focus, right-click to unpin.")
    }
}

/// Miniature of this screen's whole docking tree, with the current zoom level outlined.
struct TreeMap: View {
    @ObservedObject var wm = WindowManager.shared
    let space: ScreenSpace
    private var ws: Workspace { Workspace.shared }

    private func computed(_ size: CGSize) -> ([UUID: CGRect], [(Node, CGRect)]) {
        var rects: [UUID: CGRect] = [:]
        var leaves: [(Node, CGRect)] = []
        ws.layout(space.root, CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2), gap: 1.5, rects: &rects, leaves: &leaves)
        return (rects, leaves)
    }

    var body: some View {
        let _ = wm.revision
        GeometryReader { geo in
            let (rects, leaves) = computed(geo.size)
            Canvas { ctx, _ in
                for (n, r) in leaves {
                    let color: Color = n.isDesktop ? .accentColor.opacity(0.35) : .primary.opacity(0.35)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color))
                }
                if let f = rects[space.focus.id], space.focus !== space.root {
                    ctx.stroke(Path(roundedRect: f.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 3),
                               with: .color(.accentColor), lineWidth: 1.5)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                if let (n, _) = leaves.first(where: { $0.1.insetBy(dx: -1, dy: -1).contains(loc) }) {
                    ws.setFocus(space, n === space.focus ? space.root : n)
                }
            }
        }
    }
}
