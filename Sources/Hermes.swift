import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Hermes gateway's dashboard, the server Hermes Desktop connects to.
///
/// - Sessions come from `GET /api/sessions`, which lists every session the gateway
///   stores: chats from Desktop, from messaging apps, and cron runs.
/// - Desktop chats run in the dashboard itself, and `/api/ws` (JSON-RPC) says which
///   are working and which wait on you. Their approvals and questions are answered
///   here, alongside Desktop: the first answer wins.
/// - Chats from a messaging app run in the gateway's own process, which keeps their
///   approvals to itself. Muster shows those as needing you, from the session's
///   activity note, and you answer in the chat.
///
/// Signs in with the dashboard's username and password and sends the access token it
/// returns as a bearer token. When that lapses (12 hours by default) Muster signs in again,
/// never more than once in 30 seconds: the dashboard allows ten sign-ins a minute.
final class HermesClient: RemoteClient {
    private(set) var sessions: [Session] = []
    private(set) var prompts: [RemotePrompt] = []
    private(set) var state: SourceState = .ok(0)
    var onChange: (() -> Void)?

    private let server: RemoteServer
    private let password: String
    private let http = RemoteHTTP()
    private var socket: URLSessionWebSocketTask?
    private var stopped = false
    private var signedIn = false
    private var signingIn = false
    private var signedInAt = Date.distantPast
    private var backoff = Backoff()

    private var rows: [[String: Any]] = []
    /// Live sessions in the dashboard, by stored session id.
    private var live: [String: Live] = [:]
    /// Live sessions this connection attached to, to read a question: the dashboard
    /// keeps a session alive while any client is attached, so they're let go once answered.
    private var attached: Set<String> = []
    private var replies: [String: (Any?) -> Void] = [:]
    private var nextID = 0
    private var listTimer: Timer?
    private var liveTimer: Timer?
    private var refetch: DispatchWorkItem?

    struct Live: Equatable {
        let sid: String       // the live session's id, which the RPCs take
        let status: String    // idle, starting, waiting, working, streaming, resuming
    }

    init(server: RemoteServer, password: String) {
        self.server = server
        self.password = password
    }

    func start() { signIn() }

    func stop() {
        stopped = true
        listTimer?.invalidate()
        liveTimer?.invalidate()
        refetch?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        http.stop()
    }

