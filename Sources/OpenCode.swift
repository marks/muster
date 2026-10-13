import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An `opencode serve` (OpenCode 2), the server its web UI and `opencode --server` use.
///
/// - Sessions come from `GET /api/session`, every project's, with their tokens and cost.
/// - `GET /api/event` streams what happens on the server (server-sent events): turns
///   starting and ending, permission requests and questions, for every session.
/// - A permission or a question is answered with the same calls the web UI makes, and
///   the first answer wins, so you can answer from Muster or from OpenCode.
///
/// Signs in with HTTP basic auth: the user is `opencode`, the password the server's.
final class OpenCodeClient: RemoteClient {
    private(set) var sessions: [Session] = []
    private(set) var prompts: [RemotePrompt] = []
    private(set) var state: SourceState = .ok(0)
    var onChange: (() -> Void)?

    private let server: RemoteServer
    private let http = RemoteHTTP()
    private var stream: EventStream?
    private var stopped = false
    private var backoff = Backoff()
    private var refetch: DispatchWorkItem?
    private var listTimer: Timer?

    private var rows: [[String: Any]] = []
    private var parents: [String: String] = [:]         // child session -> the session that started it
    private var running: Set<String> = []
    private var faults: [String: (Fault, Date)] = [:]   // why a turn failed, until the next one starts
    private var pending: [String: RemotePrompt] = [:]   // by the request's id

    init(server: RemoteServer, password: String) {
        self.server = server
        let user = server.username.isEmpty ? "opencode" : server.username
        http.headers["Authorization"] = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        // A compressed event stream can sit in a buffer; ask for it plain.
        http.headers["Accept-Encoding"] = "identity"
    }

    func start() { connect() }

    func stop() {
        stopped = true
        refetch?.cancel()
        listTimer?.invalidate()
        stream?.stop()
        http.stop()
    }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    private func path(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    // MARK: connecting

    /// Opens the event stream; once the server says it's connected, everything is read afresh,
    /// since events sent while the stream was down are gone.
    private func connect() {
        guard !stopped else { return }
        stream?.stop()
        let s = EventStream(url: url("/api/event"), headers: http.headers)
        s.onEvent = { [weak self] in self?.event($0) }
        s.onEnd = { [weak self] status, error in self?.ended(status, error) }
        stream = s
        s.start()
    }

    private func ended(_ status: Int, _ error: String?) {
        guard !stopped else { return }
        stream = nil
        listTimer?.invalidate()
        running = []
        pending = [:]
        switch status {
        case 401: state = .unreadable("Wrong password")
        case 0: state = .unreadable("Can't reach \(server.url.host ?? "the server")" + (error.map { ": \($0)" } ?? ""))
        case 200: break   // the stream closed; reconnect quietly
        default: state = .unreadable("The server answered \(status)")
        }
        publish(force: true)
        guard status != 401 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff.next()) { [weak self] in self?.connect() }
    }

