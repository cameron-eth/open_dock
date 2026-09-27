import AppKit

/// Claude sessions, read live from the Claude app's own sidebar (through Accessibility), so the dock
/// can show what each one is doing and jump straight to it.
struct AgentSession: Identifiable {
    enum Status: String {
        case running = "Running", waiting = "Waiting", needsInput = "Needs input", unread = "Unread", idle = "Idle", other = ""
        /// Needs you: waiting on a reply, a permission, input, or unread.
        var wantsYou: Bool { self == .waiting || self == .needsInput || self == .unread }
    }
    let id: String
    let title: String
    let status: Status
    let project: String
    /// Claude: the sidebar button. Other sources don't use Accessibility.
    var element: AXUIElement? = nil
    /// Codex thread id / Messages chat id.
    var ref: String = ""
}

struct SessionProject: Identifiable {
    var id: String { name }
    let name: String
    let newSession: AXUIElement?
    var sessions: [AgentSession]
}

/// One message of recent context shown in the dock.
struct ContextMessage: Identifiable {
    let id = UUID()
    let from: String
    let text: String
    let isMe: Bool
}

enum ContextResult {
    case messages([ContextMessage])
    /// Can't show context, and why (e.g. a permission is needed).
    case notice(String, action: (title: String, url: URL)?)
}

/// Anything the dock can list conversations for and send messages to.
protocol SessionSource: AnyObject {
    var bundleID: String { get }
    /// "Sessions", "Threads", "Conversations"…
    var heading: String { get }
    var projects: [SessionProject] { get }
    var defaultReplyTarget: AgentSession? { get }
    func start()
    func open(_ s: AgentSession)
    func send(_ text: String, to s: AgentSession)
    func newSession(in p: SessionProject)
    /// Recent messages. `explicit` = the user picked this conversation (Claude may switch to it to read).
    func context(for s: AgentSession, explicit: Bool, completion: @escaping (ContextResult) -> Void)
    /// What the message box says for this item ("Reply to…", "Message…", "Search Google…").
    func placeholder(for s: AgentSession) -> String
}

extension SessionSource {
    func placeholder(for s: AgentSession) -> String { "Reply to \(s.title)…" }
    var all: [AgentSession] { projects.flatMap(\.sessions) }
    var runningCount: Int { all.filter { $0.status == .running }.count }
    var needsYouCount: Int { all.filter { $0.status.wantsYou }.count }
}

enum Sources {
    static let all: [SessionSource] = [Sessions.shared, CodexSessions.shared, MessagesChats.shared, ChromeTabs.shared]
    static func source(for app: AppGroup) -> SessionSource? {
        all.first { $0.bundleID == app.app.bundleIdentifier }
    }
    static func start() { all.forEach { $0.start() } }
}

/// Claude, driven through its own sidebar and Prompt box via Accessibility.
final class Sessions: SessionSource {
    static let shared = Sessions()
    static let claudeBundle = "com.anthropic.claudefordesktop"
    let bundleID = Sessions.claudeBundle
    let heading = "Sessions"

    private(set) var projects: [SessionProject] = []
    private(set) var claudePID: pid_t?
    private let queue = DispatchQueue(label: "fractal.sessions", qos: .utility)
    private var exposedPIDs = Set<pid_t>()   // only touched on `queue`
    private var scanning = false

    /// Who a reply goes to by default: whoever is waiting on you, else the last one you replied to, else the first.
    private var lastReplied: String?
    var defaultReplyTarget: AgentSession? {
        all.first { $0.status.wantsYou } ?? all.first { $0.id == lastReplied } ?? all.first
    }

    func isClaude(_ app: AppGroup) -> Bool { app.app.bundleIdentifier == Self.claudeBundle }

