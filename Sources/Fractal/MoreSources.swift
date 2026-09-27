import AppKit
import SQLite3

// MARK: - Codex (the ChatGPT desktop app)

/// Codex threads, read from Codex's own local session index and logs, and replied to with the
/// `codex queue` command bundled inside the app. That command hands the message to the desktop
/// app's local server, so it shows up in the app and the window never has to come up.
final class CodexSessions: SessionSource {
    static let shared = CodexSessions()
    let bundleID = "com.openai.codex"
    let heading = "Threads"

    private(set) var projects: [SessionProject] = []
    private var lastReplied: String?
    private let queue = DispatchQueue(label: "mono.codex", qos: .utility)
    private var scanning = false
    private var paths: [String: String] = [:]      // thread id → log file (queue only)
    private var folders: [String: String] = [:]    // thread id → project folder (queue only)

    private let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    var defaultReplyTarget: AgentSession? {
        all.first { $0.status.wantsYou } ?? all.first { $0.id == lastReplied } ?? all.first
    }

    func start() {
        scan()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
    }

    private var app: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }

    /// The `codex` command that ships inside the app.
    /// Where the app keeps its bundled `codex` tool (it moved in newer versions).
    private static let cliPaths = [
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex-cli/bin/codex",
        "Contents/Resources/codex",
    ]

    private var cli: URL? {
        guard let bundle = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Self.cliPaths.map { bundle.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Reading

    func scan() {
        guard !scanning, app != nil else {
            if app == nil, !projects.isEmpty { projects = []; Tracker.shared.bump(force: true) }
            return
        }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.read()
            DispatchQueue.main.async {
                self.scanning = false
                let sig = { (ps: [SessionProject]) in ps.map { $0.name + $0.sessions.map { $0.id + $0.title + $0.status.rawValue }.joined() } }
                let changed = sig(found) != sig(self.projects)
                self.projects = found
                if changed { Tracker.shared.bump(force: true) }
            }
        }
    }

    private func read() -> [SessionProject] {
        // Newest entry per thread from the index.
        guard let text = try? String(contentsOf: home.appendingPathComponent("session_index.jsonl"), encoding: .utf8) else { return [] }
        var latest: [String: (name: String, updated: String)] = [:]
        for line in text.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = d["id"] as? String else { continue }
            let name = (d["thread_name"] as? String) ?? ""
            let updated = (d["updated_at"] as? String) ?? "\(d["updated_at"] ?? "")"
            if let old = latest[id], old.updated >= updated { continue }
            latest[id] = (name, updated)
        }
        let recent = latest.sorted { $0.value.updated > $1.value.updated }.prefix(10)
        if recent.contains(where: { paths[$0.key] == nil }) { indexLogs() }

        var groups: [(String, [AgentSession])] = []
        for (id, info) in recent {
            guard let path = paths[id] else { continue }            // archived or deleted: skip
            let folder = folders[id] ?? projectFolder(path)
            folders[id] = folder
            let s = AgentSession(id: id, title: info.name.isEmpty ? "Untitled thread" : info.name,
                                 status: status(path), project: folder, ref: id)
            if let i = groups.firstIndex(where: { $0.0 == folder }) { groups[i].1.append(s) } else { groups.append((folder, [s])) }
        }
        return groups.map { SessionProject(name: $0.0, newSession: nil, sessions: $0.1) }
    }

    /// Map thread ids to their log files (file names end with the id).
    private func indexLogs() {
        let root = home.appendingPathComponent("sessions")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let name = url.deletingPathExtension().lastPathComponent        // rollout-<date>-<uuid>
            if name.count >= 36 { paths[String(name.suffix(36))] = url.path }
        }
    }

    /// Running if the last task in the log started but hasn't finished (and the log is still fresh).
    private func status(_ path: String) -> AgentSession.Status {
        guard let fh = FileHandle(forReadingAtPath: path) else { return .idle }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 256 * 1024
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
        let started = tail.range(of: "\"type\":\"task_started\"", options: .backwards)?.lowerBound
        let completed = tail.range(of: "\"type\":\"task_complete\"", options: .backwards)?.lowerBound
        guard let started else { return .idle }
        if let completed, completed > started { return .idle }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        return Date().timeIntervalSince(modified) < 30 * 60 ? .running : .idle
    }

    /// The folder a thread works in, from the first record of its log.
    private func projectFolder(_ path: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "Codex" }
        defer { try? fh.close() }
        let head = String(decoding: fh.readData(ofLength: 64 * 1024), as: UTF8.self)
        guard let r = head.range(of: #""cwd":"([^"]*)""#, options: .regularExpression) else { return "Codex" }
        let cwd = String(head[r]).replacingOccurrences(of: "\"cwd\":\"", with: "").dropLast()
        let name = URL(fileURLWithPath: String(cwd)).lastPathComponent
        return name.isEmpty || name == "/" ? "No folder" : name
    }

    // MARK: Steering

    func open(_ s: AgentSession) {
        guard let url = URL(string: "codex://threads/\(s.ref)") else { return }
        NSWorkspace.shared.open(url)
    }

    func send(_ text: String, to s: AgentSession) {
        guard let cli else { NSSound.beep(); return }
        lastReplied = s.id
        queue.async {
            let p = Process()
            p.executableURL = cli
            p.arguments = ["queue", "--thread", s.ref, "--message", text]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            do { try p.run() } catch { DispatchQueue.main.async { NSSound.beep() }; return }
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                NSLog("Mono Dock: codex queue failed: \(msg)")
                DispatchQueue.main.async { NSSound.beep() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.scan() }
        }
    }

    func newSession(in p: SessionProject) {}

    /// The thread's last messages, straight from its log.
    func context(for s: AgentSession, explicit: Bool, completion: @escaping (ContextResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.paths[s.ref] == nil { self.indexLogs() }
            guard let path = self.paths[s.ref], let fh = FileHandle(forReadingAtPath: path) else {
                return DispatchQueue.main.async { completion(.notice("Couldn't find this thread's history.", action: nil)) }
            }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            let chunk: UInt64 = 1_500_000
            try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
            let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
            var msgs: [ContextMessage] = []
            for line in tail.split(separator: "\n") {
                guard line.contains("\"type\":\"message\""),
                      let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      d["type"] as? String == "response_item",
                      let p = d["payload"] as? [String: Any], p["type"] as? String == "message",
                      let role = p["role"] as? String, role == "user" || role == "assistant",
                      let content = p["content"] as? [[String: Any]] else { continue }
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip the environment/context blocks Codex injects as "user" turns.
                guard !text.isEmpty, !text.hasPrefix("<") else { continue }
                msgs.append(ContextMessage(from: role == "user" ? "You" : "Codex", text: String(text.prefix(1500)), isMe: role == "user"))
            }
            let recent = Array(msgs.suffix(6))
            DispatchQueue.main.async { completion(recent.isEmpty ? .notice("No messages yet.", action: nil) : .messages(recent)) }
        }
    }
}

