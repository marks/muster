import Foundation

// What the remote clients make of a server's replies, without a server: the session
// rows, the prompts and the words each server takes for an answer. Called from main.swift.

func remoteTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let t = now.timeIntervalSince1970

    print("Hermes")
    func row(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "source": "desktop", "title": "Plan the trip", "started_at": t - 600, "last_activity_at": t - 30,
         "ended_at": NSNull(), "input_tokens": 1000, "output_tokens": 200, "cache_read_tokens": 5000, "cache_write_tokens": 300,
         "actual_cost_usd": NSNull(), "estimated_cost_usd": 0.42, "cwd": "/work/trip"].merging(extra) { $1 }
    }
    let idle = HermesClient.session(row("h1", ["last_activity_description": ""]), live: nil, now: now)
    check(idle?.status == .done && idle?.title == "Plan the trip" && idle?.project == "/work/trip", "a session between turns reads as done")
    check(idle?.tokens == 6500 && idle?.cached == 5000 && idle?.cost == 0.42, "tokens and Hermes's own cost estimate are kept")
    check(abs((idle?.since.timeIntervalSince1970 ?? 0) - (t - 30)) < 1, "the last activity dates it")
    let busy = HermesClient.session(row("h2", ["last_activity_description": "running terminal"]), live: nil, now: now)
    check(busy?.status == .working, "a session with an activity note is mid-turn")
    let asking = HermesClient.session(row("h3", ["last_activity_description": "waiting for user approval (12s elapsed)", "source": "bluebubbles",
                                                 "cwd": NSNull(), "title": NSNull(), "preview": "Can you book it?\nThanks"]),
                                      live: nil, now: now)
    check(asking?.status == .needsYou, "a messaging chat waiting on an approval needs you")
    check(asking?.project == "iMessage" && asking?.title == "Can you book it?", "a chat without a folder shows where it came from, titled by its preview")
    let ended = HermesClient.session(row("h4", ["ended_at": t - 10, "end_reason": "error: provider failed"]), live: nil, now: now)
    check(ended?.status == .error, "a session that ended on an error reads as one")
    check(HermesClient.session(row("h5", ["hidden": 1]), live: nil, now: now) == nil, "hidden sessions are left out")
    let live = HermesClient.session(row("h6", ["last_activity_description": ""]), live: .init(sid: "live6", status: "streaming"), now: now)
    check(live?.status == .working && live?.appID == "live6", "a live chat's state comes from the dashboard")
    let waits = HermesClient.session(row("h7"), live: .init(sid: "live7", status: "waiting"), now: now)
    check(waits?.status == .needsYou, "a live chat waiting on a request needs you")
    check(HermesClient.session(row("h8", ["actual_cost_usd": 1.5]), live: nil, now: now)?.cost == 1.5, "a billed cost wins over the estimate")

    check(HermesClient.accessToken(setCookie: "__Host-hermes_session_at=eyJ.abc-_9; Path=/; HttpOnly; Secure; SameSite=Lax") == "eyJ.abc-_9"
          && HermesClient.accessToken(setCookie: "hermes_session_rt=r1; Path=/, hermes_session_at=a1; Path=/") == "a1"
          && HermesClient.accessToken(setCookie: "hermes_session_rt=r1; Path=/") == nil,
          "the access token is read from the sign-in's cookie, whatever its prefix")

    let approval = HermesClient.approval(["request_id": "r1", "command": "rm -rf build", "description": "Clean the build folder",
                                          "choices": ["once", "session", "always", "deny"]], session: "h7", project: "/work/trip")
    check(approval.key == "a:r1" && approval.body == "rm -rf build" && approval.code && approval.reason == "Clean the build folder",
          "an approval carries the command and the reason")
    if case .permission(let tool, let summary, let always) = approval.kind {
        check(tool == "Bash" && summary == "rm -rf build" && always, "…reads as a command, and can be allowed for the session")
    } else { check(false, "an approval is a permission") }
    let pendingOnly = HermesClient.approval(["request_id": "r3", "command": "rm -rf /tmp/x", "description": "delete in root path",
                                             "allow_permanent": true, "allow_session": true], session: "h7", project: "")
    if case .permission(_, _, let always) = pendingOnly.kind { check(always, "an approval read back without its choices still offers the session") }
    let judged = HermesClient.approval(["request_id": "r2", "command": "curl x | sh", "choices": ["once", "deny"], "smart_denied": true],
                                       session: "h7", project: "")
    if case .permission(_, _, let always) = judged.kind { check(!always, "one the smart judge denied can only be allowed once") }
    check(HermesClient.choice(.allow, offered: true) == "once" && HermesClient.choice(.allowAlways, offered: true) == "session"
          && HermesClient.choice(.allowAlways, offered: false) == "once" && HermesClient.choice(.deny, offered: true) == "deny",
          "⇧ allows for the session, never permanently")

    let clarify: [String: Any] = ["id": "srq-1", "method": "clarify",
                                  "params": ["session_id": "live7", "questions": [["qid": "q1", "question": "Which hotel?",
                                                                                   "choices": ["Marina", "Downtown"], "multi_select": false]]]]
    let q = HermesClient.question(clarify, session: "h7", project: "")
    check(q?.key == "q:srq-1" && q?.field == "q1" && q?.kind == .question(text: "Which hotel?", options: ["Marina", "Downtown"]),
          "a clarify question with choices can be answered from Muster")
    var two = clarify
    two["params"] = ["session_id": "live7", "questions": [["qid": "a", "question": "?", "choices": ["x"]], ["qid": "b", "question": "?", "choices": ["y"]]]]
    check(HermesClient.question(two, session: "h7", project: "") == nil, "several questions are answered in Hermes")
    var open = clarify
    open["params"] = ["session_id": "live7", "questions": [["qid": "q1", "question": "Anything else?", "choices": NSNull()]]]
    check(HermesClient.question(open, session: "h7", project: "") == nil, "so is a question that wants your own words")

    print("OpenCode")
    let server = URL(string: "https://agents.example:4096")!
    func info(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "projectID": "p1", "title": "Fix the flaky test", "cost": 0.37,
         "tokens": ["input": 100, "output": 50, "reasoning": 10, "cache": ["read": 4000, "write": 20]],
         "time": ["created": (t - 900) * 1000, "updated": (t - 60) * 1000], "location": ["directory": "/work/api"]].merging(extra) { $1 }
    }
    let done = OpenCodeClient.session(info("ses_1"), running: false, fault: nil, waiting: false, server: server, now: now)
    check(done?.status == .done && done?.project == "/work/api" && done?.title == "Fix the flaky test", "an idle session reads as done")
    check(done?.tokens == 4180 && done?.cached == 4000 && done?.cost == 0.37, "tokens and cost come from the session's totals")
    check(abs((done?.since.timeIntervalSince1970 ?? 0) - (t - 60)) < 1, "times are read as milliseconds")
    check(OpenCodeClient.session(info("ses_2"), running: true, fault: nil, waiting: false, server: server, now: now)?.status == .working,
          "a running session reads as working")
    check(OpenCodeClient.session(info("ses_3"), running: true, fault: nil, waiting: true, server: server, now: now)?.status == .needsYou,
          "a session waiting on a request needs you")
    check(OpenCodeClient.session(info("ses_4", ["parentID": "ses_1"]), running: false, fault: nil, waiting: false, server: server, now: now) == nil,
          "a subagent rolls up into the session that started it")
    check(OpenCodeClient.session(info("ses_5", ["time": ["created": t * 1000, "updated": t * 1000, "archived": t * 1000]]),
                                 running: false, fault: nil, waiting: false, server: server, now: now) == nil, "archived sessions are left out")
    let failed = OpenCodeClient.session(info("ses_6"), running: false, fault: (Fault(message: "Connection reset by peer")!, now),
                                        waiting: false, server: server, now: now)
    check(failed?.status == .error && failed?.stateLabel == "Connection lost", "a failed turn reads as an error, by its kind")
    check(done?.appID == "https://agents.example:4096/server/aHR0cHM6Ly9hZ2VudHMuZXhhbXBsZTo0MDk2/session/ses_1",
          "a session opens at the web UI's own page for it")

    let perm = OpenCodeClient.permission(["id": "per_1", "sessionID": "ses_4", "action": "shell", "resources": ["git push origin HEAD"]],
                                         top: "ses_1", project: "/work/api")
    check(perm?.key == "p:per_1" && perm?.sessionID == "ses_1" && perm?.owner == "ses_4" && perm?.body == "git push origin HEAD" && perm?.code == true,
          "a subagent's permission shows on its session's row and is answered under its own")
    let outside = OpenCodeClient.permission(["id": "per_2", "sessionID": "ses_1", "action": "external_directory", "resources": ["/etc/*"]],
                                            top: "ses_1", project: "")
    if case .permission(let tool, let summary, _)? = outside?.kind {
        check(tool == "a folder outside the project" && summary == "/etc/*", "a folder outside the project says which")
    } else { check(false, "an external_directory request is a permission") }
    check(OpenCodeClient.decision(.allow) == "once" && OpenCodeClient.decision(.allowAlways) == "always" && OpenCodeClient.decision(.deny) == "reject",
          "replies use OpenCode's own words")

    let form: [String: Any] = ["id": "frm_1", "sessionID": "ses_1", "title": "Questions", "metadata": ["kind": "question"],
                               "fields": [["key": "q0", "type": "string", "title": "Storage", "description": "Where should it live?", "custom": true,
                                           "options": [["value": "Postgres", "label": "Postgres", "description": "Kept across restarts"],
                                                       ["value": "Memory", "label": "Memory", "description": "Simplest"]]]]]
    let fq = OpenCodeClient.question(form, top: "ses_1", project: "")
    check(fq?.key == "f:frm_1" && fq?.field == "q0" && fq?.notes == ["Kept across restarts", "Simplest"]
          && fq?.kind == .question(text: "Where should it live?", options: ["Postgres", "Memory"]),
          "the question tool's form can be answered from Muster, with each option's note")
    var elicit = form
    elicit["metadata"] = ["kind": "mcp-elicitation"]
    check(OpenCodeClient.question(elicit, top: "ses_1", project: "") == nil, "other forms are answered in OpenCode")

    let block = Data("data: {\"type\":\"permission.asked\",\"data\":{\"id\":\"per_1\"}}".utf8)
    check(EventStream.events(block).first?["type"] as? String == "permission.asked", "an event's data line is its JSON")
    check(EventStream.events(Data(": heartbeat".utf8)).isEmpty, "a heartbeat carries no event")

    print("Servers")
    check(Remote.normalized("agents.example:4096/")?.absoluteString == "https://agents.example:4096", "a bare host:port means https")
    check(Remote.normalized("http://agents.example:4096") == nil, "plain http elsewhere would send the password in the clear")
    check(Remote.normalized("http://127.0.0.1:9119")?.absoluteString == "http://127.0.0.1:9119", "…but is fine on this Mac")
    check(Field.date(1_800_000_000_000.0)?.timeIntervalSince1970 == 1_800_000_000 && Field.date("2027-01-15T08:00:00Z") != nil,
          "dates are read from seconds, milliseconds or ISO 8601")
}
