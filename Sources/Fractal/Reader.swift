import AppKit
import SwiftUI

/// A page opened from search, shown cleanly inside the widget: recipes as ingredients and steps,
/// everything else as its summary and main text.
struct ReaderView: View {
    let result: SearchResult
    let query: String
    @State private var digest: PageDigest?
    @State private var loaded = false
    @State private var summary: String?
    @State private var summarizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { SearchEngine.shared.reading = nil } label: {
                    Label("Results", systemImage: "chevron.left").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Open in Chrome ↗") {
                    ChromeTabs.shared.openURL((digest?.url ?? result.url).absoluteString)
                    HoverPreview.shared.hide(now: true, force: true)
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !loaded {
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07))
                                .frame(width: i == 0 ? 260 : nil, height: i == 0 ? 14 : 9)
                        }
                    } else if let d = digest {
                        if let r = d.recipe { RecipeBody(digest: d, recipe: r) } else { ArticleBody(digest: d, summary: summary, summarizing: summarizing, summarize: summarize) }
                    } else {
                        Text("This page couldn't be opened here.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
        }
        .task(id: result.id) {
            loaded = false
            digest = await PageReader.shared.digest(result.url)
            loaded = true
        }
    }

    private func summarize() {
        guard let d = digest else { return }
        summarizing = true
        Task {
            summary = await Assistant.shared.linkPeek(query: query, page: d)
            summarizing = false
        }
    }
}

private struct RecipeBody: View {
    let digest: PageDigest
    let recipe: PageDigest.Recipe

    var body: some View {
        if let img = digest.image {
            AsyncImage(url: img) { i in i.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.primary.opacity(0.06) }
                .frame(height: 130).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        Text(recipe.name.isEmpty ? digest.title : recipe.name).font(.system(size: 14, weight: .semibold))
        Text(digest.site).font(.system(size: 10.5)).foregroundStyle(.secondary)
        RecipeChips(recipe: recipe)
        if !recipe.ingredients.isEmpty {
            Text("Ingredients").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, i in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(Color.accentColor).frame(width: 4, height: 4).padding(.top, 6)
                        Text(i).font(.system(size: 11.5))
                    }
                }
            }
        }
        if !recipe.steps.isEmpty {
            Text("Steps").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { n, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(n + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 17, height: 17).background(Circle().fill(Color.accentColor))
                        Text(step).font(.system(size: 11.5)).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct RecipeChips: View {
    let recipe: PageDigest.Recipe
    var body: some View {
        HStack(spacing: 6) {
            if let t = recipe.time { chip("clock", t) }
            if let s = recipe.servings, !s.isEmpty { chip("person.2", s) }
            if let r = recipe.rating { chip("star.fill", r) }
            if !recipe.ingredients.isEmpty { chip("list.bullet", "\(recipe.ingredients.count) ingredients") }
        }
    }
    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.primary.opacity(0.08)))
    }
}

private struct ArticleBody: View {
    let digest: PageDigest
    let summary: String?
    let summarizing: Bool
    let summarize: () -> Void

