import AppKit
import WebKit

/// The useful parts of a web page, pulled out so the dock can show them cleanly.
struct PageDigest {
    var title: String
    var url: URL
    var site: String
    var description: String
    var text: [String]            // headings and paragraphs of the main content, in order
    var image: URL?
    var recipe: Recipe?

    struct Recipe {
        var name: String
        var ingredients: [String]
        var steps: [String]
        var time: String?
        var servings: String?
        var rating: String?
    }
}

/// Loads a page out of sight and extracts its content: structured data when the site publishes it
/// (recipes especially), otherwise the main text. Each page is read once per session.
final class PageReader {
    static let shared = PageReader()
    private var cache: [URL: PageDigest] = [:]
    private var inFlight: [URL: Task<PageDigest?, Never>] = [:]
    private let store = WKWebsiteDataStore.nonPersistent()

    @MainActor
    func cached(_ url: URL) -> PageDigest? { cache[url] }

    @MainActor
    func digest(_ url: URL) async -> PageDigest? {
        if let d = cache[url] { return d }
        if let t = inFlight[url] { return await t.value }
        let t = Task { @MainActor () -> PageDigest? in
            let loader = PageLoad(url: url, store: store)
            let d = await loader.run()
            if let d { cache[url] = d }
            inFlight[url] = nil
            return d
        }
        inFlight[url] = t
        return await t.value
    }
}

/// One page load in a hidden web view.
@MainActor
private final class PageLoad: NSObject, WKNavigationDelegate {
    private let url: URL
    private let web: WKWebView
    private var done: CheckedContinuation<PageDigest?, Never>?
    private var finished = false

    init(url: URL, store: WKWebsiteDataStore) {
        self.url = url
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 900), configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        web.navigationDelegate = self
    }

    func run() async -> PageDigest? {
        await withCheckedContinuation { c in
            done = c
            web.load(URLRequest(url: url, timeoutInterval: 12))
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.extract() }   // slow page: take what's there
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.extract() }
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(nil) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish(nil) }

    private func extract() {
        guard !finished else { return }
        web.callAsyncJavaScript(Self.js, arguments: [:], in: nil, in: .page) { [weak self] r in
            guard let self else { return }
            guard case .success(let v) = r, let d = v as? [String: Any] else { return self.finish(nil) }
            self.finish(Self.parse(d, fallback: self.url))
        }
    }

    private func finish(_ d: PageDigest?) {
        guard !finished else { return }
        finished = true
        web.stopLoading()
        done?.resume(returning: d)
        done = nil
    }

    private static func parse(_ d: [String: Any], fallback: URL) -> PageDigest {
        let url = (d["url"] as? String).flatMap(URL.init(string:)) ?? fallback
        var recipe: PageDigest.Recipe?
        if let r = d["recipe"] as? [String: Any] {
            let ingredients = (r["ingredients"] as? [String] ?? []).map(clean).filter { !$0.isEmpty }
            let steps = (r["steps"] as? [String] ?? []).map(clean).filter { !$0.isEmpty }
            if !ingredients.isEmpty || !steps.isEmpty {
                recipe = .init(name: clean(r["name"] as? String ?? ""), ingredients: ingredients, steps: steps,
                               time: duration(r["time"] as? String), servings: (r["servings"] as? String).map(clean),
                               rating: (r["rating"] as? String).flatMap { Double($0) }.map { String(format: "%.1f", $0) })
            }
        }
        return PageDigest(title: clean(d["title"] as? String ?? ""), url: url,
                          site: (url.host ?? "").replacingOccurrences(of: "www.", with: ""),
                          description: clean(d["description"] as? String ?? ""),
                          text: (d["text"] as? [String] ?? []).map(clean).filter { !$0.isEmpty },
                          image: (d["image"] as? String).flatMap(URL.init(string:)), recipe: recipe)
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "PT1H25M" → "1 hr 25 min".
    private static func duration(_ iso: String?) -> String? {
        guard let iso, iso.hasPrefix("P") else { return nil }
        var h = 0, m = 0, num = ""
        for c in iso {
            if c.isNumber { num.append(c) }
            else if c == "H" { h = Int(num) ?? 0; num = "" }
            else if c == "M" { m = Int(num) ?? 0; num = "" }
            else { num = "" }
        }
        if h == 0 && m == 0 { return nil }
        return [h > 0 ? "\(h) hr" : nil, m > 0 ? "\(m) min" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// Structured data first (schema.org JSON-LD), then the page's main readable text.
    private static let js = """
    const NL = String.fromCharCode(10);
    const out = { title: document.title, url: location.href };
    const blocks = [];
    for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        const j = JSON.parse(s.textContent);
        const items = Array.isArray(j) ? j : (j['@graph'] ? j['@graph'] : [j]);
        for (const x of items) blocks.push(x);
      } catch (e) {}
    }
    const typeOf = x => [].concat((x && x['@type']) || []).join(',');
    const r = blocks.find(x => typeOf(x).includes('Recipe'));
    if (r) {
      const steps = [];
      const walk = s => {
        if (!s) return;
        if (typeof s === 'string') { steps.push(s); return; }
        if (Array.isArray(s)) { s.forEach(walk); return; }
        if (s.itemListElement) { walk(s.itemListElement); return; }
        if (s.text) steps.push(s.text);
      };
      walk(r.recipeInstructions);
      const y = [].concat(r.recipeYield || []);
      const img = [].concat(r.image || [])[0];
      out.recipe = {
        name: r.name || '', ingredients: r.recipeIngredient || [], steps: steps.slice(0, 20),
        time: r.totalTime || r.cookTime || r.prepTime || '',
        servings: String(y.find(v => /[a-z]/i.test(String(v))) || y[0] || ''),
        rating: r.aggregateRating ? String(r.aggregateRating.ratingValue || '') : ''
      };
      out.image = typeof img === 'string' ? img : (img && img.url) || '';
    }
    const meta = n => (document.querySelector('meta[name="' + n + '"], meta[property="' + n + '"]') || {}).content || '';
    const art = blocks.find(x => /Article|BlogPosting|NewsArticle/.test(typeOf(x)));
    out.description = (art && art.description) || meta('description') || meta('og:description');
    if (!out.image) out.image = meta('og:image');
    const main = document.querySelector('article') || document.querySelector('main') || document.body;
    const text = [];
    for (const e of main.querySelectorAll('h1, h2, h3, p, li')) {
      const t = (e.innerText || '').trim();
      if (!t) continue;
      const heading = /^H/.test(e.tagName);
      if (heading ? t.length > 2 && t.length < 120 : t.length > 60) text.push((heading ? '## ' : '') + t);
      if (text.length > 60) break;
    }
    out.text = text;
    return out;
    """
}