    private func resync() {
        backoff.reset()
        fetch()
        http.call("GET", url("/api/session/active")) { [weak self] status, body, _ in
            guard let self, !self.stopped, status == 200 else { return }
            let active = ((body as? [String: Any])?["data"] as? [String: Any]).map { Set($0.keys) } ?? []
            self.running = active
            for id in active { self.readRequests(id) }
            self.publish(force: true)
        }
        listTimer?.invalidate()
        // Usage and titles arrive as events; this catches anything a dropped event missed.
        listTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.fetch() }
    }

    // MARK: the session list

    private func fetch() {
        http.call("GET", url("/api/session", ["limit": "60"])) { [weak self] status, body, error in
            guard let self, !self.stopped else { return }
            guard status == 200 else {
                if status == 401 { self.state = .unreadable("Wrong password"); self.publish(force: true) }
                return
            }
            self.rows = (body as? [String: Any])?["data"] as? [[String: Any]] ?? []
            for r in self.rows {
                let id = Field.string(r["id"]), parent = Field.string(r["parentID"])
                if !parent.isEmpty { self.parents[id] = parent }
            }
            self.publish()
        }
    }

    private func fetchSoon() {
        refetch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fetch() }
        refetch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Reads the permission requests and questions a running session (or its subagents) waits on.
    private func readRequests(_ id: String) {
        http.call("GET", url("/api/session/\(path(id))/permission")) { [weak self] status, body, _ in
            guard let self, status == 200 else { return }
            for r in (body as? [String: Any])?["data"] as? [[String: Any]] ?? [] { self.asked(r) }
        }
        http.call("GET", url("/api/session/\(path(id))/form")) { [weak self] status, body, _ in
            guard let self, status == 200 else { return }
            for f in (body as? [String: Any])?["data"] as? [[String: Any]] ?? [] { self.formed(f) }
        }
    }

    /// The session a row shows: subagents roll up to the session that started them.
    private func top(_ id: String) -> String {
        var id = id, seen: Set<String> = []
        while let p = parents[id], !seen.contains(p) { seen.insert(id); id = p }
        return id
    }

    private func publish(force: Bool = false) {
        let now = Date()
        let busy = Set(running.map(top))
        let next = rows.compactMap { r -> Session? in
            let id = Field.string(r["id"])
            return Self.session(r, running: busy.contains(id), fault: faults[id], waiting: pending.values.contains { $0.sessionID == id },
                                server: server.url, now: now)
        }
        let nextPrompts = pending.values.sorted { $0.key < $1.key }
        var nextState = state
        if stream?.connected == true { nextState = .ok(next.filter { now.timeIntervalSince($0.since) <= 3 * 3600 || $0.status.section != .recent }.count) }
        guard force || next != sessions || nextPrompts != prompts || nextState != state else { return }
        sessions = next
        prompts = nextPrompts
        state = nextState
        onChange?()
    }

    /// One `Session.Info`. Subagents and archived sessions have no row of their own.
    static func session(_ r: [String: Any], running: Bool, fault: (Fault, Date)?, waiting: Bool, server: URL, now: Date) -> Session? {
        let id = Field.string(r["id"])
        let time = r["time"] as? [String: Any] ?? [:]
        guard !id.isEmpty, Field.string(r["parentID"]).isEmpty, time["archived"] == nil || time["archived"] is NSNull else { return nil }
        let updated = Field.date(time["updated"]) ?? Field.date(time["created"]) ?? now
        let since = [updated, Field.date(time["idle"]), fault?.1].compactMap { $0 }.max() ?? updated
        let directory = Field.string((r["location"] as? [String: Any])?["directory"])
        var s = Session(agent: .opencode, sid: id, status: waiting ? .needsYou : running ? .working : .done, since: since,
                        title: Field.string(r["title"]), project: directory, appID: webLink(server, id)?.absoluteString ?? "")
        if !running, !waiting {
            if let fault, fault.1 >= updated.addingTimeInterval(-1) { s.fail(fault.0, at: fault.1) }
            else if Field.string(r["outcome"]) == "failed", let f = Fault(message: "The last turn failed") { s.fail(f, at: since) }
        }
        let tokens = r["tokens"] as? [String: Any] ?? [:]
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let read = Field.int(cache["read"])
        s.tokens = Field.int(tokens["input"]) + Field.int(tokens["output"]) + Field.int(tokens["reasoning"]) + read + Field.int(cache["write"])
        s.cached = read
        s.cost = Field.double(r["cost"])
        return s
    }

    /// The web UI's page for a session, which keys a server by its base64url address.
    static func webLink(_ server: URL, _ id: String) -> URL? {
        guard var c = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        c.path = ""; c.query = nil; c.fragment = nil; c.user = nil; c.password = nil
        guard let origin = c.url?.absoluteString else { return nil }
        let key = Data(origin.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: origin + "/server/" + key + "/session/" + id)
    }

    // MARK: events

    private func event(_ e: [String: Any]) {
        let type = Field.string(e["type"])
        let data = e["data"] as? [String: Any] ?? [:]
        let sid = Field.string(data["sessionID"])
        switch type {
        case "server.connected":
            resync()
        case "session.execution.started", "session.retry.scheduled":
            running.insert(sid)
            faults[sid] = nil
            publish()
        case "session.execution.succeeded", "session.execution.interrupted":
            running.remove(sid)
            fetchSoon()
            publish()
        case "session.execution.failed":
            running.remove(sid)
            let err = data["error"] as? [String: Any] ?? [:]
            if let f = Fault(message: Field.string(err["message"]).isEmpty ? Field.string(err["type"]) : Field.string(err["message"])) {
                faults[sid] = (f, Field.date(e["created"]) ?? Date())
            }
            fetchSoon()
            publish()
        case "session.created":
            let parent = Field.string(data["parentID"])
            if !parent.isEmpty { parents[sid] = parent }
            fetchSoon()
        case "session.renamed", "session.deleted", "session.moved", "session.usage.updated":
            fetchSoon()
        case "permission.asked":
            asked(data)
        case "permission.replied":
            if pending.removeValue(forKey: "p:" + Field.string(data["requestID"])) != nil { publish() }
        case "form.created":
            if let form = data["form"] as? [String: Any] { formed(form) }
        case "form.replied", "form.cancelled":
            if pending.removeValue(forKey: "f:" + Field.string(data["id"])) != nil { publish() }
        default:
            break
        }
    }

    private func asked(_ r: [String: Any]) {
        guard let p = Self.permission(r, top: top(Field.string(r["sessionID"])), project: project(of: r)) else { return }
        pending[p.key] = p
        publish()
    }

    private func formed(_ f: [String: Any]) {
        let sid = Field.string(f["sessionID"])
        guard let p = Self.question(f, top: top(sid), project: project(of: f)) else { return }
        pending[p.key] = p
        publish()
    }

    private func project(of r: [String: Any]) -> String {
        let id = top(Field.string(r["sessionID"]))
        return Field.string((rows.first { Field.string($0["id"]) == id }?["location"] as? [String: Any])?["directory"])
    }

    /// The request's own session goes in the key: the reply has to name it, a subagent's included.
    static func permission(_ r: [String: Any], top: String, project: String) -> RemotePrompt? {
        let id = Field.string(r["id"]), sid = Field.string(r["sessionID"])
        guard !id.isEmpty, !sid.isEmpty else { return nil }
        let action = Field.string(r["action"])
        let resources = r["resources"] as? [String] ?? []
        let metadata = r["metadata"] as? [String: Any] ?? [:]
        let tool: String, body: String
        switch action {
        case "shell", "bash":
            tool = "Bash"; body = resources.joined(separator: "\n")
        case "edit", "write":
            tool = "Edit"; body = resources.joined(separator: "\n")
        case "webfetch":
            tool = "WebFetch"; body = Field.string(metadata["url"]).isEmpty ? resources.joined(separator: "\n") : Field.string(metadata["url"])
        case "external_directory":
            tool = "a folder outside the project"; body = resources.joined(separator: "\n")
        case "read":
            tool = "Read"; body = resources.joined(separator: "\n")
        default:
            tool = action.isEmpty ? "a tool" : action; body = resources.joined(separator: "\n")
        }
        return RemotePrompt(key: "p:" + id, agent: .opencode, sessionID: top, project: project,
                            kind: .permission(tool: tool, summary: Field.line(body.isEmpty ? Field.string(r["message"]) : body),
                                              canAlwaysAllow: true),
                            reason: Field.string(r["message"]), body: body, code: tool == "Bash", owner: sid)
    }

    /// The question tool's form, when it asks one thing with choices; anything else is answered in OpenCode.
    static func question(_ f: [String: Any], top: String, project: String) -> RemotePrompt? {
        let id = Field.string(f["id"]), sid = Field.string(f["sessionID"])
        guard !id.isEmpty, !sid.isEmpty, sid != "global",
              (f["metadata"] as? [String: Any])?["kind"] as? String == "question",
              let fields = f["fields"] as? [[String: Any]], fields.count == 1, let field = fields.first,
              Field.string(field["type"]) == "string", let options = field["options"] as? [[String: Any]], !options.isEmpty
        else { return nil }
        let labels = options.prefix(9).map { o -> String in
            let v = Field.string(o["value"]); return v.isEmpty ? Field.string(o["label"]) : v
        }
        var text = Field.string(field["description"])
        if text.isEmpty { text = Field.string(field["title"]) }
        return RemotePrompt(key: "f:" + id, agent: .opencode, sessionID: top, project: project,
                            kind: .question(text: text, options: labels),
                            notes: options.prefix(9).map { Field.string($0["description"]) }, owner: sid, field: Field.string(field["key"]))
    }

    // MARK: answering

    /// OpenCode's word for a reply. ⇧ is "always", which saves a rule for the project, as
    /// OpenCode's own "Allow always" does.
    static func decision(_ reply: RemoteReply) -> String {
        switch reply {
        case .allow: return "once"
        case .allowAlways: return "always"
        case .deny, .option: return "reject"
        }
    }

    func answer(_ p: RemotePrompt, _ reply: RemoteReply) {
        let owner = p.owner.isEmpty ? p.sessionID : p.owner
        let done: (Int, Any?, String?) -> Void = { [weak self] _, _, _ in self?.publish() }
        if p.key.hasPrefix("p:") {
            let id = String(p.key.dropFirst(2))
            http.call("POST", url("/api/session/\(path(owner))/permission/\(path(id))/reply"),
                      json: ["decision": Self.decision(reply)], done: done)
        } else if p.key.hasPrefix("f:"), case .question(_, let options) = p.kind, !p.field.isEmpty {
            let id = String(p.key.dropFirst(2))
            if case .option(let i) = reply, options.indices.contains(i) {
                http.call("POST", url("/api/session/\(path(owner))/form/\(path(id))/reply"),
                          json: ["answer": [p.field: options[i]]], done: done)
            } else {
                http.call("DELETE", url("/api/session/\(path(owner))/form/\(path(id))"), done: done)
            }
        }
        pending[p.key] = nil
        publish()
    }
}