    var body: some View {
        Text(digest.title).font(.system(size: 14, weight: .semibold))
        Text(digest.site).font(.system(size: 10.5)).foregroundStyle(.secondary)
        if let summary {
            HStack(alignment: .top, spacing: 6) {
                Pinwheel(size: 12, spinning: false)
                Text(summary).font(.system(size: 11.5))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        } else {
            Button(summarizing ? "Summarizing…" : "Summarize for my search") { summarize() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                .disabled(summarizing)
        }
        if !digest.description.isEmpty {
            Text(digest.description).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        ForEach(Array(digest.text.prefix(40).enumerated()), id: \.offset) { _, t in
            if t.hasPrefix("## ") {
                Text(String(t.dropFirst(3))).font(.system(size: 12.5, weight: .semibold)).padding(.top, 4)
            } else {
                Text(t).font(.system(size: 11.5)).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Hover summary card

/// A tooltip-style card beside the widget: what's useful about a result for your search.
/// Click-through, so it never takes focus or gets in the way.
final class PeekPanel {
    static let shared = PeekPanel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var showingID: UUID?

    func show(_ r: SearchResult, query: String, rowInWindow: CGRect) {
        hideWork?.cancel()
        guard let host = HoverPreview.shared.frame else { return }
        showingID = r.id
        let view = FirstMouseHostingView(rootView: LinkPeek(result: r, query: query))
        view.layoutSubtreeIfNeeded()
        let size = CGSize(width: 300, height: max(60, view.fittingSize.height))
        // Beside the widget, level with the hovered row; flip to the left if there's no room.
        let screen = NSScreen.screens.first { $0.frame.intersects(host) } ?? NSScreen.underMouse
        let rowMidY = host.maxY - rowInWindow.midY
        var x = host.maxX + 6
        if x + size.width > screen.visibleFrame.maxX - 6 { x = host.minX - 6 - size.width }
        let y = min(max(rowMidY - size.height / 2, screen.visibleFrame.minY + 6), screen.visibleFrame.maxY - size.height - 6)
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        let p = panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            return p
        }()
        p.contentView = view
        let appearing = panel == nil || !p.isVisible
        if appearing { p.setFrame(frame.offsetBy(dx: x > host.maxX ? -6 : 6, dy: 0), display: false); p.alphaValue = 0 }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
    }

    /// The card reports its real rendered height; the panel matches it exactly (centered on the row,
    /// kept on screen), so nothing is ever cropped.
    func setHeight(_ h: CGFloat) {
        guard let p = panel, abs(h - p.frame.height) > 0.5 else { return }
        let screen = p.screen ?? NSScreen.underMouse
        var y = p.frame.midY - h / 2
        y = min(max(y, screen.visibleFrame.minY + 6), screen.visibleFrame.maxY - h - 6)
        p.setFrame(NSRect(x: p.frame.minX, y: y, width: p.frame.width, height: h), display: true)
    }

    func hide(soon: Bool = false) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            self?.panel = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (soon ? 0.15 : 0), execute: w)
    }
}

struct LinkPeek: View {
    let result: SearchResult
    let query: String
    @State private var digest: PageDigest?
    @State private var loaded = false
    @State private var points: String?

    init(result: SearchResult, query: String) {
        self.result = result
        self.query = query
        // Already read this page? Open with its content in place, so the first measurement is the real one.
        let cached = MainActor.assumeIsolated { PageReader.shared.cached(result.url) }
        _digest = State(initialValue: cached)
        _loaded = State(initialValue: cached != nil)
        _points = State(initialValue: MainActor.assumeIsolated { LinkPeek.points[result.url] })
    }

    /// On-device summaries already written, so revisiting a result is instant.
    @MainActor static var points: [URL: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(result.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            if !loaded {
                ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08)).frame(height: 8) }
            } else if let r = digest?.recipe {
                RecipeChips(recipe: r)
                if !r.ingredients.isEmpty {
                    Text("Key ingredients").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(r.ingredients.prefix(8).enumerated()), id: \.offset) { _, i in
                            Text("• " + i).font(.system(size: 11)).lineLimit(1)
                        }
                        if r.ingredients.count > 8 {
                            Text("+ \(r.ingredients.count - 8) more — click to see the full recipe")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let points {
                HStack(alignment: .top, spacing: 6) {
                    Pinwheel(size: 11, spinning: false).padding(.top, 1)
                    Text(points).font(.system(size: 11))
                }
            } else if let d = digest, !d.description.isEmpty {
                Text(d.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(5)
            } else if loaded && digest == nil {
                Text("Couldn't preview this page.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .modifier(Glass(cornerRadius: 14))
        .padding(10)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in PeekPanel.shared.setHeight(h) }
        .task(id: result.id) {
            if digest == nil { digest = await PageReader.shared.digest(result.url) }
            loaded = true
            if let d = digest, d.recipe == nil, points == nil {
                let p = await Assistant.shared.linkPeek(query: query, page: d)
                LinkPeek.points[result.url] = p
                points = p
            }
        }
    }
}
