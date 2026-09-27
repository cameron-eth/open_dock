import AppKit
import SwiftUI
import WebKit

/// Search Google from the Chrome widget and get a clean, native list of results — title, site, snippet.
/// The results page loads out of sight; only its results are shown. Clicking one opens it in Chrome.
struct GoogleSearchCard: View {
    @ObservedObject private var engine = SearchEngine.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search Google or enter a URL…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit(search)
                if engine.active {
                    Button { engine.clear(); query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear search, show tabs again")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06)))
            .onChange(of: focused) { _, f in if f { HoverPreview.shared.beginTyping() } }
            .onAppear { DispatchQueue.main.async { focused = true } }

            if let reading = engine.reading {
                ReaderView(result: reading, query: engine.query)
                    .frame(height: Self.resultsHeight + 30)
                    .transition(.opacity)
            } else if engine.active {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if engine.loading {
                            ForEach(0..<5, id: \.self) { _ in ResultSkeleton() }
                        } else if engine.results.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Couldn't read the results here.").font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("Open results in Chrome ↗") { engine.openInChrome() }
                                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                            }
                            .padding(8)
                        } else {
                            AnswerCard()
                            ForEach(engine.results) { r in ResultRow(result: r) }
                            Button("See all results in Chrome ↗") { engine.openInChrome() }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                }
                .frame(height: Self.resultsHeight)
                .transition(.opacity)
            }
        }
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.18), value: engine.active)
        .animation(.easeOut(duration: 0.18), value: engine.loading)
        .animation(.easeOut(duration: 0.18), value: engine.reading?.id)
        .onChange(of: engine.active) { _, _ in HoverPreview.shared.refitSoon() }
    }

    /// Tall enough for several results, never taller than the screen allows above the dock.
    static var resultsHeight: CGFloat {
        let vf = (NSScreen.screens.first ?? NSScreen.underMouse).visibleFrame
        return max(240, min(420, vf.height - DockController.reserve - 170))
    }

    private func search() {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let url = ChromeTabs.url(for: t)
        if !url.hasPrefix("https://www.google.com/search") {          // an address, not a search: just go there
            ChromeTabs.shared.openURL(url)
            HoverPreview.shared.hide(now: true, force: true)
            return
        }
        HoverPreview.shared.beginTyping()                             // you're using it: keep it open
        engine.search(t)
    }
}

struct SearchResult: Identifiable {
    let id = UUID()
    let title: String
    let url: URL          // may be Google's redirect link; opening it lands on the page
    let site: String      // the site as shown on the results page
    let snippet: String
    var domain: String { site.replacingOccurrences(of: "www.", with: "") }
    var icon: URL? { URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(site)") }
}

struct ResultRow: View {
    let result: SearchResult
    @State private var hover = false
    @State private var peekWork: DispatchWorkItem?
    @State private var rowFrame: CGRect = .zero

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if result.site.isEmpty {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    AsyncImage(url: result.icon) { img in img.resizable() } placeholder: {
                        RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08))
                    }
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(result.site.isEmpty ? "Discussion" : result.domain).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                if !result.snippet.isEmpty {
                    Text(result.snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                Button {
                    PeekPanel.shared.hide()
                    ChromeTabs.shared.openURL(result.url.absoluteString)
                    HoverPreview.shared.hide(now: true, force: true)
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in Chrome")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(hover ? 0.08 : 0)))
        .background(GeometryReader { g in Color.clear.onAppear { rowFrame = g.frame(in: .global) }
            .onChange(of: g.frame(in: .global)) { _, f in rowFrame = f } })
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            peekWork?.cancel()
            if h {
                // Settle on a result for a moment and its summary card appears beside the widget.
                let w = DispatchWorkItem { PeekPanel.shared.show(result, query: SearchEngine.shared.query, rowInWindow: rowFrame) }
                peekWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
            } else {
                PeekPanel.shared.hide(soon: true)
            }
        }
        .onTapGesture {
            PeekPanel.shared.hide()
            SearchEngine.shared.open(result)
        }
        .help("Click to read it here")
    }
}

private struct ResultSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.1)).frame(width: 220, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(width: 90, height: 8)
                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.06)).frame(height: 8)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }
}

