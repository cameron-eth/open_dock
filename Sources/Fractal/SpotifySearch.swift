import AppKit
import SwiftUI
import WebKit

/// Search Spotify from the dock. Results are read from Spotify's web search out of sight; picking one tells
/// your Spotify app to play it — in the background, without its window coming up.
final class SpotifySearch: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = SpotifySearch()

    struct Item: Identifiable, Hashable {
        enum Kind: String { case track, artist, album, playlist }
        let kind: Kind
        let spotifyID: String
        let title: String
        let subtitle: String
        let duration: String
        let image: URL?
        var id: String { kind.rawValue + spotifyID }
        var uri: String { "spotify:\(kind.rawValue):\(spotifyID)" }
    }

    @Published private(set) var tracks: [Item] = []
    @Published private(set) var artists: [Item] = []
    @Published private(set) var collections: [Item] = []      // albums and playlists
    @Published private(set) var loading = false
    @Published private(set) var active = false
    @Published private(set) var failed = false
    private(set) var query = ""
    private let web: WKWebView
    private var generation = 0
    private var tries = 0

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        web.navigationDelegate = self
    }

    func search(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let enc = t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://open.spotify.com/search/" + enc) else { return }
        generation &+= 1
        query = t
        tries = 0
        tracks = []; artists = []; collections = []
        failed = false
        loading = true
        active = true
        web.load(URLRequest(url: url))
    }

    func clear() {
        generation &+= 1
        web.stopLoading()
        active = false
        loading = false
        tracks = []; artists = []; collections = []
        HoverPreview.shared.refitSoon()
    }

    /// Play it in the Spotify app, which stays in the background.
    func play(_ item: Item) {
        SpotifyControl.shared.playURI(item.uri)
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { poll(generation) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done(generation) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done(generation) }

    /// Spotify's page fills in its results after loading; check a few times.
    private func poll(_ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 0.8 : 1.0)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.tries += 1
            self.web.callAsyncJavaScript(Self.js, arguments: [:], in: nil, in: .page) { r in
                guard gen == self.generation else { return }
                guard case .success(let v) = r, let d = v as? [String: Any] else { return self.done(gen) }
                let t = self.items(d["tracks"], .track), a = self.items(d["artists"], .artist)
                let c = self.items(d["albums"], .album) + self.items(d["playlists"], .playlist)
                if t.isEmpty && a.isEmpty && c.isEmpty && self.tries < 6 { return self.poll(gen) }
                self.tracks = Array(t.prefix(8))
                self.artists = Array(a.prefix(6))
                self.collections = Array(c.prefix(10))
                self.done(gen)
            }
        }
    }

    private func done(_ gen: Int) {
        guard gen == generation else { return }
        loading = false
        failed = tracks.isEmpty && artists.isEmpty && collections.isEmpty
    }

    private func items(_ raw: Any?, _ kind: Item.Kind) -> [Item] {
        (raw as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? String, let title = r["title"] as? String, !title.isEmpty else { return nil }
            var sub = (r["sub"] as? String ?? "")
            if sub.hasPrefix(title) { sub = String(sub.dropFirst(title.count)) }      // "Homework1997 • Daft Punk" → "1997 • Daft Punk"
            sub = sub.trimmingCharacters(in: CharacterSet(charactersIn: " ·•"))
            return Item(kind: kind, spotifyID: id, title: title, subtitle: sub, duration: r["extra"] as? String ?? "",
                        image: (r["image"] as? String).flatMap(URL.init(string:)))
        }
    }

    private static let js = """
    const NL = String.fromCharCode(10);
    const idOf = (a, kind) => { const m = (a.getAttribute('href') || '').match(new RegExp('^/' + kind + '/([A-Za-z0-9]+)')); return m ? m[1] : null; };
    const out = { tracks: [], artists: [], albums: [], playlists: [] };
    const seen = new Set();
    for (const a of document.querySelectorAll('a[href^="/track/"]')) {
      const id = idOf(a, 'track'); if (!id || seen.has(id)) continue; seen.add(id);
      const row = a.closest('[data-testid="tracklist-row"]') || a.closest('[role="row"]') || a.parentElement.parentElement.parentElement;
      const artists = [...row.querySelectorAll('a[href^="/artist/"]')].map(x => x.innerText.trim()).filter(Boolean);
      const dur = ((row.innerText || '').match(/[0-9]+:[0-9][0-9]/) || [''])[0];
      const img = row.querySelector('img');
      out.tracks.push({ id, title: a.innerText.trim(), sub: [...new Set(artists)].join(', '), extra: dur, image: img ? img.src : '' });
    }
    for (const kind of ['artist', 'album', 'playlist']) {
      for (const a of document.querySelectorAll('a[href^="/' + kind + '/"]')) {
        const id = idOf(a, kind); if (!id || seen.has(id)) continue;
        const card = a.closest('[data-testid="card"], [data-encore-id="card"]') || a.closest('div[role="group"]') || a.parentElement.parentElement;
        if (a.closest('[data-testid="tracklist-row"]')) continue;
        const lines = (card.innerText || '').split(NL).map(s => s.trim()).filter(Boolean);
        const title = (a.innerText || '').trim() || lines[0] || ''; if (!title) continue;
        seen.add(id);
        const img = card.querySelector('img');
        out[kind + 's'].push({ id, title, sub: lines.filter(l => l !== title).slice(0, 2).join(' · '), extra: '', image: img ? img.src : '' });
      }
    }
    return out;
    """
}

