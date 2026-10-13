import AppKit
import SwiftUI
import UserNotifications

// Settings, in SwiftUI's native grouped form so it looks like System Settings.
// Built only when opened; the always-on paths (menu bar, switcher, deck) stay
// plain AppKit.

final class Windows {
    private var settingsWindow: NSWindow?
    private var usage: (window: NSWindow, model: UsageModel, closing: NSObjectProtocol)?

    func show() {
        let w = settingsWindow ?? window("Muster Settings", SettingsView(), size: NSSize(width: 460, height: 560))
        settingsWindow = w
        present(w)
    }

    /// Scans while open; closing stops the scan and lets the window and its data go.
    func showUsage() {
        if let usage { return present(usage.window) }
        let model = UsageModel()
        let w = window("Usage", UsageView(model: model), size: NSSize(width: 540, height: 760))
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            guard let self, let usage = self.usage else { return }
            usage.model.stop()
            NotificationCenter.default.removeObserver(usage.closing)
            usage.window.contentView = nil
            self.usage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
        }
        usage = (w, model, closing)
        present(w)
        model.start()
    }

    private func window<V: View>(_ title: String, _ view: V, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject private var keys = Hotkeys.shared
    @State private var launch = Settings.launchAtLogin
    @State private var needsYou = Settings.notifyNeedsYou
    @State private var done = Settings.notifyDone
    @State private var alert = Attention.enabled
    @State private var autoUpdate = Updates.automatic
    @State private var costDisplay = Settings.costDisplay
    @State private var week = Stats.week()
    @State private var agents = Settings.enabledAgents
    @State private var sources = Store.shared.sources
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var answering: [Agent: Bool] = [:]
    @State private var answerError: String?
    @State private var broken: [String] = []
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launch).onChange(of: launch) { _, v in Settings.launchAtLogin = v }
            }
            Section("Shortcuts") {
                LabeledContent("Switch between sessions") {
                    ShortcutRecorder(shortcut: keys.switcher, conflict: keys.conflicts.contains("switcher")) { keys.set(switcher: $0) }
                }
                LabeledContent("Search all sessions") {
                    ShortcutRecorder(shortcut: keys.search, conflict: keys.conflicts.contains("search")) { keys.set(search: $0) }
                }
                if !keys.conflicts.isEmpty {
                    Text("Another app already uses a shortcut marked ⚠︎. Click it and press a new combination.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(Agent.allCases, id: \.self) { agent in
                    Toggle(isOn: Binding(get: { agents.contains(agent) }, set: { on in
                        if on { agents.insert(agent) } else { agents.remove(agent) }
                        Settings.setEnabled(agent, on)
                        Store.shared.rescan()
                    })) {
                        HStack(spacing: 10) {
                            if let icon = agent.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.name)
                                Text(sourceText(agent)).font(.caption).foregroundStyle(sourceColour(agent))
                            }
                        }
                    }
                }
            } header: {
                Text("Watch")
            }
            Section {
                ForEach(Agent.allCases.filter(\.isRemote), id: \.self) { agent in
                    ServerRow(agent: agent, state: sources[agent], changed: refresh)
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Hermes and OpenCode run on a server, often another computer. Muster signs in to the one you add, "
                     + "keeps its password in your Keychain and connects to nothing else. Answer their prompts here or in "
                     + "the agent's own app: the first answer wins.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach([Agent.claude, Agent.codex], id: \.self) { agent in
                    Toggle(isOn: Binding(get: { answering[agent] ?? false }, set: { on in
                        do {
                            try on ? HookInstaller.install(agent) : HookInstaller.uninstall(agent)
                            answerError = nil
                        } catch { answerError = error.localizedDescription }
                        answering[agent] = HookInstaller.isInstalled(agent)
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent == .claude ? "Claude Code" : "Codex")
                            Text(agent == .claude ? "Permissions, questions and plans" : "Approvals. Trust the hook once in Codex with /hooks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let answerError { Text(answerError).font(.callout).foregroundStyle(.orange) }
                if !broken.isEmpty {
                    HStack {
                        Text("\(broken.joined(separator: ", ")) is gone, but its Claude hooks still run and fail.")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("Remove") {
                            do { try HookInstaller.removeBrokenClaudeHooks(); answerError = nil }
                            catch { answerError = error.localizedDescription }
                            refresh()
                        }
                    }
                }
            } header: {
                Text("Answer prompts from Muster")
            } footer: {
                Text("Adds a hook to the agent's own settings, keeping a backup; turning it off removes exactly that. "
                     + "If Muster isn't running, the agent asks as usual. Cursor's hooks can't step aside for prompts it would "
                     + "auto-approve, so Cursor prompts open in Cursor.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $alert) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show an alert at the top of the screen")
                        Text("Stays until you answer or dismiss it. Works in Focus modes and with a full menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: alert) { _, v in
                    Attention.enabled = v
                    NotificationCenter.default.post(name: Attention.changed, object: nil)
                }
            } header: {
                Text("When an agent needs you")
            }
            Section("Notify me when a session") {
                Toggle("Needs me or hits an error", isOn: $needsYou).onChange(of: needsYou) { _, v in Settings.notifyNeedsYou = v }
                Toggle("Finishes", isOn: $done).onChange(of: done) { _, v in Settings.notifyDone = v }
                if notifications == .denied || notifications == .notDetermined {
                    HStack {
                        Text(notifications == .denied ? "Notifications are turned off for Muster." : "Muster hasn't been allowed to notify you yet.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if notifications == .denied {
                            Button("Open Settings", action: Notifier.openSystemSettings)
                        } else {
                            Button("Allow…") { Notifier.requestAuthorization(refresh) }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Version") { Text(Updates.version).foregroundStyle(.secondary) }
                Toggle("Check for updates once a day", isOn: $autoUpdate).onChange(of: autoUpdate) { _, v in Updates.automatic = v }
                Button("Check for Updates…") { Updates.check(manual: true) }
            } header: {
                Text("Updates")
            } footer: {
                Text("Asks GitHub for the latest release. Nothing else is sent, and nothing at all unless you check.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("This week") {
                    Text(Stats.summary(week)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("What Muster did for you")
            } footer: {
                Text(Stats.assumption + " Counted on this Mac only.").foregroundStyle(.secondary)
            }
            Section {
                Picker("Show on each session", selection: $costDisplay) {
                    Text("Cost and tokens").tag(Settings.CostDisplay.costAndTokens)
                    Text("Tokens only").tag(Settings.CostDisplay.tokens)
                    Text("Nothing").tag(Settings.CostDisplay.hidden)
                }
                .onChange(of: costDisplay) { _, v in
                    Settings.costDisplay = v
                    Store.shared.refreshPrompts()
                }
                LabeledContent("Prices from") { Text("Anthropic and OpenAI, \(Pricing.retrieved)").foregroundStyle(.secondary) }
                Button("Use my own prices…") { Self.revealPricingFile() }
            } header: {
                Text("API cost estimate")
            } footer: {
                Text("What each session's tokens would cost at public API list prices. It is not what your subscription bills.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        sources = Store.shared.sources
        answering = [.claude: HookInstaller.isInstalled(.claude), .codex: HookInstaller.isInstalled(.codex)]
        broken = HookInstaller.brokenClaudeHooks()
        week = Stats.week()
        Notifier.status { notifications = $0 }
    }

    private func sourceText(_ agent: Agent) -> String {
        guard agents.contains(agent) else { return "Not watched" }
        return sources[agent]?.summary ?? "Looking…"
    }

    private func sourceColour(_ agent: Agent) -> Color {
        if case .unreadable = sources[agent] { return .orange }
        return .secondary
    }

    /// Creates ~/Library/Application Support/Muster/pricing.json from the built-in table and shows it in Finder.
    static func revealPricingFile() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Muster")
        let file = dir.appendingPathComponent("pricing.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(Pricing.builtIn).write(to: file)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

/// A server for an agent that runs elsewhere: where it is, and the password to sign in with.
private struct ServerRow: View {
    let agent: Agent
    let state: SourceState?
    let changed: () -> Void
    @State private var editing = false
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let icon = agent.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                    Text(summary).font(.caption).foregroundStyle(warning ? Color.orange : Color.secondary)
                }
                Spacer()
                if !editing {
                    if Remote.server(agent) != nil {
                        Button("Remove") { Remote.forget(agent); changed() }
                        Button("Edit…", action: begin)
                    } else {
                        Button("Add…", action: begin)
                    }
                }
            }
            if editing {
                TextField("Address", text: $address, prompt: Text(agent == .hermes ? "https://dashboard-host" : "https://server-host:4096"))
                if agent == .hermes { TextField("Username", text: $username) }
                SecureField("Password", text: $password, prompt: Text(Remote.server(agent) == nil ? "" : "Unchanged"))
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false; error = nil }
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                        .disabled(address.isEmpty || (password.isEmpty && Remote.server(agent) == nil))
                }
            }
        }
    }

    private var summary: String {
        guard let server = Remote.server(agent) else { return "Not added" }
        let host = server.url.host ?? server.url.absoluteString
        switch state {
        case .ok(let n)?: return "\(host) · \(n) session\(n == 1 ? "" : "s") in the last 3 hours"
        case .unreadable(let why)?: return "\(host) · \(why)"
        default: return "\(host) · Connecting…"
        }
    }

    private var warning: Bool {
        if case .unreadable = state { return true }
        return false
    }

    private func begin() {
        let server = Remote.server(agent)
        address = server?.url.absoluteString ?? ""
        username = server?.username ?? ""
        password = ""
        error = nil
        editing = true
    }

    private func save() {
        do {
            try Remote.save(agent, address: address, username: username, password: password)
            editing = false
            error = nil
            password = ""
            changed()
        } catch { self.error = error.localizedDescription }
    }
}
