import AppKit
import FoundationModels
import SwiftUI

/// Mono — the dock's on-device assistant, running on Apple's built-in language model.
/// Free, private (nothing leaves the Mac), and wired to the dock's bridges as tools.
/// It never sends anything itself: it writes drafts you approve with one click.
@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()

    struct Draft: Identifiable {
        let id = UUID()
        let session: AgentSession
        let source: SessionSource
        var text: String
        var app: String { Assistant.appName(source) }
    }

    /// One question and Mono's reply, shown as a short thread.
    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var reply: String?
    }
    @Published var thread: [Exchange] = []

    /// Mono's latest reply (fills in the newest exchange).
    var answer: String {
        get { thread.last?.reply ?? "" }
        set {
            guard !newValue.isEmpty else { return }
            if thread.isEmpty || thread[thread.count - 1].reply != nil { thread.append(Exchange(question: "", reply: newValue)) }
            else { thread[thread.count - 1].reply = newValue }
        }
    }
    @Published var thinking = false
    @Published var drafts: [Draft] = []
    /// One-line "where things stand" for conversations waiting on you, keyed by session id.
    @Published var summaries: [String: String] = [:]

    /// What you've pointed Mono at, so it doesn't have to guess.
    enum Attachment: Identifiable {
        case conversation(AgentSession, SessionSource)
        case app(SessionSource)
        var id: String {
            switch self {
            case .conversation(let s, _): return "c:" + s.id
            case .app(let src): return "a:" + src.bundleID
            }
        }
        var label: String {
            switch self {
            case .conversation(let s, let src): return "\(s.title) · \(Assistant.appName(src))"
            case .app(let src): return Assistant.appName(src)
            }
        }
    }
    @Published var attached: [Attachment] = []

    func attach(_ a: Attachment) {
        if !attached.contains(where: { $0.id == a.id }) { attached.append(a) }
    }

    func detach(_ id: String) { attached.removeAll { $0.id == id } }

    /// The single conversation Mono is working on, if you attached exactly one.
    private var focus: (AgentSession, SessionSource)? {
        guard attached.count == 1, case .conversation(let s, let src) = attached[0] else { return nil }
        return (s, src)
    }

    /// Numbered list of conversations the model is currently referring to.
    private(set) var index: [(AgentSession, SessionSource)] = []

    var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return "Apple Intelligence isn't available (\(reason)). Turn it on in System Settings → Apple Intelligence & Siri."
        }
    }

    nonisolated static func appName(_ s: SessionSource) -> String {
        s is Sessions ? "Claude" : s is CodexSessions ? "Codex" : s is ChromeTabs ? "Chrome" : "Messages"
    }

    private static let instructions = """
        You are Mono, the assistant built into the user's macOS dock. You help them stay on top of their \
        apps, AI agent sessions (Claude, Codex) and Messages conversations, and arrange their windows.
        Each request comes with the current numbered conversations and apps. Only call draftMessage when \
        the user asks you to reply, send, tell, text or message someone — use the conversation's number, \
        and the text the user wants sent. For questions, just answer. The user reviews drafts before sending; \
        never say a message was sent. Answer in one or two short sentences, plain text.
        """

    private static let focusedInstructions = """
        You are Mono, the assistant built into the user's macOS dock. The user has pointed you at one \
        conversation, shown with its latest messages. Answer the user's question about it briefly and \
        concretely, using the messages. You are talking to the user, not writing a message for them. \
        One to three short sentences, plain text.
        """

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(tools: [DraftMessageTool(), OpenConversationTool(), ArrangeWindowsTool(), FocusAppTool()],
                             instructions: Self.instructions)
    }

    /// A session with the model already loaded, so answers come back in about a second.
    private var warm: LanguageModelSession?

    func prewarm() {
        guard availability == nil, warm == nil else { return }
        let s = makeSession()
        s.prewarm()
        warm = s
    }

    // MARK: Asking

    enum Mode { case message, ask }

    /// Message: your words become a draft to the attached conversation — no AI involved.
    /// Ask: Mono answers; it can't create drafts in this mode.
    func ask(_ request: String, raw: Bool = false, mode: Mode = .ask, shown: String? = nil) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !thinking else { return }
        thread.append(Exchange(question: shown ?? request, reply: nil))
        if thread.count > 5 { thread.removeFirst(thread.count - 5) }
        refreshIndex()
        let focus = raw ? nil : self.focus
        if mode == .message, let (conv, src) = focus {
            putDraft(Draft(session: conv, source: src, text: request))
            answer = "Ready to send to \(conv.title). Check it, then press Send."
            return
        }
        if let problem = availability { answer = problem; return }
        let draftsBefore = drafts.count
        thinking = true
        Task {
            let session: LanguageModelSession
            let prompt: String
            if let (conv, src) = focus {
                // Pointed at one conversation: give Mono its messages, and a tool that can only reply there.
                focusTarget = (conv, src)
                let ctx = await Self.context(src, conv, explicit: true)
                let messages = { if case .messages(let m) = ctx { return Self.transcript(m) }; return "(no messages loaded)" }()
                session = LanguageModelSession(tools: [ArrangeWindowsTool(), FocusAppTool()],
                                               instructions: Self.focusedInstructions)
                prompt = "Conversation \"\(conv.title)\" in \(Self.appName(src)):\n\(messages)\n\nRequest: \(request)"
            } else {
                // Everything Mono needs is in the request itself: no lookup round trips.
                session = warm ?? makeSession()
                warm = nil
                prompt = raw ? request : "\(Self.snapshot())\n\nRequest: \(request)"
            }
            do {
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                answer = drafts.count > draftsBefore ? "Draft ready below. Review it, then send." : text
            } catch {
                answer = "Mono couldn't do that: \(error.localizedDescription)"
            }
            thinking = false
            prewarm()
        }
    }

    private var focusTarget: (AgentSession, SessionSource)?

    /// "on my way, 10 min" is a message; "what did she ask?" or "summarize this" is a question for Mono.
    static func looksLikeMessage(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix("?") { return false }
        let first = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
        let askWords: Set<String> = ["what", "whats", "what's", "why", "how", "when", "who", "where", "which",
                                     "is", "are", "did", "does", "do", "can", "could", "should", "would",
                                     "summarize", "summarise", "summary", "explain", "show", "list", "tile",
                                     "open", "draft", "reply", "respond", "write", "suggest", "tell", "remind", "catch"]
        return !askWords.contains(first)
    }

    func addFocusedDraft(_ text: String) -> String {
        guard let (s, src) = focusTarget else { return "No conversation is attached." }
        putDraft(Draft(session: s, source: src, text: text))
        return "Draft ready for the user to review."
    }

    /// At most one draft per conversation: a newer one replaces it.
    private func putDraft(_ d: Draft) {
        drafts.removeAll { $0.session.id == d.session.id }
        drafts.append(d)
    }

    static func context(_ src: SessionSource, _ s: AgentSession, explicit: Bool) async -> ContextResult {
        await withCheckedContinuation { c in src.context(for: s, explicit: explicit) { c.resume(returning: $0) } }
    }

    // MARK: Auto-summaries of conversations waiting on you

    private var summarySignature: [String: String] = [:]
    private var summaryStatus: [String: AgentSession.Status] = [:]
    private var summarizing = false

    func startAutoSummaries() {
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { _ in
            MainActor.assumeIsolated { Assistant.shared.refreshSummaries() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Assistant.shared.refreshSummaries() }
    }

    func refreshSummaries() {
        guard availability == nil, !summarizing, !thinking else { return }
        let waiting = Sources.all.flatMap { src in src.all.filter { $0.status.wantsYou }.prefix(4).map { ($0, src) } }
        guard !waiting.isEmpty else { return }
        summarizing = true
        Task {
            for (s, src) in waiting {
                guard case .messages(let m) = await Self.context(src, s, explicit: false), let last = m.last else { continue }
                let sig = last.from + last.text
                guard summarySignature[s.id] != sig else { continue }
                guard let b = await brief(m, title: s.title) else { continue }
                summaries[s.id] = b.line
                summarySignature[s.id] = sig
                Tracker.shared.bump(force: true)
            }
            summarizing = false
        }
    }

    /// A short, prioritized rundown of what needs attention, built from what the dock can see.
    func whatNeedsMe() {
        refreshIndex()
        let prompt = """
            Here is what the dock sees right now:
            \(Self.snapshot())
            In at most 4 short bullet points, tell the user what needs their attention first. \
            Sessions waiting for input and unread badges come first; running work second. \
            If nothing needs them, say so in one line. Don't draft any messages.
            """
        ask(prompt, raw: true, shown: "What needs me?")
    }

    // MARK: Conversation context

    /// Oldest → newest, the user labeled "Me", the last message marked, trimmed to fit the model's budget.
    private static func transcript(_ msgs: [ContextMessage]) -> String {
        var lines = msgs.enumerated().map { i, m in
            (m.isMe ? "Me" : m.from) + (i == msgs.count - 1 ? " (latest)" : "") + ": " + m.text
        }
        while lines.joined(separator: "\n").count > 5000, lines.count > 2 { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    private func oneShot(_ instructions: String, _ prompt: String) async -> String {
        if let problem = availability { return problem }
        do {
            return try await LanguageModelSession(instructions: instructions).respond(to: prompt).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Mono couldn't do that: \(error.localizedDescription)"
        }
    }

    /// Nudge: a suggested reply for the attached conversation, for you to edit and send.
    func suggestForFocus() async -> String? {
        guard let (conv, src) = focus else { return nil }
        guard case .messages(let m) = await Self.context(src, conv, explicit: true) else { return nil }
        return await suggestReply(m, title: conv.title, toAgent: !(src is MessagesChats))
    }

    var focusedConversation: (AgentSession, SessionSource)? { focus }

    /// Answer a search from the top result pages, citing which pages it used.
    func searchAnswer(query: String, pages: [PageDigest]) async -> SearchAnswer? {
        guard availability == nil, !pages.isEmpty else { return nil }
        var sources = ""
        for (i, p) in pages.enumerated() {
            var body = p.description
            if let r = p.recipe {
                body += "\nRecipe: " + [r.time.map { "time \($0)" }, r.servings.map { "makes \($0)" }].compactMap { $0 }.joined(separator: ", ")
                body += "\nIngredients: " + r.ingredients.prefix(14).joined(separator: "; ")
                body += "\nSteps: " + r.steps.prefix(6).joined(separator: " ")
            }
            for t in p.text where body.count < 1300 { body += "\n" + t }
            sources += "[\(i + 1)] \(p.title) (\(p.site))\n\(String(body.prefix(1400)))\n\n"
        }
        let session = LanguageModelSession(instructions: """
            You answer a web search using only the numbered sources given. Be direct and specific, like a knowledgeable \
            friend: lead with the answer, then the key details. Under 70 words. If the sources don't answer it, say so. \
            List the numbers of the sources you used.
            """)
        do {
            return try await session.respond(to: "Search: \(query)\n\nSources:\n\(sources)", generating: SearchAnswer.self,
                                             options: GenerationOptions(sampling: .greedy)).content
        } catch {
            return nil
        }
    }

    /// What a web page offers for what you searched — a few short, concrete points.
    func linkPeek(query: String, page: PageDigest) async -> String {
        var body = page.description
        for t in page.text where body.count < 2200 { body += "\n" + t }
        return await oneShot("You preview web pages for someone deciding which search result to open. " +
                             "Give 2 to 4 very short lines (under 12 words each), each starting with •, with the " +
                             "specific facts most useful for their search. No preamble.",
                             "Search: \(query)\nPage: \(page.title) (\(page.site))\n\(String(body.prefix(2400)))")
    }

    func summarize(_ msgs: [ContextMessage], title: String) async -> String {
        guard let b = await brief(msgs, title: title) else {
            return await oneShot("Summarize this conversation for the user (\"Me\") in one or two concrete sentences.",
                                 "Conversation \"\(title)\":\n\(Self.transcript(msgs))")
        }
        return b.full
    }

    /// A structured read of a conversation: where it stands, what (if anything) is asked of you, and the gist.
    func brief(_ msgs: [ContextMessage], title: String) async -> ChatBrief? {
        guard availability == nil, !msgs.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: Self.briefInstructions)
        do {
            // Point the model at exactly where any ask can come from: their messages since Me last wrote.
            let sinceMe = msgs.reversed().prefix { !$0.isMe }.reversed().map { "\($0.from): \($0.text)" }
            let prompt = "Conversation \"\(title)\":\n\(Self.transcript(msgs))\n\n" +
                (sinceMe.isEmpty ? "Me wrote last, so there is no ask." : "Their messages since Me last wrote (the ask can only come from these):\n" + sinceMe.joined(separator: "\n"))
            let d = try await session.respond(to: prompt,
                                              generating: ChatBriefDraft.self,
                                              options: GenerationOptions(sampling: .greedy)).content
            // Where it stands: decided by rules about the last message, not guessed by the model.
            return ChatBrief(ask: d.ask, gist: d.gist, state: ChatBrief.state(of: msgs, ask: d.ask))
        } catch {
            return nil
        }
    }

    private static let briefInstructions = """
        You read a conversation for the user, who appears as "Me". Report only what is written in the messages. \
        "ask": what the other side most recently asked or requested of Me, restated as a short instruction that keeps \
        every specific (amounts, dates, times, names, links). If they asked nothing, leave it empty. \
        "gist": the concrete point of the conversation. Never guess, never add details, never be vague.
        """

    func suggestReply(_ msgs: [ContextMessage], title: String, toAgent: Bool) async -> String {
        let who = toAgent ? "an AI coding agent working for the user" : "a person the user is texting"
        return await oneShot("You write the user's next message to \(who). Match the conversation's tone and language. " +
                             "Reply with only the message text, short, no quotes.",
                             "Conversation \"\(title)\":\n\(Self.transcript(msgs))\n\nThe user's next message:")
    }

    // MARK: Drafts

    func addDraft(number: Int, text: String) -> String {
        guard number >= 1, number <= index.count else { return "There's no conversation number \(number)." }
        let (session, source) = index[number - 1]
        putDraft(Draft(session: session, source: source, text: text))
        return "Draft to \(session.title) in \(Self.appName(source)) is ready for the user to review."
    }

    func send(_ d: Draft) {
        d.source.send(d.text, to: d.session)
        drafts.removeAll { $0.id == d.id }
    }

    func discard(_ d: Draft) { drafts.removeAll { $0.id == d.id } }

    func update(_ d: Draft, text: String) {
        if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i].text = text }
    }

    // MARK: What the model can see

    func refreshIndex() {
        guard !attached.isEmpty else {
            index = Sources.all.flatMap { source in source.all.prefix(12).map { ($0, source) } }
            return
        }
        var out: [(AgentSession, SessionSource)] = []
        for a in attached {
            switch a {
            case .conversation(let s, let src): out.append((s, src))
            case .app(let src): out += src.all.prefix(12).map { ($0, src) }
            }
        }
        index = out
    }

    // MARK: @-mentions and the + menu

    struct Mention: Identifiable {
        let id: String
        let label: String
        let detail: String
        let attachment: Attachment
        /// What picking it means, in plain words ("Message Sam").
        let action: String
        let bundleID: String
    }

    nonisolated static func icon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Apps and conversations you can point Mono at, filtered by what you typed after "@".
    func mentions(matching query: String) -> [Mention] {
        var all: [Mention] = []
        for src in Sources.all where !src.projects.isEmpty {
            let app = Self.appName(src)
            let alias = src is CodexSessions ? "Codex · ChatGPT" : app
            all.append(Mention(id: "a:" + src.bundleID, label: alias, detail: "all \(src.heading.lowercased())",
                               attachment: .app(src), action: "Ask about all \(app) \(src.heading.lowercased())", bundleID: src.bundleID))
            for s in src.all.prefix(15) {
                let where_ = s.project == "Recent" ? app : "\(app) · \(s.project)"
                let verb = src is MessagesChats ? "Message" : src is ChromeTabs ? "Open tab" : "Reply in"
                all.append(Mention(id: "c:" + s.id, label: s.title, detail: where_, attachment: .conversation(s, src),
                                   action: "\(verb) \(s.title)", bundleID: src.bundleID))
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var hits = q.isEmpty ? all : all.filter { ($0.label + " " + $0.detail).lowercased().contains(q) }
        if !q.isEmpty {
            // Best first: names that start with what you typed, then one-to-one chats over groups.
            func rank(_ m: Mention) -> Int {
                let l = m.label.lowercased()
                return (l.hasPrefix(q) ? 0 : l.contains(" " + q) ? 1 : 2) * 10 + min(l.filter { $0 == "," }.count, 9)
            }
            hits = hits.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        }
        return Array(hits.filter { m in !attached.contains { $0.id == m.id } }.prefix(7))
    }

    func conversationList() -> String {
        guard !index.isEmpty else { return "No conversations are available." }
        return index.enumerated().map { i, pair in
            let (s, src) = pair
            let status = s.status == .other ? "" : " · \(s.status.rawValue.lowercased())"
            let summary = summaries[s.id].map { " — \($0)" } ?? ""
            return "\(i + 1). [\(Self.appName(src))\(status)] \(s.title)" + (s.project == "Recent" ? "" : " (\(s.project))") + summary
        }.joined(separator: "\n")
    }

    static func appList() -> String {
        Tracker.shared.orderedApps.map { a in
            var bits = ["\(a.windows.filter { !$0.minimized }.count) windows"]
            if let b = a.badge { bits.append("\(b) unread") }
            if a.playingAudio { bits.append("playing audio") }
            if a.busy { bits.append("busy") }
            if a.hidden { bits.append("hidden") }
            if a.pid == Tracker.shared.frontPID { bits.append("in front") }
            return "\(a.name): " + bits.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    static func snapshot() -> String {
        "Conversations:\n\(shared.conversationList())\n\nApps:\n\(appList())"
    }

    func open(number: Int) -> String {
        guard number >= 1, number <= index.count else { return "There's no conversation number \(number)." }
        let (s, src) = index[number - 1]
        src.open(s)
        return "Opened \(s.title)."
    }
}

// MARK: - Tools (the bridges, as the model sees them)

struct ListConversationsTool: Tool {
    let name = "listConversations"
    let description = "Lists the user's Claude sessions, Codex threads and recent Messages conversations, numbered, with status."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { Assistant.shared.refreshIndex(); return Assistant.shared.conversationList() }
    }
}

struct ListAppsTool: Tool {
    let name = "listApps"
    let description = "Lists running apps with window counts, unread badges, and whether they're busy or playing audio."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { Assistant.appList() }
    }
}

struct DraftMessageTool: Tool {
    let name = "draftMessage"
    let description = "Writes a message to a conversation (a person in Messages, or a Claude/Codex agent session) for the user to review and send."
    @Generable struct Arguments {
        @Guide(description: "The conversation's number from listConversations")
        var number: Int
        @Guide(description: "The message text, written as the user would send it")
        var text: String
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { Assistant.shared.addDraft(number: arguments.number, text: arguments.text) }
    }
}

struct DraftReplyTool: Tool {
    let name = "draftReply"
    let description = "Writes a reply in the attached conversation for the user to review and send."
    @Generable struct Arguments {
        @Guide(description: "The exact message text to send")
        var text: String
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { Assistant.shared.addFocusedDraft(arguments.text) }
    }
}

struct OpenConversationTool: Tool {
    let name = "openConversation"
    let description = "Opens a conversation in its app so the user can see it."
    @Generable struct Arguments {
        @Guide(description: "The conversation's number from listConversations")
        var number: Int
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { Assistant.shared.open(number: arguments.number) }
    }
}

struct ArrangeWindowsTool: Tool {
    let name = "arrangeWindows"
    let description = "Arranges windows: tile every window on the current display into a grid, or put the front window on the left half, right half, or maximized."
    @Generable enum Action { case tile, leftHalf, rightHalf, maximize }
    @Generable struct Arguments {
        var action: Action
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            switch arguments.action {
            case .tile: Steer.tile(currentScreen()); return "Tiled the windows on this display."
            case .leftHalf: Steer.front(.left); return "Moved the front window to the left half."
            case .rightHalf: Steer.front(.right); return "Moved the front window to the right half."
            case .maximize: Steer.front(.maximize); return "Maximized the front window."
            }
        }
    }
}