/// Search box and results for the Spotify widget.
struct SpotifySearchPanel: View {
    @ObservedObject private var search = SpotifySearch.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search Spotify…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit {
                        HoverPreview.shared.beginTyping()
                        search.search(query)
                    }
                if search.loading { ProgressView().controlSize(.mini) }
                if search.active {
                    Button { search.clear(); query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06)))
            .onChange(of: focused) { _, f in if f { HoverPreview.shared.beginTyping() } }

            if search.active {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if search.loading && search.tracks.isEmpty {
                            ForEach(0..<5, id: \.self) { _ in
                                HStack(spacing: 9) {
                                    RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 34, height: 34)
                                    VStack(alignment: .leading, spacing: 5) {
                                        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.1)).frame(width: 180, height: 9)
                                        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(width: 110, height: 8)
                                    }
                                }
                            }
                        } else if search.failed {
                            Text("No results. Try another search.").font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            if !search.tracks.isEmpty {
                                SectionTitle("Songs")
                                ForEach(search.tracks) { t in TrackRow(item: t) }
                            }
                            if !search.artists.isEmpty {
                                SectionTitle("Artists")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) { ForEach(search.artists) { a in Tile(item: a, round: true) } }
                                }
                            }
                            if !search.collections.isEmpty {
                                SectionTitle("Albums & playlists")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) { ForEach(search.collections) { c in Tile(item: c, round: false) } }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: GoogleSearchCard.resultsHeight)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: search.active)
        .onChange(of: search.active) { _, _ in HoverPreview.shared.refitSoon() }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2) }
}

private struct Art: View {
    let url: URL?
    let size: CGFloat
    let round: Bool
    var body: some View {
        AsyncImage(url: url) { i in i.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.primary.opacity(0.08) }
            .frame(width: size, height: size)
            .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
    }
}

private struct TrackRow: View {
    let item: SpotifySearch.Item
    @State private var hover = false
    @ObservedObject private var spotify = SpotifyControl.shared

    var body: some View {
        let playing = spotify.track?.name == item.title
        HStack(spacing: 9) {
            ZStack {
                Art(url: item.image, size: 34, round: false)
                if hover || playing {
                    RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.4)).frame(width: 34, height: 34)
                    Image(systemName: playing && spotify.track?.playing == true ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(playing ? Color.accentColor : Color.primary)
                Text(item.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.duration).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { SpotifySearch.shared.play(item) }
        .help("Play in Spotify")
    }
}

private struct Tile: View {
    let item: SpotifySearch.Item
    let round: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Art(url: item.image, size: 84, round: round)
                if hover {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.green))
                        .padding(4)
                }
            }
            Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(item.subtitle.isEmpty ? item.kind.rawValue.capitalized : item.subtitle)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 84)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { SpotifySearch.shared.play(item) }
        .help(item.kind == .artist ? "Play \(item.title)'s top songs" : "Play \(item.title)")
    }
}