// MARK: - Messages

/// Your recent conversations in Messages, sent to through Messages' own AppleScript support —
/// in the background, without opening a Messages window. macOS asks once for permission.
final class MessagesChats: SessionSource {
    static let shared = MessagesChats()
    let bundleID = "com.apple.MobileSMS"
    let heading = "Conversations"

    private(set) var projects: [SessionProject] = []
    private var lastReplied: String?
    private let queue = DispatchQueue(label: "mono.messages", qos: .utility)
    private var scanning = false

    /// Whoever messaged you last is who you most likely want to answer.
    var defaultReplyTarget: AgentSession? {
        all.first { lastIncoming != nil && Self.key($0.ref) == lastIncoming }
            ?? all.first { $0.id == lastReplied } ?? all.first
    }

    private var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Can Mono Dock read Messages' database (Full Disk Access)? nil until we've tried.
    private(set) var hasAccess: Bool?
    private var lastIncoming: String?                 // key(...) of the chat that last messaged you
    private var lastRowID: Int64 = -1                 // queue only
    private var toldAboutAccess = false

    func start() {
        scan()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.scan() }
        watchIncoming()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.watchIncoming() }
    }

    // MARK: New-message alerts

    private struct Incoming { let chat: String; let handle: String; let text: String }

    /// Checks for messages that arrived since the last look (a cheap query every few seconds).
    private func watchIncoming() {
        queue.async { [weak self] in
            guard let self else { return }
            var fresh: [Incoming] = []
            let ok: Bool? = self.withDB { db -> Bool? in
                if self.lastRowID < 0 {
                    _ = self.query(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message") { self.lastRowID = sqlite3_column_int64($0, 0) }
                    return true
                }
                var maxSeen = self.lastRowID
                let worked = self.query(db, """
                    SELECT m.ROWID, c.guid, IFNULL(h.id, ''), m.text, m.attributedBody FROM message m
                    JOIN chat_message_join j ON j.message_id = m.ROWID
                    JOIN chat c ON c.ROWID = j.chat_id
                    LEFT JOIN handle h ON h.ROWID = m.handle_id
                    WHERE m.ROWID > ?1 AND m.is_from_me = 0 AND m.item_type = 0
                      AND IFNULL(m.associated_message_type, 0) = 0
                    ORDER BY m.ROWID LIMIT 10
                    """, bind: [String(self.lastRowID)]) { st in
                    maxSeen = max(maxSeen, sqlite3_column_int64(st, 0))
                    var text = sqlite3_column_text(st, 3).map { String(cString: $0) } ?? ""
                    if text.isEmpty, let blob = sqlite3_column_blob(st, 4) {
                        text = Self.decodeBody(Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 4)))) ?? ""
                    }
                    text = text.replacingOccurrences(of: "\u{FFFC}", with: "📎").trimmingCharacters(in: .whitespacesAndNewlines)
                    fresh.append(Incoming(chat: Self.key(String(cString: sqlite3_column_text(st, 1))),
                                          handle: String(cString: sqlite3_column_text(st, 2)),
                                          text: text.isEmpty ? "Sent an attachment" : text))
                }
                self.lastRowID = maxSeen
                return worked
            }
            let access = ok ?? false
            DispatchQueue.main.async { self.deliver(fresh, access: access) }
        }
    }

    private func deliver(_ fresh: [Incoming], access: Bool) {
        hasAccess = access
        if !access {
            if !toldAboutAccess {
                toldAboutAccess = true
                Banner.shared.show(icon: Assistant.icon(bundleID), title: "Mono Dock can't see new messages",
                                   body: "Turn on Mono Dock under Full Disk Access to get message alerts and previews here.") {
                    NSWorkspace.shared.open(Self.fullDiskAccessURL)
                }
            }
            return
        }
        guard let last = fresh.last else { return }
        lastIncoming = last.chat
        let chat = all.first { Self.key($0.ref) == last.chat }
        let who = queueNames(chatID: chat?.id, handle: last.handle) ?? chat?.title ?? last.handle
        let group = (names[chat?.id ?? ""]?.count ?? 0) > 1
        let title = group ? "\(who) · \(chat?.title ?? "")" : who
        let more = fresh.count > 1 ? " (+\(fresh.count - 1) more)" : ""
        Banner.shared.show(icon: Assistant.icon(bundleID), title: title, body: last.text + more) {
            // Open the Messages widget with this conversation ready to reply to.
            guard let app = Tracker.shared.orderedApps.first(where: { $0.app.bundleIdentifier == self.bundleID }) else { return }
            HoverPreview.shared.pin(app, on: NSScreen.screens.first ?? NSScreen.underMouse)
        }
        scan()                                        // refresh unread counts and order
    }

    private func queueNames(chatID: String?, handle: String) -> String? {
        guard let chatID else { return nil }
        return names[chatID]?[handle]
    }

    func scan() {
        guard !scanning, running else { return }       // never launch Messages just to look
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let script = """
            tell application "Messages"
              set out to ""
              set n to 0
              repeat with c in chats
                set n to n + 1
                if n > 12 then exit repeat
                set nm to ""
                try
                  set nm to name of c
                end try
                if nm is missing value then set nm to ""
                set ps to ""
                set hs to ""
                try
                  repeat with p in participants of c
                    set pn to ""
                    try
                      set pn to full name of p
                    end try
                    set hd to ""
                    try
                      set hd to handle of p
                    end try
                    if pn is missing value or pn is "" then set pn to hd
                    set ps to ps & pn & ", "
                    set hs to hs & hd & "=" & pn & ";"
                  end repeat
                end try
                set out to out & (id of c) & tab & nm & tab & ps & tab & hs & linefeed
              end repeat
              return out
            end tell
            """
            let result = Self.osascript(script, args: [])
            var sessions: [AgentSession] = []
            let unread = self.unreadCounts()
            for line in (result.output ?? "").split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3, !parts[0].isEmpty else { continue }
                var people = parts[2]
                if people.hasSuffix(", ") { people.removeLast(2) }
                let title = parts[1].isEmpty ? (people.isEmpty ? "Conversation" : people) : parts[1]
                if parts.count >= 4 {
                    var map: [String: String] = [:]
                    for pair in parts[3].split(separator: ";") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2, !kv[0].isEmpty { map[kv[0]] = kv[1] }
                    }
                    self.names[parts[0]] = map
                }
                let n = unread?[Self.key(parts[0])] ?? 0
                sessions.append(AgentSession(id: parts[0], title: title, status: n > 0 ? .unread : .other, project: "Recent", ref: parts[0]))
            }
            DispatchQueue.main.async {
                self.scanning = false
                guard result.ok else { return }
                let changed = sessions.map(\.id) != self.projects.first?.sessions.map(\.id) ?? []
                    || sessions.map(\.title) != self.projects.first?.sessions.map(\.title) ?? []
                self.projects = sessions.isEmpty ? [] : [SessionProject(name: "Recent", newSession: nil, sessions: sessions)]
                if changed { Tracker.shared.bump(force: true) }
            }
        }
    }

    func open(_ s: AgentSession) {
        // One-to-one chats can be opened directly; group chats just bring Messages up.
        if let handle = s.ref.components(separatedBy: ";-;").dropFirst().first, let url = URL(string: "sms:\(handle)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            Steer.bringForward(app, window: nil)
        }
    }

    func send(_ text: String, to s: AgentSession) {
        lastReplied = s.id
        queue.async {
            // Text and chat id go in as arguments, never spliced into the script.
            let r = Self.osascript("""
            on run argv
              tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv)
            end run
            """, args: [text, s.ref])
            if !r.ok {
                NSLog("Mono Dock: Messages send failed: \(r.error ?? "")")
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    func newSession(in p: SessionProject) {}

    func placeholder(for s: AgentSession) -> String { "Message \(s.title)…" }

    // MARK: Message history (Messages' own database; needs Full Disk Access)

    private var names: [String: [String: String]] = [:]   // chat id → handle → name (queue only)
    private static let dbPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Chat ids differ in prefix between AppleScript ("iMessage;-;+1…") and the database ("any;-;+1…").
    static func key(_ chatID: String) -> String {
        for sep in [";-;", ";+;"] { if let r = chatID.range(of: sep) { return String(chatID[r.upperBound...]) } }
        return chatID
    }

    private func withDB<T>(_ body: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        return body(db)
    }

    private func query(_ db: OpaquePointer, _ sql: String, bind: [String] = [], row: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in bind.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        return true
    }

    /// Unread incoming messages per conversation (keyed by `key(_:)`), or nil without access.
    private func unreadCounts() -> [String: Int]? {
        withDB { db -> [String: Int]? in
            var out: [String: Int] = [:]
            let ok = query(db, """
                SELECT c.guid, COUNT(*) FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                JOIN chat c ON c.ROWID = j.chat_id
                WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0
                  AND m.date > (strftime('%s','now') - 978307200 - 1209600) * 1000000000
                GROUP BY c.guid
                """) { stmt in
                if let g = sqlite3_column_text(stmt, 0) { out[Self.key(String(cString: g))] = Int(sqlite3_column_int(stmt, 1)) }
            }
            return ok ? out : nil
        }
    }

    func context(for s: AgentSession, explicit: Bool, completion: @escaping (ContextResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let names = self.names[s.id] ?? [:]
            let group = names.count > 1
            let msgs: [ContextMessage]? = self.withDB { db -> [ContextMessage]? in
                var rows: [ContextMessage] = []
                let ok = self.query(db, """
                    SELECT m.text, m.attributedBody, m.is_from_me, h.id FROM message m
                    JOIN chat_message_join j ON j.message_id = m.ROWID
                    JOIN chat c ON c.ROWID = j.chat_id
                    LEFT JOIN handle h ON h.ROWID = m.handle_id
                    WHERE (c.guid = ?1 OR c.guid LIKE '%;' || ?2) AND m.item_type = 0
                      AND IFNULL(m.associated_message_type, 0) = 0
                    ORDER BY m.date DESC LIMIT 12
                    """, bind: [s.ref, Self.key(s.ref)]) { stmt in
                    var text = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    if text.isEmpty, let blob = sqlite3_column_blob(stmt, 1) {
                        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
                        text = Self.decodeBody(data) ?? ""
                    }
                    text = text.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    let me = sqlite3_column_int(stmt, 2) == 1
                    let handle = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                    let from = me ? "You" : (group ? (names[handle] ?? handle) : s.title)
                    rows.append(ContextMessage(from: from, text: String(text.prefix(1000)), isMe: me))
                }
                return ok ? rows.reversed() : nil
            }
            DispatchQueue.main.async {
                if let msgs {
                    completion(msgs.isEmpty ? .notice("No recent messages.", action: nil) : .messages(msgs))
                } else {
                    completion(.notice("To show messages here, give Mono Dock Full Disk Access.",
                                       action: ("Open Settings", Self.fullDiskAccessURL)))
                }
            }
        }
    }

    /// Newer messages keep their text only in a packed "attributed string" blob.
    private static func decodeBody(_ data: Data) -> String? {
        if let s = (try? NSUnarchiver.unarchiveObject(with: data)) as? NSAttributedString { return s.string }
        if let s = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString { return s.string }
        return nil
    }

    static func osascript(_ script: String, args: [String]) -> (ok: Bool, output: String?, error: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, nil, "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self), e)
    }
}