struct FocusAppTool: Tool {
    let name = "focusApp"
    let description = "Brings a running app to the front."
    @Generable struct Arguments {
        @Guide(description: "The app's name, e.g. Safari or Messages")
        var app: String
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let want = arguments.app.lowercased()
            guard let a = Tracker.shared.orderedApps.first(where: { $0.name.lowercased() == want })
                    ?? Tracker.shared.orderedApps.first(where: { $0.name.lowercased().contains(want) }) else {
                return "\(arguments.app) isn't running."
            }
            Steer.click(a, on: currentScreen())
            return "Brought \(a.name) to the front."
        }
    }
}

// MARK: - Panel

@MainActor
final class AssistantPanel {
    static let shared = AssistantPanel()
    private var panel: KeyablePanel?

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() { isShown ? hide() : show() }

    func show() {
        HoverPreview.shared.hide(now: true)
        let screen = currentScreen()
        let p = panel ?? {
            let p = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = FirstMouseHostingView(rootView: AssistantView())
            return p
        }()
        panel = p
        relayout(on: screen)
        p.orderFrontRegardless()
        p.makeKey()
        Assistant.shared.prewarm()
    }

    func relayout(on screen: NSScreen? = nil) {
        guard let p = panel, let v = p.contentView else { return }
        let screen = screen ?? p.screen ?? currentScreen()
        let size = v.fittingSize
        let vf = screen.visibleFrame
        let frame = NSRect(x: (vf.midX - size.width / 2).rounded(), y: DockController.shared.dockTop(for: screen) - 2,
                           width: size.width, height: size.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    func hide() { panel?.orderOut(nil) }
}

struct AssistantView: View {
    @ObservedObject private var mono = Assistant.shared
    @State private var prompt = ""
    @State private var highlighted = 0
    @State private var chosenMode: Assistant.Mode?      // set when you click the switch; otherwise it follows your text
    @State private var suggesting = false
    @FocusState private var focused: Bool

    /// Message mode only makes sense with one conversation attached.
    private var canMessage: Bool { mono.focusedConversation != nil }

    private var mode: Assistant.Mode {
        guard canMessage else { return .ask }
        if let chosenMode { return chosenMode }
        return prompt.isEmpty || Assistant.looksLikeMessage(prompt) ? .message : .ask
    }

    /// Text typed after the last "@", while you're picking something to mention.
    private var mentionQuery: String? {
        guard let at = prompt.lastIndex(of: "@") else { return nil }
        let before = prompt[..<at]
        guard before.isEmpty || before.last == " " else { return nil }       // "@" must start a word
        let q = String(prompt[prompt.index(after: at)...])
        return q.count > 40 ? nil : q
    }

    private var suggestions: [Assistant.Mention] {
        mentionQuery.map { mono.mentions(matching: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) { Pinwheel(size: 16, spinning: mono.thinking); Text("Mono").font(.system(size: 13, weight: .semibold)) }
                Spacer()
                Button("What needs me?") { mono.whatNeedsMe() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.primary.opacity(0.08)))
                    .disabled(mono.thinking)
                Button { AssistantPanel.shared.hide() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            if !mono.attached.isEmpty {
                FlowChips(items: mono.attached.map { ($0.id, $0.label) }) { mono.detach($0) }
            }

            if let problem = mono.availability {
                Text(problem).font(.system(size: 12)).foregroundStyle(.orange)
            }

            if !mono.thread.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(mono.thread) { ex in
                            if !ex.question.isEmpty {
                                HStack {
                                    Spacer(minLength: 60)
                                    Text(ex.question).font(.system(size: 12)).foregroundStyle(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor))
                                        .textSelection(.enabled)
                                }
                            }
                            if let reply = ex.reply {
                                HStack(alignment: .top, spacing: 6) {
                                    Pinwheel(size: 13, spinning: false).padding(.top, 2)
                                    Text(reply).font(.system(size: 12)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if ex.id == mono.thread.last?.id, mono.thinking {
                                HStack(spacing: 6) {
                                    Pinwheel(size: 13, spinning: true)
                                    Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(mono.drafts) { d in DraftCard(draft: d) }

            if canMessage, prompt.isEmpty, !mono.thinking {
                HStack(spacing: 6) {
                    Nudge("Catch me up") { run("Catch me up: where does this conversation stand?", shown: "Catch me up") }
                    Nudge("What do they want?") { run("What is the other side asking me for, if anything?", shown: "What do they want?") }
                    Nudge(suggesting ? "Writing…" : "Suggest a reply") {
                        suggesting = true
                        Task {
                            if let text = await mono.suggestForFocus() { prompt = text; chosenMode = .message }
                            suggesting = false
                            focused = true
                        }
                    }
                    Spacer()
                }
            }

            if let q = mentionQuery, !suggestions.isEmpty || !q.contains(" ") {
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestions.isEmpty ? "No matches" : "Choose who or what — Return to confirm")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, m in
                        HStack(spacing: 9) {
                            if let icon = Assistant.icon(m.bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(m.action).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(m.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if i == highlighted {
                                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == highlighted ? Color.accentColor.opacity(0.2) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { pick(m) }
                        .onHover { if $0 { highlighted = i } }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.06)))
            }

            HStack(spacing: 6) {
                AttachMenu()
                TextField(placeholder, text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { suggestions.isEmpty ? AssistantPanel.shared.hide() : clearMention() }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.tab) { if let m = suggestions[safe: highlighted] { pick(m); return .handled }; return .ignored }
                if canMessage {
                    ModeSwitch(mode: mode) { chosenMode = mode == .message ? .ask : .message }
                }
                Button(action: submit) {
                    Group {
                        if mode == .ask { Pinwheel(size: 16, spinning: mono.thinking) }
                        else { Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) }
                    }
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(mode == .ask ? Color.primary.opacity(0.08) : Color.accentColor))
                    .opacity(prompt.isEmpty ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(prompt.isEmpty || mono.thinking)
                .help(mode == .ask ? "Ask Mono (Return)" : "Make a draft to send (Return)")
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06)))
        }
        .padding(12)
        .frame(width: 440)
        .modifier(Glass(cornerRadius: 16))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: prompt) { _, _ in highlighted = 0; relayout() }
        .onChange(of: mono.thread.count) { _, _ in relayout() }
        .onChange(of: mono.answer) { _, _ in relayout() }
        .onChange(of: mono.thinking) { _, _ in relayout() }
        .onChange(of: mono.drafts.count) { _, _ in relayout() }
        .onChange(of: mono.attached.count) { _, _ in relayout() }
    }

    private func relayout() { DispatchQueue.main.async { AssistantPanel.shared.relayout() } }

    private var placeholder: String {
        if let (s, src) = mono.focusedConversation {
            if chosenMode == .ask { return "Ask about \(s.title)…" }
            return src is MessagesChats ? "Message \(s.title)…  (end with ? to ask instead)" : "Reply in \(s.title)…  (end with ? to ask instead)"
        }
        return mono.attached.isEmpty ? "Type @ to message someone or ask about an app…" : "Ask about what's attached…"
    }

    private func move(_ d: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + d + suggestions.count) % suggestions.count
        return .handled
    }

    private func submit() {
        if let m = suggestions[safe: highlighted] { pick(m); return }     // Return picks the highlighted mention
        resolveTypedMention()
        mono.ask(prompt, mode: mode)
        prompt = ""
        chosenMode = nil
    }

    private func run(_ question: String, shown: String? = nil) { mono.ask(question, mode: .ask, shown: shown) }

    /// "@mika on my way" typed in one go: find the longest start that names someone, attach them,
    /// and keep the rest as the message.
    private func resolveTypedMention() {
        guard let at = prompt.lastIndex(of: "@") else { return }
        let before = String(prompt[..<at])
        let words = prompt[prompt.index(after: at)...].split(separator: " ").map(String.init)
        for n in stride(from: min(words.count, 5), to: 0, by: -1) {
            let hits = mono.mentions(matching: words.prefix(n).joined(separator: " "))
            if let best = hits.first(where: { !$0.id.hasPrefix("a:") }) ?? hits.first {
                mono.attach(best.attachment)
                prompt = (before + words.dropFirst(n).joined(separator: " ")).trimmingCharacters(in: .whitespaces)
                return
            }
        }
    }

    /// Attach the mention and take the "@query" back out of the text.
    private func pick(_ m: Assistant.Mention) {
        mono.attach(m.attachment)
        clearMention()
        focused = true
    }

    private func clearMention() {
        if let at = prompt.lastIndex(of: "@") { prompt = String(prompt[..<at]) }
    }
}

/// Shows whether Return will make a draft (Message) or ask Mono (Ask). Click to flip.
struct ModeSwitch: View {
    let mode: Assistant.Mode
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                seg("Message", on: mode == .message)
                seg("Ask", on: mode == .ask)
            }
            .padding(2)
            .background(Capsule().fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Message sends your words as a draft. Ask gets an answer from Mono. Click to switch.")
    }

    private func seg(_ t: String, on: Bool) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.accentColor : .clear))
    }
}

