import AppKit

/// Google Chrome: your open tabs, and a box that searches Google (or opens a URL) in a new tab.
/// Driven through Chrome's own AppleScript support; macOS asks once for permission.
final class ChromeTabs: SessionSource {
    static let shared = ChromeTabs()
    let bundleID = "com.google.Chrome"
    let heading = "Tabs"

    private(set) var projects: [SessionProject] = []
    private let queue = DispatchQueue(label: "mono.chrome", qos: .utility)
    private var scanning = false

    /// The tab you're looking at in the front window.
    var defaultReplyTarget: AgentSession? { projects.first?.sessions.first { $0.status == .running } ?? all.first }

    private var app: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }

    func start() {
        scan()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.scan() }
    }

    func scan() {
        guard !scanning, app != nil else {
            if app == nil, !projects.isEmpty { projects = []; Tracker.shared.bump(force: true) }
            return
        }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let r = MessagesChats.osascript("""
            tell application "Google Chrome"
              set out to ""
              set wi to 0
              repeat with w in windows
                set wi to wi + 1
                set ai to active tab index of w
                set ti to 0
                repeat with t in tabs of w
                  set ti to ti + 1
                  if ti > 40 then exit repeat
                  set out to out & wi & tab & ti & tab & (id of t) & tab & (title of t) & tab & (URL of t) & tab & (ti = ai) & linefeed
                end repeat
              end repeat
              return out
            end tell
            """, args: [])
            var windows: [[AgentSession]] = []
            for line in (r.output ?? "").split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 6, let wi = Int(f[0]) else { continue }
                while windows.count < wi { windows.append([]) }
                let title = f[3].isEmpty ? (URL(string: f[4])?.host ?? f[4]) : f[3]
                windows[wi - 1].append(AgentSession(id: f[2], title: title, status: f[5] == "true" ? .running : .other,
                                                    project: "Window \(wi)", ref: "\(wi):\(f[1]):\(f[4])"))
            }
            // Active tab first in each window.
            let found = windows.enumerated().map { i, tabs in
                SessionProject(name: windows.count == 1 ? "Open tabs" : "Window \(i + 1)", newSession: nil,
                               sessions: tabs.filter { $0.status == .running } + tabs.filter { $0.status != .running })
            }.filter { !$0.sessions.isEmpty }
            DispatchQueue.main.async {
                self.scanning = false
                guard r.ok else { NSLog("Mono Dock: reading Chrome tabs failed: \(r.error ?? "")"); return }
                let sig = { (ps: [SessionProject]) in ps.map { $0.sessions.map { $0.id + $0.title + $0.status.rawValue }.joined() }.joined() }
                let changed = sig(found) != sig(self.projects)
                self.projects = found
                if changed { Tracker.shared.bump(force: true) }
            }
        }
    }

    private func parts(_ s: AgentSession) -> (window: Int, tab: Int, url: String)? {
        let p = s.ref.split(separator: ":", maxSplits: 2).map(String.init)
        guard p.count == 3, let w = Int(p[0]), let t = Int(p[1]) else { return nil }
        return (w, t, p[2])
    }

    /// Switch to the tab (brings Chrome forward — you asked to look at it).
    func open(_ s: AgentSession) {
        guard let (w, t, _) = parts(s) else { return }
        queue.async {
            _ = MessagesChats.osascript("""
            on run argv
              tell application "Google Chrome"
                set w to window ((item 1 of argv) as integer)
                set active tab index of w to ((item 2 of argv) as integer)
                set index of w to 1
                activate
              end tell
            end run
            """, args: [String(w), String(t)])
            DispatchQueue.main.async { self.scan() }
        }
    }

    /// Open a page in a new Chrome tab and bring Chrome forward.
    func openURL(_ url: String) { send(url, to: AgentSession(id: "", title: "", status: .other, project: "")) }

    /// Search Google (or open a URL) in a new tab of the front window, and show it.
    func send(_ text: String, to s: AgentSession) {
        let url = Self.url(for: text)
        queue.async {
            let r = MessagesChats.osascript("""
            on run argv
              tell application "Google Chrome"
                if (count of windows) = 0 then make new window
                tell window 1 to make new tab with properties {URL:(item 1 of argv)}
                activate
              end tell
            end run
            """, args: [url])
            if !r.ok { DispatchQueue.main.async { NSSound.beep() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.scan() }
        }
    }

    /// "news.ycombinator.com" or "https://…" opens directly; anything else is a Google search.
    static func url(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return t }
        if !t.contains(" "), t.contains("."), let host = t.split(separator: "/").first, host.contains("."),
           host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true {
            return "https://" + t
        }
        var q = CharacterSet.urlQueryAllowed
        q.remove(charactersIn: "&+=?#")
        return "https://www.google.com/search?q=" + (t.addingPercentEncoding(withAllowedCharacters: q) ?? t)
    }

    func newSession(in p: SessionProject) {}

    func placeholder(for s: AgentSession) -> String { "Search Google or enter a URL…" }

    func context(for s: AgentSession, explicit: Bool, completion: @escaping (ContextResult) -> Void) {
        let url = parts(s)?.url ?? ""
        completion(.notice(url.isEmpty ? s.title : url, action: nil))
    }
}
