import AppKit
import SwiftUI

/// A small alert that slides up just above the dock (new message, missing permission…).
/// Click it to act on it; it goes away by itself after a few seconds unless you're hovering it.
final class Banner {
    static let shared = Banner()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(icon: NSImage?, title: String, body: String, onClick: @escaping () -> Void) {
        hideWork?.cancel()
        let screen = NSScreen.screens.first ?? NSScreen.underMouse
        let view = BannerView(icon: icon, title: title, message: body,
                              onClick: { [weak self] in self?.hide(); onClick() },
                              onClose: { [weak self] in self?.hide() },
                              onHover: { [weak self] h in h ? self?.hideWork?.cancel() : self?.scheduleHide(4) })
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        let vf = screen.visibleFrame
        let frame = NSRect(x: (vf.midX - size.width / 2).rounded(), y: DockController.shared.dockTop(for: screen) + 6,
                           width: size.width, height: size.height)
        let p = panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            return p
        }()
        p.contentView = host
        let start = frame.offsetBy(dx: 0, dy: -12)
        if panel == nil { p.setFrame(start, display: false); p.alphaValue = 0 }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
        scheduleHide(6)
    }

    private func scheduleHide(_ after: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        }) { p.orderOut(nil) }
    }
}

struct BannerView: View {
    let icon: NSImage?
    let title: String
    let message: String
    let onClick: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 360)
        .modifier(Glass(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .onHover(perform: onHover)
        .padding(10)
    }
}
