import AppKit
import ScreenCaptureKit
import SwiftUI

/// Live-ish window previews for the overview. Optional: needs Screen Recording permission.
final class Thumbnails {
    static let shared = Thumbnails()
    private(set) var images: [CGWindowID: NSImage] = [:]
    private(set) var cgImages: [CGWindowID: CGImage] = [:]
    private var busy = false

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() { CGRequestScreenCaptureAccess() }

    func refresh(ids: Set<CGWindowID>, onUpdate: @escaping () -> Void) {
        guard hasPermission, !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            for w in content.windows where ids.contains(w.windowID) {
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                let scale = min(1, 900 / max(w.frame.width, 1))
                cfg.width = max(2, Int(w.frame.width * scale))
                cfg.height = max(2, Int(w.frame.height * scale))
                cfg.showsCursor = false
                guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { continue }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                let id = w.windowID
                await MainActor.run {
                    self.images[id] = img
                    self.cgImages[id] = cg
                    onUpdate()
                }
            }
            await MainActor.run { self.busy = false }
        }
    }

    /// Keep previews of on-screen windows fresh so transitions look like the real thing.
    func refreshVisible() {
        guard hasPermission, !busy else { return }
        let ids = Set(WindowManager.shared.windows.filter { !$0.parked }.map(\.id))
        guard !ids.isEmpty else { return }
        busy = true
        refresh(ids: ids) {}
    }
}

/// Small transient message in the middle of the screen.
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        let host = NSHostingView(rootView:
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .modifier(GlassCapsule())
                .padding(10)
        )
        let size = host.fittingSize
        let s = NSScreen.underMouse.visibleFrame
        let p = NSPanel(contentRect: NSRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2 - 120,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