/// Loads Google's results page out of sight and pulls out the organic results.
final class SearchEngine: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = SearchEngine()

    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var loading = false
    @Published private(set) var active = false
    @Published var reading: SearchResult?
    @Published private(set) var answer: SearchAnswer?
    @Published private(set) var answering = false
    @Published private(set) var answerSources: [SearchResult] = []
    private(set) var query = ""
    private var currentURL: URL?
    private let web: WKWebView
    private var generation = 0

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // no cookies or history kept by the dock
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        web.navigationDelegate = self
    }

    func search(_ q: String) {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "num", value: "10")]
        guard let u = c.url else { return }
        generation &+= 1
        currentURL = u
        query = q
        reading = nil
        answer = nil
        answering = false
        answerSources = []
        results = []
        loading = true
        active = true
        web.load(URLRequest(url: u))
    }

    func open(_ r: SearchResult) {
        reading = r
        HoverPreview.shared.beginTyping()        // in use: keep the widget open
    }

    func clear() {
        reading = nil
        PeekPanel.shared.hide()
        generation &+= 1
        web.stopLoading()
        results = []
        loading = false
        active = false
        currentURL = nil
        HoverPreview.shared.refitSoon()
    }

    func openInChrome() {
        if let u = currentURL?.absoluteString { ChromeTabs.shared.openURL(u) }
        HoverPreview.shared.hide(now: true, force: true)
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        let gen = generation
        // Give the page a moment to finish rendering its results.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.extract(gen) }
    }

    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish([]) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish([]) }

    /// Every organic result is a link wrapping a heading; take its title, address and nearby snippet text.
    /// Every organic result is a link wrapping a heading. Google now routes result links through an
    /// encrypted redirect (google.com/goto), so the site shown comes from the result's visible address
    /// line ("swift.org › docs"); opening the redirect link still lands on the real page.
    private static let extractJS = """
    const out = [], seen = new Set();
    for (const h of document.querySelectorAll('a h3, a [role="heading"][aria-level="3"]')) {
      const a = h.closest('a[href]'); if (!a) continue;
      let u; try { u = new URL(a.href); } catch (e) { continue; }
      const redirect = u.hostname.endsWith('google.com') && (u.pathname === '/goto' || u.pathname === '/url');
      if (u.hostname.endsWith('google.com') && !redirect) continue;         // Google's own pages
      const title = (h.innerText || '').trim(); if (!title || seen.has(title)) continue;
      seen.add(title);
      const box = a.closest('div[data-hveid], div.g, div.MjjYud') || a.parentElement?.parentElement?.parentElement;
      const cite = (box && box.querySelector('cite')) ? box.querySelector('cite').innerText : '';
      let site = (cite.split(' › ')[0] || '').replace('https://', '').replace('http://', '').trim();
      if (!redirect) site = u.hostname;
      let snippet = '';
      if (box) {
        const lines = (box.innerText || '').split(String.fromCharCode(10)).map(s => s.trim())
          .filter(s => s && s !== title && !s.startsWith('http') && !s.includes(' › ') && s.length > 30);
        snippet = lines.join(' ').slice(0, 240);
      }
      out.push({ title, href: a.href, site, snippet });
      if (out.length >= 10) break;
    }
    return out;
    """

    private func extract(_ gen: Int) {
        guard gen == generation else { return }
        web.callAsyncJavaScript(Self.extractJS, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, gen == self.generation else { return }
            var found: [SearchResult] = []
            if case .success(let value) = result, let rows = value as? [[String: Any]] {
                for r in rows {
                    guard let t = r["title"] as? String, let h = r["href"] as? String, let u = URL(string: h) else { continue }
                    let site = (r["site"] as? String) ?? ""
                    let viaGoogle = u.host?.hasSuffix("google.com") == true
                    found.append(SearchResult(title: t, url: u, site: site.isEmpty && !viaGoogle ? (u.host ?? "") : site,
                                              snippet: (r["snippet"] as? String) ?? ""))
                }
            }
            self.finish(found)
        }
    }

    private func finish(_ found: [SearchResult]) {
        results = found
        loading = false
        if !found.isEmpty, Self.isQuestion(query) { askAI() }       // questions get an answer automatically
    }

    /// "how long to chill cookie dough?" is a question; "chocolate chip cookies" is a plain search.
    static func isQuestion(_ q: String) -> Bool {
        let t = q.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("?") { return true }
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        return ["how", "what", "why", "when", "where", "who", "which", "can", "does", "do", "is", "are",
                "should", "will", "whats", "what's", "hows", "explain"].contains(first)
    }

    /// Read the top results and have the on-device model answer from them.
    func askAI() {
        guard !answering else { return }
        let gen = generation
        let q = query
        let picks = Array(results.filter { !$0.site.isEmpty }.prefix(3))
        guard !picks.isEmpty else { return }
        answering = true
        answer = nil
        answerSources = picks
        Task { @MainActor in
            var pages: [PageDigest] = []
            await withTaskGroup(of: (Int, PageDigest?).self) { g in
                for (i, r) in picks.enumerated() { g.addTask { (i, await PageReader.shared.digest(r.url)) } }
                var got: [(Int, PageDigest)] = []
                for await (i, d) in g { if let d { got.append((i, d)) } }
                pages = got.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard gen == self.generation else { return }
            let a = await Assistant.shared.searchAnswer(query: q, pages: pages)
            guard gen == self.generation else { return }
            self.answer = a
            self.answering = false
        }
    }
}


/// The on-device answer above the results, with the sources it used.
struct AnswerCard: View {
    @ObservedObject private var engine = SearchEngine.shared

    var body: some View {
        Group {
            if engine.answering {
                HStack(spacing: 8) {
                    Pinwheel(size: 14, spinning: true)
                    Text("Reading the top \(engine.answerSources.count) results…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
            } else if let a = engine.answer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Pinwheel(size: 13, spinning: false)
                        Text("Answer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Text(a.answer).font(.system(size: 12.5)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let used = a.sources.filter { $0 >= 1 && $0 <= engine.answerSources.count }
                    if !used.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(Set(used)).sorted(), id: \.self) { n in
                                let r = engine.answerSources[n - 1]
                                Button { engine.open(r) } label: {
                                    Text("[\(n)] \(r.domain)").font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Capsule().fill(.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .help(r.title)
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
            } else if !engine.results.isEmpty {
                Button { engine.askAI() } label: {
                    HStack(spacing: 6) {
                        Pinwheel(size: 12, spinning: false)
                        Text("Ask about these results").font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4).padding(.bottom, 6)
        .animation(.easeOut(duration: 0.18), value: engine.answering)
    }
}