    // MARK: signing in

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    /// Finds the dashboard's password provider, then signs in with it.
    private func signIn() {
        guard !stopped, !signingIn else { return }
        signingIn = true
        signedIn = false
        http.headers["Authorization"] = nil
        http.call("GET", url("/api/auth/providers")) { [weak self] status, body, error in
            guard let self, !self.stopped else { return }
            guard status == 200 else { self.signingIn = false; return self.failed(status, error) }
            let providers = (body as? [String: Any])?["providers"] as? [[String: Any]] ?? []
            guard let provider = providers.first(where: { $0["supports_password"] as? Bool == true })?["name"] as? String else {
                self.signingIn = false
                return self.fail("This dashboard has no username and password sign-in", retry: false)
            }
            let login: [String: Any] = ["provider": provider, "username": self.server.username, "password": self.password, "next": ""]
            self.http.call("POST", self.url("/auth/password-login"), json: login) { status, _, error, response in
                guard !self.stopped else { return }
                self.signingIn = false
                switch status {
                case 200:
                    guard let token = response.flatMap(Self.accessToken) else {
                        return self.fail("Signed in, but the dashboard sent no session", retry: false)
                    }
                    self.http.headers["Authorization"] = "Bearer " + token
                    self.signedIn = true
                    self.signedInAt = Date()
                    self.fetch()
                    self.connect()
                    self.listTimer?.invalidate()
                    self.listTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.fetch() }
                case 401: self.fail("Wrong username or password", retry: false)
                default: self.failed(status, error)
                }
            }
        }
    }

    /// The access token from the session cookie the sign-in sets (`__Host-` over https).
    static func accessToken(_ response: HTTPURLResponse) -> String? {
        let cookies = response.allHeaderFields.compactMap { k, v in (k as? String)?.lowercased() == "set-cookie" ? v as? String : nil }
        return cookies.lazy.compactMap { accessToken(setCookie: $0) }.first
    }

    static func accessToken(setCookie: String) -> String? {
        guard let r = setCookie.range(of: #"(?:^|[\s,;])(?:__Host-|__Secure-)?hermes_session_at=([^;,\s]+)"#, options: .regularExpression) else { return nil }
        let match = String(setCookie[r])
        return match.range(of: "=").map { String(match[$0.upperBound...]) }
    }

    /// The token was refused: sign in again, unless that only just happened, which
    /// means the server won't take it, and trying at once would only loop.
    private func reauthorize() {
        guard !signingIn else { return }
        if Date().timeIntervalSince(signedInAt) < 30 { return fail("The dashboard refused Muster's session") }
        signIn()
    }

    private func failed(_ status: Int, _ error: String?) {
        switch status {
        case 0: fail("Can't reach \(server.url.host ?? "the server")" + (error.map { ": \($0)" } ?? ""))
        case 429: fail("Too many sign-ins; trying again shortly")
        default: fail("The server answered \(status)")
        }
    }

    private func fail(_ why: String, retry: Bool = true) {
        signedIn = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .unreadable(why)
        onChange?()
        guard retry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff.next()) { [weak self] in
            guard let self, !self.stopped, !self.signedIn else { return }
            self.signIn()
        }
    }

    // MARK: the session list

    private func fetch() {
        guard signedIn else { return }
        http.call("GET", url("/api/sessions", ["limit": "50", "order": "recent"])) { [weak self] status, body, error in
            guard let self, !self.stopped else { return }
            guard status == 200 else { return status == 401 ? self.reauthorize() : self.failed(status, error) }
            // Only a request that works after signing in ends the backoff: a server that signs
            // Muster in and then refuses it would otherwise be asked again every few seconds.
            self.backoff.reset()
            self.rows = (body as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
            self.publish()
        }
    }

    /// Fetches again soon, once a burst of changes settles.
    private func fetchSoon() {
        refetch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fetch(); self?.poll() }
        refetch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func publish() {
        let now = Date()
        let next = rows.compactMap { Self.session($0, live: live[Field.string($0["id"])], now: now) }
        let ok = SourceState.ok(next.filter { $0.status.section != .recent || now.timeIntervalSince($0.since) <= 3 * 3600 }.count)
        guard next != sessions || state != ok else { return }
        sessions = next
        state = ok
        onChange?()
    }

    /// One row of `/api/sessions`. A live Desktop chat's state comes from the dashboard;
    /// any other session's from its activity note, which Hermes clears when a turn ends.
    static func session(_ row: [String: Any], live: Live?, now: Date) -> Session? {
        let id = Field.string(row["id"])
        guard !id.isEmpty, Field.int(row["hidden"]) == 0, row["hidden"] as? Bool != true else { return nil }
        let started = Field.date(row["started_at"]) ?? now
        let since = [Field.date(row["last_activity_at"]), Field.date(row["last_active"]), Field.date(row["ended_at"]), started]
            .compactMap { $0 }.max() ?? started
        let note = Field.string(row["last_activity_description"]).lowercased()
        var status: Status
        var fault: Fault?
        if let live {
            switch live.status {
            case "waiting": status = .needsYou
            case "working", "streaming", "starting", "resuming": status = .working
            default: status = .done
            }
        } else if row["ended_at"] != nil, !(row["ended_at"] is NSNull) {
            status = .done
            let reason = Field.string(row["end_reason"])
            if reason.lowercased().contains("error") || reason.lowercased().contains("fail") { fault = Fault(message: reason) }
        } else if note.contains("waiting for user") {
            status = .needsYou
        } else {
            status = note.isEmpty ? .done : .working
        }
        var title = Field.string(row["title"])
        if title.isEmpty { title = Field.line(Field.string(row["preview"]), max: 80) }
        let cwd = Field.string(row["cwd"])
        var s = Session(agent: .hermes, sid: id, status: status, since: since, title: title,
                        project: cwd.isEmpty ? source(Field.string(row["source"])) : cwd, appID: live?.sid ?? "")
        if let fault { s.fail(fault, at: since) }
        let cacheRead = Field.int(row["cache_read_tokens"])
        s.tokens = Field.int(row["input_tokens"]) + Field.int(row["output_tokens"]) + cacheRead + Field.int(row["cache_write_tokens"])
        s.cached = cacheRead
        s.cost = Field.double(row["actual_cost_usd"]) ?? Field.double(row["estimated_cost_usd"])
        return s
    }

    /// Where a chat came from, for a session with no folder.
    static func source(_ s: String) -> String {
        switch s.lowercased() {
        case "", "desktop", "tui", "cli", "dashboard", "web": return ""
        case "bluebubbles", "imessage": return "iMessage"
        case "whatsapp": return "WhatsApp"
        case "api_server": return "API"
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    // MARK: the live connection

    private func connect() {
        guard signedIn, socket == nil else { return }
        http.call("POST", url("/api/auth/ws-ticket")) { [weak self] status, body, error in
            guard let self, !self.stopped, self.signedIn, self.socket == nil else { return }
            guard status == 200, let ticket = (body as? [String: Any])?["ticket"] as? String else {
                return status == 401 ? self.reauthorize() : self.failed(status, error)
            }
            var c = URLComponents(url: self.url("/api/ws", ["ticket": ticket]), resolvingAgainstBaseURL: false)!
            c.scheme = c.scheme == "http" ? "ws" : "wss"
            let task = self.http.session.webSocketTask(with: c.url!)
            task.maximumMessageSize = 16 << 20
            self.socket = task
            self.attached = []
            task.resume()
            self.receive(task)
            self.rpc("client.capabilities", ["server_requests": true])
            self.poll()
            self.liveTimer?.invalidate()
            self.liveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, task === self.socket else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(Data(text.utf8))
                    case .data(let data): self.handle(data)
                    @unknown default: break
                    }
                    self.receive(task)
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    /// The socket closed: sleep, a restart, a lapsed ticket. Live state is stale until it's back.
    private func dropped() {
        socket = nil
        replies = [:]
        live = [:]
        attached = []
        prompts = []
        publish()
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff.next()) { [weak self] in self?.connect() }
    }

    private func rpc(_ method: String, _ params: [String: Any], reply: ((Any?) -> Void)? = nil) {
        guard let socket else { return }
        nextID += 1
        let id = "m\(nextID)"
        if let reply { replies[id] = reply }
        send(socket, ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func send(_ socket: URLSessionWebSocketTask, _ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func handle(_ data: Data) {
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let method = frame["method"] as? String
        if method == nil, let id = frame["id"] as? String, let reply = replies.removeValue(forKey: id) {
            backoff.reset()
            return reply(frame["error"] == nil ? frame["result"] : nil)
        }
        if method == "event" {
            let type = Field.string((frame["params"] as? [String: Any])?["type"])
            switch type {
            case "sessions.changed", "session.reclaimed": fetchSoon()
            case "approval.cancelled", "request.cancel", "message.complete", "session.title": poll()
            default: break
            }
            return
        }
        // A question sent to the clients attached to its session: read it the same way as the rest.
        if method == "approval" || method == "clarify" { poll() }
    }

    // MARK: what waits on you

    /// Asks which live sessions are working or waiting: often while any is, rarely otherwise.
    private var quietTicks = 0
    private func tick() {
        let busy = live.values.contains { $0.status != "idle" }
        quietTicks += 1
        if busy || quietTicks >= 5 { quietTicks = 0; poll() }
    }

    private func poll() {
        rpc("session.active_list", [:]) { [weak self] result in
            guard let self else { return }
            let items = (result as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
            var next: [String: Live] = [:]
            for item in items {
                let key = Field.string(item["session_key"]), sid = Field.string(item["id"])
                guard !key.isEmpty, !sid.isEmpty else { continue }
                next[key] = Live(sid: sid, status: Field.string(item["status"]))
            }
            let changed = next != self.live
            self.live = next
            if !next.keys.allSatisfy({ k in self.rows.contains { Field.string($0["id"]) == k } }) { self.fetchSoon() }
            self.gatherPrompts()
            if changed { self.publish() }
        }
    }

    /// Reads each waiting session's approvals, or, failing those, its open questions.
    private func gatherPrompts() {
        let waiting = live.filter { $0.value.status == "waiting" }
        var found: [RemotePrompt] = []
        var pendingReads = waiting.count
        let finish = { [weak self] in
            guard let self else { return }
            pendingReads -= 1
            guard pendingReads <= 0 else { return }
            self.shedAttachments(waiting: Set(waiting.keys))
            guard found != self.prompts else { return }
            self.prompts = found
            self.onChange?()
        }
        guard !waiting.isEmpty else { pendingReads = 1; return finish() }
        for (key, l) in waiting {
            let project = sessions.first { $0.sid == key }?.project ?? ""
            rpc("approval.pending", ["session_id": l.sid]) { [weak self] result in
                guard let self else { return }
                let approvals = (result as? [String: Any])?["approvals"] as? [[String: Any]] ?? []
                if !approvals.isEmpty {
                    found += approvals.map { Self.approval($0, session: key, project: project) }
                    return finish()
                }
                self.rpc("session.activate", ["session_id": l.sid, "omit_messages": true]) { [weak self] snapshot in
                    self?.attached.insert(key)
                    let open = (snapshot as? [String: Any])?["open_requests"] as? [[String: Any]] ?? []
                    found += open.compactMap { Self.question($0, session: key, project: project) }
                    finish()
                }
            }
        }
    }

    /// Attaching keeps a chat alive in the dashboard even after Desktop lets it go, so once
    /// nothing attached waits any longer, the connection starts over without them.
    private func shedAttachments(waiting: Set<String>) {
        guard !attached.isEmpty, attached.isDisjoint(with: waiting), let socket else { return }
        socket.cancel(with: .normalClosure, reason: nil)
        self.socket = nil
        attached = []
        replies = [:]
        connect()
    }

    static func approval(_ a: [String: Any], session: String, project: String) -> RemotePrompt {
        let command = Field.string(a["command"])
        let description = Field.string(a["description"])
        // A request frame lists its choices; `approval.pending` gives only the flags they come from.
        let choices = a["choices"] as? [String] ?? []
        let forSession = choices.isEmpty ? a["allow_session"] as? Bool == true && a["smart_denied"] as? Bool != true : choices.contains("session")
        let tool = Field.string(a["tool_name"])
        return RemotePrompt(key: "a:" + (Field.string(a["request_id"]).isEmpty ? session : Field.string(a["request_id"])),
                            agent: .hermes, sessionID: session, project: project,
                            kind: .permission(tool: command.isEmpty ? (tool.isEmpty ? "a tool" : tool) : "Bash",
                                              summary: Field.line(command.isEmpty ? description : command),
                                              canAlwaysAllow: forSession),
                            reason: command.isEmpty ? "" : description, body: command.isEmpty ? description : command,
                            code: !command.isEmpty)
    }

    /// A clarify request with one question and its choices; several questions, or one
    /// that wants your own words, are answered in Hermes.
    static func question(_ r: [String: Any], session: String, project: String) -> RemotePrompt? {
        guard Field.string(r["method"]) == "clarify", let id = r["id"] as? String,
              let qs = (r["params"] as? [String: Any])?["questions"] as? [[String: Any]], qs.count == 1, let q = qs.first,
              q["multi_select"] as? Bool != true, let choices = q["choices"] as? [String], !choices.isEmpty,
              let qid = q["qid"] as? String else { return nil }
        return RemotePrompt(key: "q:" + id, agent: .hermes, sessionID: session, project: project,
                            kind: .question(text: Field.string(q["question"]), options: Array(choices.prefix(9))), field: qid)
    }

    /// Hermes's word for a reply: ⇧ allows for the rest of the session, never permanently.
    static func choice(_ reply: RemoteReply, offered: Bool) -> String {
        switch reply {
        case .allow: return "once"
        case .allowAlways: return offered ? "session" : "once"
        case .deny, .option: return "deny"
        }
    }

    func answer(_ p: RemotePrompt, _ reply: RemoteReply) {
        guard let l = live[p.sessionID] else { return }
        if p.key.hasPrefix("a:") {
            var params: [String: Any] = ["session_id": l.sid]
            if case .permission(_, _, let session) = p.kind { params["choice"] = Self.choice(reply, offered: session) }
            let request = String(p.key.dropFirst(2))
            if request != p.sessionID { params["request_id"] = request }
            rpc("approval.respond", params) { [weak self] _ in self?.poll() }
        } else if p.key.hasPrefix("q:"), case .question(_, let options) = p.kind {
            var answers: [String: Any] = [:]
            if case .option(let i) = reply, options.indices.contains(i) { answers[p.field] = options[i] }
            // An empty answer set cancels the question, which is what dismissing it means.
            let result: [String: Any] = answers.isEmpty ? [:] : ["answers": answers]
            rpc("request.answer", ["id": String(p.key.dropFirst(2)), "result": result]) { [weak self] _ in self?.poll() }
        }
        prompts.removeAll { $0.key == p.key }
        onChange?()
    }
}