struct Nudge: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().strokeBorder(Color.accentColor.opacity(hover ? 0.9 : 0.45)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "+" — pick an app or conversation to point Mono at.
struct AttachMenu: View {
    @ObservedObject private var mono = Assistant.shared

    var body: some View {
        Menu {
            ForEach(Sources.all.filter { !$0.projects.isEmpty }, id: \.bundleID) { src in
                Section(Assistant.appName(src) + (src is CodexSessions ? " · ChatGPT" : "")) {
                    Button("All \(src.heading.lowercased())") { mono.attach(.app(src)) }
                    ForEach(src.all.prefix(12)) { s in
                        Button(s.title) { mono.attach(.conversation(s, src)) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Point Mono at an app or conversation (or type @)")
    }
}

/// Attached items as removable chips, wrapping onto new lines.
struct FlowChips: View {
    let items: [(String, String)]
    let remove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { id, label in
                HStack(spacing: 4) {
                    Text("@" + label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Button { remove(id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A message Mono wrote. Nothing is sent until you press Send.
struct DraftCard: View {
    let draft: Assistant.Draft
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Draft to \(draft.session.title) · \(draft.app)")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .onChange(of: text) { _, t in Assistant.shared.update(draft, text: t) }
            HStack {
                Spacer()
                Button("Discard") { Assistant.shared.discard(draft) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Send") { Assistant.shared.send(Assistant.Draft(session: draft.session, source: draft.source, text: text)); Assistant.shared.discard(draft) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
        .onAppear { text = draft.text }
    }
}


// MARK: - Structured model outputs

/// What the model fills in. Where the conversation stands is decided separately, by rules.
@Generable
struct ChatBriefDraft {
    @Guide(description: "What the other side most recently asked of Me, keeping every specific. Empty if nothing was asked.")
    var ask: String
    @Guide(description: "The concrete point of the conversation in under 16 words")
    var gist: String
}

struct ChatBrief {
    enum State { case needsYourReply, waitingOnThem, justFYI, wrappedUp }
    var ask: String
    var gist: String
    var state: State

    /// Where a conversation stands, from simple, reliable rules about the last message.
    static func state(of msgs: [ContextMessage], ask: String) -> State {
        guard let last = msgs.last else { return .justFYI }
        if last.isMe { return .waitingOnThem }
        let t = last.text.lowercased()
        let closers = ["love you", "talk tomorrow", "talk soon", "thanks", "thank you", "sounds good", "night", "👍", "ok cool", "see you", "bye"]
        let asks = ["?", "can you", "could you", "please", "let me know", "need you", "venmo", "send me", "want me to", "should i", "by tonight", "by friday"]
        if asks.contains(where: { t.contains($0) }) { return .needsYourReply }
        if closers.contains(where: { t.contains($0) }) { return .wrappedUp }
        return ask.trimmingCharacters(in: .whitespaces).isEmpty ? .justFYI : .needsYourReply
    }

    var label: String {
        switch state {
        case .needsYourReply: return "Needs your reply"
        case .waitingOnThem: return "Waiting on them"
        case .justFYI: return "FYI"
        case .wrappedUp: return "Wrapped up"
        }
    }

    /// One line under a conversation row.
    var line: String {
        let a = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(label) · " + (state == .needsYourReply && !a.isEmpty ? a : gist)
    }

    /// The Summarize button's fuller version.
    var full: String {
        let a = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(label). \(gist)" + (a.isEmpty ? "" : "\nThey're asking: \(a)")
    }
}

@Generable
struct SearchAnswer {
    @Guide(description: "The answer, direct and specific, under 70 words")
    var answer: String
    @Guide(description: "Numbers of the sources used, e.g. [1, 3]")
    var sources: [Int]
}
