import AppKit
import SwiftUI

/// Stand-ins drawn where a pane is too small for a real window: app-icon chips for windows,
/// and a mini wallpaper tile for the desktop. They sit just above the desktop, below every real window.
final class Surfaces {
    static let shared = Surfaces()
    private var panels: [UUID: NSPanel] = [:]
    private var bySpace: [String: Set<UUID>] = [:]
    private var wallpapers: [String: NSImage] = [:]

    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    func set(space sp: ScreenSpace, screen: NSScreen, chips: [(Node, CGRect)], tile: (Node, CGRect)?) {
        var keep = Set<UUID>()
        for (n, r) in chips where r.width >= 18 && r.height >= 18 {
            guard let id = n.windowID, let mw = WindowManager.shared.records[id] else { continue }
            keep.insert(n.id)
            show(n.id, r, SurfaceView(kind: .window(mw), nodeID: n.id, displayID: sp.displayID))
        }
        if let (n, r) = tile, r.width >= 24, r.height >= 18 {
            keep.insert(n.id)
            show(n.id, r, SurfaceView(kind: .desktop(wallpaper(for: screen)), nodeID: n.id, displayID: sp.displayID))
        }
        for id in (bySpace[sp.displayID] ?? []).subtracting(keep) {
            panels[id]?.orderOut(nil)
            panels[id] = nil
        }
        bySpace[sp.displayID] = keep
    }

    private func show(_ id: UUID, _ axRect: CGRect, _ view: SurfaceView) {
        let primary = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(x: axRect.minX, y: primary - axRect.maxY, width: axRect.width, height: axRect.height)
        if let panel = panels[id], let host = panel.contentView as? FirstMouseHostingView<SurfaceView> {
            host.rootView = view
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            return
        }
        let panel = makePanel()
        panel.contentView = FirstMouseHostingView(rootView: view)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panels[id] = panel
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = Self.level
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return p
    }

    func clear(displayID: String) {
        for id in bySpace[displayID] ?? [] { panels[id]?.orderOut(nil); panels[id] = nil }
        bySpace[displayID] = []
    }

    func resetWallpapers() { wallpapers.removeAll() }

    func wallpaperImage(for screen: NSScreen) -> NSImage? { wallpaper(for: screen) }

    private func wallpaper(for screen: NSScreen) -> NSImage? {
        let key = Workspace.displayID(screen)
        if let w = wallpapers[key] { return w }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let img = NSImage(contentsOf: url) else { return nil }
        wallpapers[key] = img
        return img
    }
}

struct SurfaceView: View {
    enum Kind {
        case window(ManagedWindow)
        case desktop(NSImage?)
    }
    let kind: Kind
    let nodeID: UUID
    let displayID: String
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                switch kind {
                case .window(let mw):
                    RoundedRectangle(cornerRadius: min(12, side * 0.18))
                        .fill(.ultraThinMaterial)
                    VStack(spacing: 4) {
                        if let icon = mw.icon {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: side * 0.62, height: side * 0.62)
                        }
                        if geo.size.width > 110 && geo.size.height > 80 {
                            Text(mw.displayTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .padding(.horizontal, 6)
                        }
                    }
                case .desktop(let img):
                    if let img {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    } else {
                        LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    if geo.size.width > 70 {
                        Text("Desktop")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.black.opacity(0.4), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: min(12, side * 0.18)))
            .overlay(RoundedRectangle(cornerRadius: min(12, side * 0.18))
                .strokeBorder(.white.opacity(hover ? 0.8 : 0.2), lineWidth: hover ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { Workspace.shared.focus(nodeID: nodeID, displayID: displayID) }
            .help("Click to zoom in")
        }
    }
}
