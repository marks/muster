import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

// Agents that run on a server rather than on this Mac: a Hermes gateway's
// dashboard, an `opencode serve`. Muster has no files to read for them, so it
// signs in to the server you add in Settings and asks it. Nothing is sent
// anywhere else, and nothing at all for an agent with no server added.

/// A prompt waiting on a server, as its client found it. Answered through that client.
struct RemotePrompt: Equatable {
    enum Kind: Equatable {
        case permission(tool: String, summary: String, canAlwaysAllow: Bool)
        case question(text: String, options: [String])
    }

    let key: String          // the server's own id for the request
    let agent: Agent
    let sessionID: String
    var project = ""
    let kind: Kind
    var reason = ""          // the agent's own explanation, when it gives one
    var body = ""            // the whole command, path or pattern
    var code = false         // body is a command, shown in monospace
    var notes: [String] = [] // one per option of a question
    var owner = ""           // the session the server files the request under, when not `sessionID`
    var field = ""           // the server's key for a question's answer
}

/// What you chose, before each server's own words for it.
enum RemoteReply: Equatable {
    case allow, allowAlways, deny, option(Int)
}

/// The address of a server you added, and the user to sign in as.
/// The password is kept in the Keychain, never in the defaults.
struct RemoteServer: Equatable {
    var url: URL
    var username: String
}

protocol RemoteClient: AnyObject {
    var sessions: [Session] { get }
    var prompts: [RemotePrompt] { get }
    var state: SourceState { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    func answer(_ prompt: RemotePrompt, _ reply: RemoteReply)
}

/// Owns one client per remote agent that has a server and is watched.
final class Remote {
    static let shared = Remote()

    /// OpenCode's desktop app, for its icon. Sessions on a server open in its web UI.
    static let openCodeBundleIDs = ["ai.opencode.desktop"]

    private var clients: [Agent: RemoteClient] = [:]
    private var watched: Set<Agent> = []
    private var started = false
    /// A session list or a prompt changed on some server.
    var onChange: (() -> Void)?

    /// Starts or stops each client to match what Settings watches.
    func watch(_ enabled: Set<Agent>) {
        started = true
        let want = enabled.filter { $0.isRemote }
        guard want != watched else { return }
        for agent in watched.subtracting(want) { disconnect(agent) }
        for agent in want.subtracting(watched) { connect(agent) }
        watched = want
    }

    /// Signs in again with the saved server, after you change it in Settings.
    func reconnect(_ agent: Agent) {
        disconnect(agent)
        if started, watched.contains(agent) { connect(agent) }
        onChange?()
    }

    func sessions(_ agent: Agent) -> [Session] { clients[agent]?.sessions ?? [] }

    var prompts: [RemotePrompt] { clients.values.flatMap { $0.prompts } }

    func state(_ agent: Agent) -> SourceState {
        guard Self.server(agent) != nil else { return .noServer }
        return clients[agent]?.state ?? .ok(0)
    }

    func answer(_ p: RemotePrompt, _ reply: RemoteReply) {
        clients[p.agent]?.answer(p, reply)
    }

    private func connect(_ agent: Agent) {
        guard clients[agent] == nil, let server = Self.server(agent) else { return }
        let password = Keychain.password(for: Self.account(agent, server)) ?? ""
        let client: RemoteClient
        switch agent {
        case .hermes: client = HermesClient(server: server, password: password)
        case .opencode: client = OpenCodeClient(server: server, password: password)
        default: return
        }
        client.onChange = { [weak self] in self?.onChange?() }
        clients[agent] = client
        client.start()
    }

    private func disconnect(_ agent: Agent) {
        clients.removeValue(forKey: agent)?.stop()
    }

    // MARK: saved servers

    private static let d = UserDefaults.standard

    static func server(_ agent: Agent) -> RemoteServer? {
        guard agent.isRemote, let s = d.string(forKey: "server.\(agent.rawValue).url"), let url = URL(string: s) else { return nil }
        return RemoteServer(url: url, username: d.string(forKey: "server.\(agent.rawValue).user") ?? "")
    }

