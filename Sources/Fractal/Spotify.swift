import AppKit
import SwiftUI

/// Spotify, steered from the dock: what's playing, play/pause, skip, volume, and search.
/// Uses Spotify's AppleScript support; macOS asks once for permission.
final class SpotifyControl: ObservableObject {
    static let shared = SpotifyControl()
    static let bundleID = "com.spotify.client"

    struct Track: Equatable {
        var playing = false
        var name = ""
        var artist = ""
        var album = ""
        var artwork: URL?
        var duration: Double = 0      // seconds
        var position: Double = 0      // seconds
        var volume: Double = 50       // 0–100
    }

    @Published private(set) var track: Track?
    private let queue = DispatchQueue(label: "mono.spotify", qos: .userInitiated)
    private var polling = false

    static func isSpotify(_ app: AppGroup) -> Bool { app.app.bundleIdentifier == bundleID }
    private var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    func start() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !polling else { return }
        guard running else { if track != nil { track = nil }; return }
        polling = true
        queue.async { [weak self] in
            let r = MessagesChats.osascript("""
            tell application "Spotify"
              if not (exists current track) then return ""
              set t to current track
              return (player state as string) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (artwork url of t) & tab & ((duration of t) as string) & tab & ((player position) as string) & tab & ((sound volume) as string)
            end tell
            """, args: [])
            let f = (r.output ?? "").trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var t: Track?
            if r.ok, f.count >= 8 {
                let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                t = Track(playing: f[0] == "playing", name: f[1], artist: f[2], album: f[3], artwork: URL(string: f[4]),
                          duration: num(f[5]) / 1000, position: num(f[6]), volume: num(f[7]))
            }
            DispatchQueue.main.async {
                self?.polling = false
                if self?.track != t { self?.track = t }
            }
        }
    }

    private func tell(_ command: String) {
        queue.async { [weak self] in
            _ = MessagesChats.osascript("tell application \"Spotify\" to \(command)", args: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refresh() }
        }
    }

    func playPause() { track?.playing.toggle(); tell("playpause") }
    func next() { tell("next track") }
    func previous() { tell("previous track") }
    func setVolume(_ v: Double) { track?.volume = v; tell("set sound volume to \(Int(v.rounded()))") }

    /// Play a song, album, playlist or artist by its Spotify address — the app stays in the background.
    func playURI(_ uri: String) {
        queue.async { [weak self] in
            _ = MessagesChats.osascript("""
            on run argv
              tell application "Spotify" to play track (item 1 of argv)
            end run
            """, args: [uri])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh() }
        }
    }

    /// Opens Spotify's search for the text (Spotify comes forward so you can pick a result).
    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "spotify:search:" + enc) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct NowPlayingCard: View {
    @ObservedObject private var spotify = SpotifyControl.shared
    @ObservedObject private var search = SpotifySearch.shared
    @State private var volume: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = spotify.track, search.active {
                // Searching: a slim now-playing bar keeps the room for results.
                HStack(spacing: 8) {
                    AsyncImage(url: t.artwork) { img in img.resizable() } placeholder: { Color.primary.opacity(0.08) }
                        .frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(t.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(t.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Control(t.playing ? "pause.fill" : "play.fill") { spotify.playPause() }
                    Control("forward.fill") { spotify.next() }
                }
            } else if let t = spotify.track {
                HStack(spacing: 10) {
                    AsyncImage(url: t.artwork) { img in img.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08)) }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(t.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: min(t.position, max(t.duration, 1)), total: max(t.duration, 1))
                            .progressViewStyle(.linear).controlSize(.mini).padding(.top, 3)
                    }
                }
                HStack(spacing: 18) {
                    Spacer()
                    Control("backward.fill") { spotify.previous() }
                    Control(t.playing ? "pause.fill" : "play.fill", size: 18) { spotify.playPause() }
                    Control("forward.fill") { spotify.next() }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...100) { editing in if !editing { spotify.setVolume(volume) } }
                        .controlSize(.mini)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .onAppear { volume = t.volume }
                .onChange(of: t.volume) { _, v in volume = v }
            } else {
                Text("Nothing playing.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            SpotifySearchPanel()
        }
        .padding(.top, 6)
        .onAppear { spotify.refresh() }
    }
}

private struct Control: View {
    let symbol: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hover = false
    init(_ symbol: String, size: CGFloat = 13, action: @escaping () -> Void) { self.symbol = symbol; self.size = size; self.action = action }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