/// A server-sent event stream read as it arrives: each `data:` line is one JSON event.
/// The server sends a heartbeat every 15 seconds, so 45 seconds of silence means the
/// connection is gone even if nothing said so.
final class EventStream: NSObject, URLSessionDataDelegate {
    var onEvent: (([String: Any]) -> Void)?
    var onEnd: ((_ status: Int, _ error: String?) -> Void)?
    private(set) var connected = false

    private let request: URLRequest
    private var session: URLSession?
    private var buffer = Data()
    private var status = 0
    private var last = Date()
    private var watchdog: Timer?
    private var ended = false

    init(url: URL, headers: [String: String]) {
        var r = URLRequest(url: url)
        r.timeoutInterval = 60 * 60 * 24
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        request = r
    }

    func start() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 24 * 7
        c.urlCache = nil
        let s = URLSession(configuration: c, delegate: self, delegateQueue: .main)
        session = s
        s.dataTask(with: request).resume()
        last = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.last) > 45 else { return }
            self.finish(200, nil)
        }
    }

    func stop() {
        ended = true
        watchdog?.invalidate()
        session?.invalidateAndCancel()
        session = nil
    }

    private func finish(_ status: Int, _ error: String?) {
        guard !ended else { return }
        connected = false
        stop()
        onEnd?(status, error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        connected = status == 200
        completionHandler(status == 200 ? .allow : .cancel)
        if status != 200 { finish(status, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        last = Date()
        buffer.append(data)
        // Events end with a blank line; keep a partial one for the next chunk.
        while let r = buffer.range(of: Data("\n\n".utf8)) {
            let chunk = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            for e in Self.events(chunk) { onEvent?(e) }
        }
        if buffer.count > 8 << 20 { finish(200, nil) }   // no event is this large: the stream is lost
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A stream that was open and closed reconnects quietly; one that never opened couldn't reach the server.
        finish(status == 0 ? 0 : 200, error?.localizedDescription)
    }

    /// The JSON of each `data:` field in one event block; comments (`: heartbeat`) carry none.
    static func events(_ block: Data) -> [[String: Any]] {
        let text = String(decoding: block, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let data = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).drop { $0 == " " } }
            .joined(separator: "\n")
        guard !data.isEmpty, let o = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { return [] }
        return [o]
    }
}