    /// Saves the server and its password, after checking the address is one Muster can use.
    /// An empty password keeps the one already saved.
    static func save(_ agent: Agent, address: String, username: String, password: String) throws {
        guard let url = normalized(address) else {
            throw NSError(domain: "Muster", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter the server's address, like https://host:port"])
        }
        let old = server(agent)
        let password = password.isEmpty ? old.flatMap { Keychain.password(for: account(agent, $0)) } ?? "" : password
        guard !password.isEmpty else {
            throw NSError(domain: "Muster", code: 2, userInfo: [NSLocalizedDescriptionKey: "Enter the server's password"])
        }
        if let old { Keychain.delete(account(agent, old)) }
        let server = RemoteServer(url: url, username: username.trimmingCharacters(in: .whitespaces))
        try Keychain.set(password, for: account(agent, server))
        d.set(url.absoluteString, forKey: "server.\(agent.rawValue).url")
        d.set(server.username, forKey: "server.\(agent.rawValue).user")
        shared.reconnect(agent)
    }

    static func forget(_ agent: Agent) {
        if let old = server(agent) { Keychain.delete(account(agent, old)) }
        d.removeObject(forKey: "server.\(agent.rawValue).url")
        d.removeObject(forKey: "server.\(agent.rawValue).user")
        shared.reconnect(agent)
    }

    /// `host:port` or a full URL, without a trailing slash. Plain http is accepted only for
    /// this Mac itself: anything else would send the password in the clear.
    static func normalized(_ address: String) -> URL? {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) { return url }
        return nil
    }

    private static func account(_ agent: Agent, _ server: RemoteServer) -> String {
        "\(agent.rawValue) \(server.username)@\(server.url.absoluteString)"
    }
}

// MARK: - Plumbing the clients share

/// JSON over HTTPS, answered on the main queue. One session per server, so its
/// cookies are that server's alone and go when the client does.
final class RemoteHTTP {
    let session: URLSession
    var headers: [String: String] = [:]

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieAcceptPolicy = .always
        c.httpShouldSetCookies = true
        c.urlCache = nil
        session = URLSession(configuration: c, delegate: nil, delegateQueue: .main)
    }

    /// `status` is 0 when the server couldn't be reached at all.
    func call(_ method: String, _ url: URL, json: Any? = nil, extra: [String: String] = [:],
              done: @escaping (_ status: Int, _ body: Any?, _ error: String?) -> Void) {
        call(method, url, json: json, extra: extra) { status, body, error, _ in done(status, body, error) }
    }

    /// The same, with the response's headers.
    func call(_ method: String, _ url: URL, json: Any? = nil, extra: [String: String] = [:],
              full done: @escaping (_ status: Int, _ body: Any?, _ error: String?, _ response: HTTPURLResponse?) -> Void) {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers.merging(extra, uniquingKeysWith: { $1 }) { r.setValue(v, forHTTPHeaderField: k) }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        session.dataTask(with: r) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { $0.isEmpty ? nil : try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            done(status, body, error?.localizedDescription, response as? HTTPURLResponse)
        }.resume()
    }

    func stop() { session.invalidateAndCancel() }
}

/// Waits a little longer after each failure, up to a minute.
struct Backoff {
    private var n = 0
    mutating func next() -> TimeInterval { n += 1; return min(60, pow(2, Double(min(n, 6)))) }
    mutating func reset() { n = 0 }
}

/// Reads the numbers and dates servers write, whatever their JSON type.
enum Field {
    static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func string(_ v: Any?) -> String { (v as? String) ?? "" }

    /// Epoch seconds or milliseconds, or an ISO 8601 string.
    static func date(_ v: Any?) -> Date? {
        if let d = double(v) { return d > 0 ? Date(timeIntervalSince1970: d > 1e11 ? d / 1000 : d) : nil }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The first line, cut to a length a row can show.
    static func line(_ s: String, max: Int = 120) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }
}

// MARK: - Keychain

/// Server passwords, as generic passwords under Muster's own service name.
enum Keychain {
    static let service = "Muster server"

    #if canImport(Security)
    static func password(for account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ password: String, for account: String) throws {
        delete(account)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: Data(password.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't save the password in the Keychain (\(status))."])
        }
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
    #else
    private static var store: [String: String] = [:]
    static func password(for account: String) -> String? { store[account] }
    static func set(_ password: String, for account: String) throws { store[account] = password }
    static func delete(_ account: String) { store[account] = nil }
    #endif
}