    func start() {
        scan()
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.scan() }
    }

    func scan() {
        guard !scanning else { return }
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundle).first else {
            if !projects.isEmpty { projects = []; claudePID = nil; Tracker.shared.bump(force: true) }
            return
        }
        scanning = true
        let pid = claude.processIdentifier
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.read(pid)
            DispatchQueue.main.async {
                self.scanning = false
                self.claudePID = pid
                let changed = found.map { $0.name + $0.sessions.map { $0.title + $0.status.rawValue }.joined() }
                    != self.projects.map { $0.name + $0.sessions.map { $0.title + $0.status.rawValue }.joined() }
                self.projects = found
                if changed { Tracker.shared.bump(force: true) }
            }
        }
    }

    // MARK: Steering

    /// Bring Claude forward and switch to this session.
    func open(_ s: AgentSession) {
        guard let pid = claudePID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        let window = Tracker.shared.apps[pid]?.windows.first { !$0.minimized }
        if let w = window { Steer.focus(w) } else { Steer.bringForward(app, window: nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let el = s.element { AXUIElementPerformAction(el, kAXPressAction as CFString) }
            self.scanSoon()
        }
    }

    /// Send a prompt to a session without bringing Claude up: switch to the session, put the text in its
    /// Prompt box and press Send — all through Accessibility, with Claude staying in the background.
    /// If Claude has no Send button to press (e.g. the session is mid-run and shows Stop), fall back to
    /// bringing Claude forward for a moment, pressing Return, and putting you straight back.
    func send(_ text: String, to s: AgentSession) {
        guard let pid = claudePID else { NSSound.beep(); return }
        lastReplied = s.id
        let previous = NSWorkspace.shared.frontmostApplication
        guard let el = s.element else { NSSound.beep(); return }
        AXUIElementPerformAction(el, kAXPressAction as CFString)                 // switch session, in the background
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard let composer = self.findComposer(pid) else { return self.fail() }
            // Never clobber or send a half-written draft.
            guard self.value(composer).isEmpty else { return self.fail() }

            AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, text as CFString)
            usleep(150_000)
            let placed = self.value(composer).contains(String(text.prefix(12)))

            if placed, let sendButton = self.findSendButton(pid) {
                AXUIElementPerformAction(sendButton, kAXPressAction as CFString)
                if self.waitUntilEmpty(composer) { return self.done() }
            }
            // Fallback: typing needs Claude in front, so do it without Claude ever appearing:
            // move its window off-screen (un-minimizing it out of sight if needed), type and send,
            // put you back in your app, then return the window exactly as it was.
            let window: AXUIElement? = DispatchQueue.main.sync {
                Tracker.shared.apps[pid]?.windows.min { $0.z < $1.z }?.element
            }
            guard let window, let app = NSRunningApplication(processIdentifier: pid) else { return self.fail() }
            let original = AX.frame(window)
            let wasMinimized = AX.bool(window, kAXMinimizedAttribute)
            let hideAt: CGPoint = DispatchQueue.main.sync {
                let u = NSScreen.screens.map(\.axFrame).reduce(CGRect.null) { $0.union($1) }
                return CGPoint(x: u.maxX + 50, y: u.maxY + 50)
            }
            AX.setPosition(window, hideAt)
            if wasMinimized { AX.setMinimized(window, false) }
            DispatchQueue.main.sync { Steer.bringForward(app, window: window) }
            usleep(350_000)
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(100_000)
            var ok = true
            if !self.value(composer).contains(String(text.prefix(12))) {
                if self.value(composer).isEmpty {
                    Keys.type(text, to: pid)
                    usleep(150_000)
                }
                ok = self.value(composer).contains(String(text.prefix(12)))
            }
            if ok {
                Keys.press(36, to: pid)   // Return sends
                ok = self.waitUntilEmpty(composer)
            }
            DispatchQueue.main.sync {
                if let previous, previous.processIdentifier != pid, previous.processIdentifier != getpid() {
                    Steer.bringForward(previous, window: nil)
                }
            }
            usleep(200_000)
            if wasMinimized {
                AX.setMinimized(window, true)
                usleep(400_000)
            }
            if let original { AX.setPosition(window, original.origin) }
            if wasMinimized, !AX.bool(window, kAXMinimizedAttribute) { AX.setMinimized(window, true) }
            if !ok { self.fail() }
            self.done()
        }
    }

    private func value(_ e: AXUIElement) -> String {
        (AX.string(e, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitUntilEmpty(_ composer: AXUIElement) -> Bool {
        for _ in 0..<10 { usleep(80_000); if value(composer).isEmpty { return true } }
        return false
    }

    private func done() { DispatchQueue.main.async { self.scanSoon() } }
    private func fail() { DispatchQueue.main.async { NSSound.beep() } }

    /// Claude's Send button (the one next to the Prompt box; while a session runs it reads "Stop").
    private func findSendButton(_ pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        guard let windows: [AXUIElement] = AX.attr(appEl, kAXWindowsAttribute) else { return nil }
        func walk(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            guard d < 45 else { return nil }
            let l = label(e)
            if l == "Chat messages" || l == "Sidebar" { return nil }
            if AX.string(e, kAXRoleAttribute) == kAXButtonRole as String, l.hasPrefix("Send"), l != "Send feedback",
               (AX.attr(e, kAXEnabledAttribute) as NSNumber?)?.boolValue ?? true { return e }
            for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let hit = walk(c, d + 1) { return hit } }
            return nil
        }
        for w in windows { if let hit = walk(w, 0) { return hit } }
        return nil
    }

    /// Claude's prompt box ("Prompt" text area), skipping the transcript.
    private func findComposer(_ pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        guard let windows: [AXUIElement] = AX.attr(appEl, kAXWindowsAttribute) else { return nil }
        func walk(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            guard d < 45 else { return nil }
            let l = label(e)
            if l == "Chat messages" || l == "Sidebar" { return nil }
            if AX.string(e, kAXRoleAttribute) == kAXTextAreaRole as String, l == "Prompt" { return e }
            for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let hit = walk(c, d + 1) { return hit } }
            return nil
        }
        for w in windows { if let hit = walk(w, 0) { return hit } }
        return nil
    }

    /// Claude only shows one session at a time; read it if it's the one on screen (or switch to it,
    /// in the background, if you picked it).
    func context(for s: AgentSession, explicit: Bool, completion: @escaping (ContextResult) -> Void) {
        guard let pid = claudePID else { return completion(.notice("Claude isn't running.", action: nil)) }
        // Switching sessions to read one is fine when you picked it, or when you're not looking at Claude.
        let claudeInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let mayPeek = explicit || !claudeInFront
        let original = all.first { $0.title == lastShown }
        queue.async { [weak self] in
            guard let self else { return }
            // Best path: read the session's transcript from disk — no window switching at all.
            if let path = self.transcriptPath(for: s.title) {
                let msgs = self.readTranscript(path)
                if !msgs.isEmpty { return DispatchQueue.main.async { completion(.messages(msgs)) } }
            }
            let current = self.currentTitle(pid)
            var switched = false
            if current != s.title {
                guard mayPeek, let el = s.element else {
                    return DispatchQueue.main.async { completion(.notice("Click this session to load its latest messages.", action: nil)) }
                }
                AXUIElementPerformAction(el, kAXPressAction as CFString)
                for _ in 0..<10 { usleep(100_000); if self.currentTitle(pid) == s.title { break } }
                usleep(250_000)
                switched = true
            }
            let msgs = self.readMessages(pid)
            // Just peeking: put Claude back on the session it was showing.
            if switched, !explicit, let back = original?.element ?? self.sessionElement(titled: current) {
                AXUIElementPerformAction(back, kAXPressAction as CFString)
            }
            DispatchQueue.main.async {
                if explicit || !switched { self.lastShown = s.title }
                completion(msgs.isEmpty ? .notice("No messages yet.", action: nil) : .messages(msgs))
            }
        }
    }

    // MARK: Transcripts on disk

    private struct Record { let title: String; let cli: String; let activity: Double }
    private var records: [Record] = []            // queue only
    private var recordsLoadedAt = Date.distantPast
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// The desktop app keeps one small record per Code session: its title and the transcript it writes.
    private func loadRecords() {
        guard Date().timeIntervalSince(recordsLoadedAt) > 20 else { return }
        recordsLoadedAt = Date()
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var out: [Record] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                guard let d = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      d["isArchived"] as? Bool != true,
                      let title = d["title"] as? String, let cli = d["cliSessionId"] as? String else { continue }
                out.append(Record(title: title, cli: cli, activity: (d["lastActivityAt"] as? Double) ?? 0))
            }
        }
        records = out.sorted { $0.activity > $1.activity }
    }

    private func transcriptPath(for title: String) -> String? {
        loadRecords()
        // Sidebar titles can carry a PR prefix ("#42, #43 · Title").
        let bare = title.components(separatedBy: " · ").last ?? title
        guard let r = records.first(where: { $0.title == title }) ?? records.first(where: { $0.title == bare })
                ?? records.first(where: { title.hasSuffix($0.title) }) else { return nil }
        let projects = home.appendingPathComponent(".claude/projects")
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let path = projects.appendingPathComponent(dir).appendingPathComponent(r.cli + ".jsonl").path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// The last few real messages (skipping tool calls, tool output and injected context).
    private func readTranscript(_ path: String) -> [ContextMessage] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 1_500_000
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
        var msgs: [ContextMessage] = []
        for line in tail.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  d["isSidechain"] as? Bool != true, d["isMeta"] as? Bool != true,
                  let message = d["message"] as? [String: Any] else { continue }
            var text = ""
            if let str = message["content"] as? String {
                text = str
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<") else { continue }   // skip command/system wrappers
            let me = type == "user"
            msgs.append(ContextMessage(from: me ? "You" : "Claude", text: String(text.prefix(1500)), isMe: me))
        }
        return Array(msgs.suffix(6))
    }

    /// The session Claude's window was last seen showing.
    private var lastShown: String?

    private func sessionElement(titled t: String?) -> AXUIElement? {
        guard let t else { return nil }
        return DispatchQueue.main.sync { self.all.first { $0.title == t }?.element }
    }

    /// Title of the session Claude is showing (its header reads "<title>, rename session").
    private func currentTitle(_ pid: pid_t) -> String? {
        guard let w = firstWindow(pid) else { return nil }
        func walk(_ e: AXUIElement, _ d: Int) -> String? {
            guard d < 40 else { return nil }
            let l = label(e)
            if l == "Chat messages" || l == "Sidebar" { return nil }
            if l.hasSuffix(", rename session") { return String(l.dropLast(", rename session".count)) }
            for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let t = walk(c, d + 1) { return t } }
            return nil
        }
        return walk(w, 0)
    }

    private func firstWindow(_ pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        return (AX.attr(appEl, kAXWindowsAttribute) as [AXUIElement]?)?.first
    }

    /// The last few messages in Claude's transcript.
    private func readMessages(_ pid: pid_t) -> [ContextMessage] {
        guard let w = firstWindow(pid), let list = find(in: w, label: "Chat messages", depth: 0, skipTranscript: false) else { return [] }
        let groups = ((AX.attr(list, kAXChildrenAttribute) as [AXUIElement]?) ?? []).filter { label($0).hasPrefix("Message") }
        return groups.suffix(6).compactMap { g in
            var texts: [String] = []
            var buttons: [String] = []
            collect(g, texts: &texts, buttons: &buttons, depth: 0)
            let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let isMe = buttons.contains("Rewind to here")       // your messages can be rewound to; Claude's can be read aloud
            return ContextMessage(from: isMe ? "You" : "Claude", text: String(text.prefix(1500)), isMe: isMe)
        }
    }

    private func collect(_ e: AXUIElement, texts: inout [String], buttons: inout [String], depth: Int) {
        guard depth < 30, texts.count < 200 else { return }
        let role = AX.string(e, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole as String, let v = AX.string(e, kAXValueAttribute), !v.isEmpty { texts.append(v) }
        if role == kAXButtonRole as String { buttons.append(label(e)); return }
        for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { collect(c, texts: &texts, buttons: &buttons, depth: depth + 1) }
    }

    func newSession(in p: SessionProject) {
        guard let el = p.newSession, let pid = claudePID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        Steer.bringForward(app, window: Tracker.shared.apps[pid]?.windows.first?.element)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AXUIElementPerformAction(el, kAXPressAction as CFString)
            self.scanSoon()
        }
    }

    func scanSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scan() }
    }

    // MARK: Reading the sidebar

    private static let controls: Set<String> = [
        "Hide sidebar", "Show sidebar", "Back", "Forward", "New", "Artifacts", "Routines", "Customize",
        "Pinned", "Search", "Send feedback", "Chat and Cowork", "Code",
    ]

    private func read(_ pid: pid_t) -> [SessionProject] {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        if !exposedPIDs.contains(pid) {
            // Electron apps only build their accessibility tree once someone asks for it.
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            exposedPIDs.insert(pid)
        }
        guard let windows: [AXUIElement] = AX.attr(appEl, kAXWindowsAttribute) else { return [] }
        for w in windows {
            guard let sidebar = find(in: w, label: "Sidebar", depth: 0) else { continue }
            var buttons: [(String, AXUIElement)] = []
            collectButtons(sidebar, into: &buttons, depth: 0)
            return parse(buttons)
        }
        return []
    }

    private func label(_ e: AXUIElement) -> String {
        let t = AX.string(e, kAXTitleAttribute) ?? ""
        return t.isEmpty ? (AX.string(e, kAXDescriptionAttribute) ?? "") : t
    }

    /// Breadth-limited search for the sidebar, skipping the (huge) chat transcript.
    private func find(in e: AXUIElement, label want: String, depth: Int, skipTranscript: Bool = true) -> AXUIElement? {
        guard depth < 30 else { return nil }
        let l = label(e)
        if l == want { return e }
        if skipTranscript && (l == "Primary pane" || l == "Chat messages") { return nil }
        if !skipTranscript && l == "Sidebar" { return nil }
        for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let hit = find(in: c, label: want, depth: depth + 1, skipTranscript: skipTranscript) { return hit }
        }
        return nil
    }

    private func collectButtons(_ e: AXUIElement, into out: inout [(String, AXUIElement)], depth: Int) {
        guard depth < 25, out.count < 300 else { return }
        if AX.string(e, kAXRoleAttribute) == kAXButtonRole as String {
            let l = label(e)
            if !l.isEmpty { out.append((l, e)) }
        }
        for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { collectButtons(c, into: &out, depth: depth + 1) }
    }

    private func parse(_ buttons: [(String, AXUIElement)]) -> [SessionProject] {
        let newPrefix = "New session in "
        var newButtons: [String: AXUIElement] = [:]
        for (l, e) in buttons where l.hasPrefix(newPrefix) { newButtons[String(l.dropFirst(newPrefix.count))] = e }

        var projects: [SessionProject] = [SessionProject(name: "Pinned", newSession: nil, sessions: [])]
        var seen = Set<String>()
        for (l, e) in buttons {
            if Self.controls.contains(l) || l.hasPrefix(newPrefix) || l.hasPrefix("Relaunch") { continue }
            if newButtons[l] != nil {                                   // a project header
                projects.append(SessionProject(name: l, newSession: newButtons[l], sessions: []))
                continue
            }
            var status = AgentSession.Status.other
            var title = l
            for s in [AgentSession.Status.needsInput, .running, .waiting, .idle] where l.hasPrefix(s.rawValue + " ") {
                status = s
                title = String(l.dropFirst(s.rawValue.count + 1))
                break
            }
            let key = projects[projects.count - 1].name + "/" + title
            guard seen.insert(key).inserted else { continue }
            projects[projects.count - 1].sessions.append(
                AgentSession(id: key, title: title, status: status, project: projects[projects.count - 1].name, element: e))
        }
        return projects.filter { !$0.sessions.isEmpty || $0.newSession != nil }
    }
}

/// Types text straight into one app (by process), so nothing lands in the wrong place if focus moves.
enum Keys {
    static func type(_ text: String, to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            var units = Array(line.utf16)
            while !units.isEmpty {
                let chunk = Array(units.prefix(16))
                units.removeFirst(chunk.count)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                    e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    e.postToPid(pid)
                }
                usleep(3_000)
            }
            if i < lines.count - 1 { press(36, to: pid, flags: .maskShift) }   // Shift-Return = new line
        }
    }

    static func press(_ key: CGKeyCode, to pid: pid_t, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.postToPid(pid)
        }
    }
}
