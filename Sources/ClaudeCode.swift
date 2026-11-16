import Foundation
import AppKit
import Network
import SwiftUI

/// Talks to Claude Code through its "hooks": Claude Code runs ~/.hangtime/hook.sh at key
/// moments, and the script passes the details to Hangtime over a private local connection
/// (127.0.0.1 only, protected by a secret token). If Hangtime is not running, the script
/// does nothing and Claude Code carries on exactly as normal.
final class ClaudeCode: ObservableObject {
    static let shared = ClaudeCode()
    static let port: UInt16 = 47823
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hangtime", isDirectory: true)
    static var hookScript: URL { folder.appendingPathComponent("hook.sh") }
    static var tokenFile: URL { folder.appendingPathComponent("token") }
    static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    static let marker = ".hangtime/hook.sh"
    static let legacyMarker = ".deckhand/hook.sh"      // before the rename to Hangtime

    enum State: String { case working, waiting, done, error }

    /// A file Claude changed in a session, with rough line counts from the edits it made.
    struct ChangedFile: Identifiable, Equatable {
        var id: String { path }
        let path: String
        var added: Int
        var removed: Int
    }

    struct Session: Identifiable {
        let id: String
        var project: String
        var cwd: String
        var state: State
        var detail: String
        var symbol: String = "sparkle"
        var updated: Date
        var started = Date()
        var files: [ChangedFile] = []
    }

    /// Shown for a few seconds after a session finishes ("Done · 4 files changed").
    struct Finished: Equatable {
        let project: String
        let files: Int
        let date: Date
    }

    struct Request: Identifiable {
        let id = UUID()
        let session: String
        let project: String
        let tool: String
        let summary: String
        let canAlwaysAllow: Bool
        let reply: (String) -> Void
    }

    @Published var sessions: [Session] = []
    @Published var requests: [Request] = []
    @Published var finished: Finished? = nil
    @Published var connected = false
    @Published var serverRunning = false

    // Today's Claude Code usage, read from its local logs.
    @Published var tokens = 0
    @Published var inputTokens = 0
    @Published var outputTokens = 0
    @Published var cacheWrite = 0
    @Published var cacheRead = 0
    @Published var sessionCount = 0
    @Published var messageCount = 0
    @Published var usageUpdated: Date? = nil

    private var listener: NWListener?
    private var token = ""
    private var timer: Timer?
    private var usageTimer: Timer?
    private let queue = DispatchQueue(label: "hangtime.bridge")
    private let usageQueue = DispatchQueue(label: "hangtime.usage")
    private var fileCache: [String: FileUsage] = [:]

    var overall: State? {
        if !requests.isEmpty || sessions.contains(where: { $0.state == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.state == .error }) { return .error }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        if sessions.contains(where: { $0.state == .done }) { return .done }
        return nil
    }

    func start() {
        prepareFiles()
        startServer()
        moveFromDeckhand()
        connected = hooksInstalled()
        if !connected && !UserDefaults.standard.bool(forKey: "hooksOffered") {
            UserDefaults.standard.set(true, forKey: "hooksOffered")
            connected = installHooks()
        }
        // Version 2 also listens for finished edits (files changed) and errors.
        if connected && UserDefaults.standard.integer(forKey: "hooksVersion") < 2 {
            installHooks()
        }
        UserDefaults.standard.set(2, forKey: "hooksVersion")
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.prune()
        }
        scanUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.scanUsage()
        }
    }

    /// The app used to be called Deckhand: swap its hooks in Claude Code's settings for
    /// Hangtime's and remove the old ~/.deckhand folder.
    private func moveFromDeckhand() {
        let text = (try? String(contentsOf: ClaudeCode.settingsFile, encoding: .utf8)) ?? ""
        if text.contains(ClaudeCode.legacyMarker) {
            installHooks()
            debugLog("claude code: moved hooks from Deckhand to Hangtime")
        }
        let old = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deckhand", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: Files Claude Code runs

    private func prepareFiles() {
        let manager = FileManager.default
        try? manager.createDirectory(at: ClaudeCode.folder, withIntermediateDirectories: true)
        if let saved = try? String(contentsOf: ClaudeCode.tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 32 {
            token = saved
        } else {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try? token.write(to: ClaudeCode.tokenFile, atomically: true, encoding: .utf8)
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ClaudeCode.tokenFile.path)

        let script = """
        #!/bin/sh
        # Hangtime bridge for Claude Code hooks. Does nothing when Hangtime is not running.
        TOKEN=$(cat "$HOME/.hangtime/token" 2>/dev/null)
        if [ "$1" = "permission" ]; then
          curl -s -m 125 -H "X-Hangtime-Token: $TOKEN" -H "Content-Type: application/json" --data-binary @- http://127.0.0.1:\(ClaudeCode.port)/permission 2>/dev/null
          exit 0
        fi
        curl -s -m 2 -H "X-Hangtime-Token: $TOKEN" -H "Content-Type: application/json" --data-binary @- http://127.0.0.1:\(ClaudeCode.port)/event >/dev/null 2>&1
        exit 0

        """
        try? script.write(to: ClaudeCode.hookScript, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ClaudeCode.hookScript.path)
    }

    // MARK: Claude Code settings (~/.claude/settings.json)

    func hooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: ClaudeCode.settingsFile),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(ClaudeCode.marker)
    }

    /// Adds Hangtime's hooks next to any hooks you already have. Keeps a backup of the file.
    @discardableResult
    func installHooks() -> Bool {
        let url = ClaudeCode.settingsFile
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                debugLog("claude code: settings.json is not valid JSON, not touching it")
                return false
            }
            root = parsed
            let folder = url.deletingLastPathComponent()
            let backup = folder.appendingPathComponent("settings.json.hangtime-backup")
            let older = folder.appendingPathComponent("settings.json.deckhand-backup")   // original from before the rename
            if !FileManager.default.fileExists(atPath: backup.path) && !FileManager.default.fileExists(atPath: older.path) {
                try? data.write(to: backup)
            }
        }
        var hooks = ClaudeCode.withoutOurs(root["hooks"] as? [String: Any] ?? [:])
        func add(_ event: String, _ mode: String, _ timeout: Int) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": "\"$HOME/\(ClaudeCode.marker)\" \(mode)", "timeout": timeout]]])
            hooks[event] = groups
        }
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd"] {
            add(event, "event", 5)
        }
        add("PermissionRequest", "permission", 130)
        root["hooks"] = hooks
        let saved = write(root, to: url)
        connected = saved && hooksInstalled()
        return connected
    }

    func removeHooks() {
        let url = ClaudeCode.settingsFile
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let hooks = ClaudeCode.withoutOurs(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        _ = write(root, to: url)
        connected = hooksInstalled()
    }

    private func write(_ root: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private static func withoutOurs(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                let inner = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    let command = $0["command"] as? String ?? ""
                    return !command.contains(marker) && !command.contains(legacyMarker)
                }
                if inner.isEmpty && group["hooks"] != nil { continue }
                group["hooks"] = inner
                kept.append(group)
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    // MARK: Local server

    private func startServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ClaudeCode.port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.serverRunning = true
                    case .failed(let error):
                        debugLog("bridge failed: \(error)")
                        self?.serverRunning = false
                    case .cancelled: self?.serverRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            debugLog("bridge could not start: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        if case .hostPort(let host, _) = connection.endpoint {
            let text = "\(host)"
            if !(text.hasPrefix("127.") || text == "::1" || text.hasPrefix("localhost")) {
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, finished, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                self.route(request, connection)
            } else if finished || error != nil || buffer.count > 4_000_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ body: String, status: String = "200 OK") {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func route(_ request: HTTPRequest, _ connection: NWConnection) {
        guard request.method == "POST", request.headers["x-hangtime-token"] == token else {
            respond(connection, "", status: "403 Forbidden")
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch request.path {
        case "/event":
            respond(connection, "")
            DispatchQueue.main.async { self.handleEvent(json) }
        case "/permission":
            DispatchQueue.main.async { self.handlePermission(json, connection) }
        default:
            respond(connection, "", status: "404 Not Found")
        }
    }

    // MARK: Events -> status lights

    private static func project(_ cwd: String) -> String {
        cwd.isEmpty ? "Claude Code" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func update(_ id: String, cwd: String, state: State, detail: String, symbol: String? = nil) {
        let previous = sessions.first { $0.id == id }?.state
        if sessions.firstIndex(where: { $0.id == id }) == nil {
            sessions.insert(Session(id: id, project: ClaudeCode.project(cwd), cwd: cwd, state: state, detail: detail, updated: Date()), at: 0)
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if state == .working && previous != .working {
            sessions[index].started = Date()
        }
        sessions[index].state = state
        sessions[index].detail = detail
        if let symbol = symbol { sessions[index].symbol = symbol }
        sessions[index].updated = Date()
        if !cwd.isEmpty {
            sessions[index].cwd = cwd
            sessions[index].project = ClaudeCode.project(cwd)
        }
        if state == .done && previous == .working {
            NSSound(named: "Glass")?.play()
            let done = Finished(project: sessions[index].project, files: sessions[index].files.count, date: Date())
            finished = done
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if self?.finished == done { self?.finished = nil }
            }
        }
        if state == .error && previous != .error {
            NSSound(named: "Basso")?.play()
        }
    }

    /// What Claude is doing right now, in plain words, plus a matching symbol.
    private static func describe(tool: String, input: [String: Any]) -> (String, String) {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return ("Editing " + (file ?? "a file"), "pencil")
        case "Read":
            return ("Reading " + (file ?? "a file"), "doc.text.magnifyingglass")
        case "Bash":
            let command = (input["command"] as? String ?? "").components(separatedBy: .newlines).first ?? ""
            return ("Running " + String(command.prefix(40)), "terminal")
        case "Grep", "Glob":
            return ("Searching " + String((input["pattern"] as? String ?? "the code").prefix(30)), "magnifyingglass")
        case "WebFetch", "WebSearch":
            return ("Browsing the web", "globe")
        case "Task", "Agent":
            return ("Running a helper", "person.2.fill")
        case "TodoWrite":
            return ("Planning", "checklist")
        default:
            return (tool, "sparkle")
        }
    }

    private static func lines(_ text: String?) -> Int {
        guard let text = text, !text.isEmpty else { return 0 }
        return text.components(separatedBy: "\n").count
    }

    /// After an edit lands, remember the file and roughly how many lines changed.
    private func recordChange(_ id: String, tool: String, input: [String: Any]) {
        guard ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool),
              let path = input["file_path"] as? String ?? input["notebook_path"] as? String,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var added = 0
        var removed = 0
        switch tool {
        case "Edit":
            added = ClaudeCode.lines(input["new_string"] as? String)
            removed = ClaudeCode.lines(input["old_string"] as? String)
        case "MultiEdit":
            for edit in input["edits"] as? [[String: Any]] ?? [] {
                added += ClaudeCode.lines(edit["new_string"] as? String)
                removed += ClaudeCode.lines(edit["old_string"] as? String)
            }
        case "Write":
            added = ClaudeCode.lines(input["content"] as? String)
        default:
            added = ClaudeCode.lines(input["new_source"] as? String)
        }
        if let existing = sessions[index].files.firstIndex(where: { $0.path == path }) {
            sessions[index].files[existing].added += added
            sessions[index].files[existing].removed += removed
        } else {
            sessions[index].files.append(ChangedFile(path: path, added: added, removed: removed))
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let id = json["session_id"] as? String, let event = json["hook_event_name"] as? String else { return }
        let cwd = json["cwd"] as? String ?? ""
        switch event {
        case "SessionStart":
            update(id, cwd: cwd, state: .done, detail: "Ready")
        case "UserPromptSubmit":
            update(id, cwd: cwd, state: .working, detail: "Thinking")
        case "PreToolUse":
            let (text, symbol) = ClaudeCode.describe(tool: json["tool_name"] as? String ?? "Working",
                                                     input: json["tool_input"] as? [String: Any] ?? [:])
            update(id, cwd: cwd, state: .working, detail: text, symbol: symbol)
        case "PostToolUse":
            recordChange(id, tool: json["tool_name"] as? String ?? "", input: json["tool_input"] as? [String: Any] ?? [:])
        case "StopFailure":
            update(id, cwd: cwd, state: .error, detail: "Stopped with an error", symbol: "exclamationmark.triangle.fill")
        case "Notification":
            let type = json["notification_type"] as? String ?? ""
            if ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(type) {
                update(id, cwd: cwd, state: .waiting, detail: json["message"] as? String ?? "Needs you")
            }
        case "Stop":
            update(id, cwd: cwd, state: .done, detail: "Finished")
        case "SessionEnd":
            sessions.removeAll { $0.id == id }
        default:
            break
        }
    }

    /// Finished sessions fade out after a while; a session that stopped talking is no longer "working".
    private func prune() {
        let now = Date()
        sessions.removeAll { now.timeIntervalSince($0.updated) > 3 * 3600 }
        for index in sessions.indices where sessions[index].state == .working && now.timeIntervalSince(sessions[index].updated) > 15 * 60 {
            sessions[index].state = .done
            sessions[index].detail = "Quiet"
        }
        for index in sessions.indices where sessions[index].state == .error && now.timeIntervalSince(sessions[index].updated) > 120 {
            sessions[index].state = .done
        }
    }

    // MARK: Permission requests -> pop-up

    private static func summary(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String { return "\(tool): \(path)" }
        if let url = input["url"] as? String { return "\(tool): \(url)" }
        if let pattern = input["pattern"] as? String { return "\(tool): \(pattern)" }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(300))
        }
        return tool
    }

    private func handlePermission(_ json: [String: Any], _ connection: NWConnection) {
        let id = json["session_id"] as? String ?? UUID().uuidString
        let cwd = json["cwd"] as? String ?? ""
        let tool = json["tool_name"] as? String ?? "Tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let suggestions = json["permission_suggestions"] as? [Any] ?? []
        update(id, cwd: cwd, state: .waiting, detail: "Needs permission")

        var answered = false
        var requestID = UUID()
        let reply: (String) -> Void = { [weak self] body in
            guard !answered else { return }
            answered = true
            self?.respond(connection, body)
            self?.requests.removeAll { $0.id == requestID }
            self?.update(id, cwd: cwd, state: .working, detail: tool)
        }
        let request = Request(session: id, project: ClaudeCode.project(cwd), tool: tool,
                              summary: ClaudeCode.summary(tool: tool, input: input),
                              canAlwaysAllow: !suggestions.isEmpty) { [suggestions] choice in
            reply(ClaudeCode.decision(choice, suggestions: suggestions))
        }
        requestID = request.id
        requests.append(request)
        NSSound(named: "Ping")?.play()
        NoticeCenter.shared.layout()
        // No answer within two minutes: hand the question back to Claude Code's own prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { reply("") }
    }

    /// choice: "allow", "always", "deny", or "" (let Claude Code ask normally).
    private static func decision(_ choice: String, suggestions: [Any]) -> String {
        var decision: [String: Any]
        switch choice {
        case "allow": decision = ["behavior": "allow"]
        case "always": decision = ["behavior": "allow", "updatedPermissions": suggestions]
        case "deny": decision = ["behavior": "deny", "message": "Denied from Hangtime."]
        default: return ""
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: output) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Today's token usage (from ~/.claude/projects/**/*.jsonl)

    private struct FileUsage {
        var size: UInt64
        var day: Date
        var input = 0, output = 0, write = 0, read = 0, messages = 0
        var sessions = Set<String>()
    }

    func scanUsage() {
        usageQueue.async { [weak self] in
            guard let self = self else { return }
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let today = Calendar.current.startOfDay(for: Date())
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var total = FileUsage(size: 0, day: today)
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            var seen = Set<String>()
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= today else { continue }
                let size = UInt64(values.fileSize ?? 0)
                seen.insert(url.path)
                var usage: FileUsage
                if let cached = self.fileCache[url.path], cached.size == size, cached.day == today {
                    usage = cached
                } else {
                    usage = ClaudeCode.read(url, since: today, iso: iso)
                    usage.size = size
                    self.fileCache[url.path] = usage
                }
                total.input += usage.input
                total.output += usage.output
                total.write += usage.write
                total.read += usage.read
                total.messages += usage.messages
                total.sessions.formUnion(usage.sessions)
            }
            self.fileCache = self.fileCache.filter { seen.contains($0.key) }
            let result = total
            debugLog("claude code today: \(result.input + result.output + result.write + result.read) tokens, \(result.sessions.count) sessions, \(result.messages) replies")
            DispatchQueue.main.async {
                self.inputTokens = result.input
                self.outputTokens = result.output
                self.cacheWrite = result.write
                self.cacheRead = result.read
                self.tokens = result.input + result.output + result.write + result.read
                self.messageCount = result.messages
                self.sessionCount = result.sessions.count
                self.usageUpdated = Date()
            }
        }
    }

    private static func read(_ url: URL, since day: Date, iso: ISO8601DateFormatter) -> FileUsage {
        var usage = FileUsage(size: 0, day: day)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return usage }
        var counted = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 20,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let tokens = message["usage"] as? [String: Any],
                  let stamp = object["timestamp"] as? String,
                  let date = iso.date(from: stamp), date >= day else { continue }
            let key = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? "")"
            if key != "|" {
                if counted.contains(key) { continue }
                counted.insert(key)
            }
            usage.input += tokens["input_tokens"] as? Int ?? 0
            usage.output += tokens["output_tokens"] as? Int ?? 0
            usage.write += tokens["cache_creation_input_tokens"] as? Int ?? 0
            usage.read += tokens["cache_read_input_tokens"] as? Int ?? 0
            usage.messages += 1
            if let session = object["sessionId"] as? String { usage.sessions.insert(session) }
        }
        return usage
    }

    static func format(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.1fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }
}

/// Just enough HTTP to read one request from the hook script.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[range.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }
}

// MARK: - Views

struct SessionsPane: View {
    @ObservedObject private var code = ClaudeCode.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                DangleView(size: 16, mood: DangleMood(code.overall), animated: false)
                Text("Claude Code").font(.headline)
                Spacer()
                if !code.sessions.isEmpty {
                    Text("\(code.sessions.count) session\(code.sessions.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if !code.connected {
                Text("Connect Hangtime to Claude Code to see what each session is doing, which files it changed, and to answer permission requests from the notch.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Claude Code") { code.installHooks() }
            } else if code.sessions.isEmpty {
                Text("No sessions right now. Start Claude Code and Dangle will show up here.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(code.sessions) { session in
                        SessionBlock(session: session)
                    }
                }
            }
            .frame(maxHeight: 380)
            if code.connected {
                Divider()
                HStack {
                    Circle().fill(code.serverRunning ? Color.green : Color.red).frame(width: 6, height: 6)
                    Text(code.serverRunning ? "Connected" : "Bridge not running").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Button("Disconnect") { code.removeHooks() }.controlSize(.small)
                }
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    static func color(_ state: ClaudeCode.State) -> Color {
        switch state {
        case .waiting: return Color(red: 0.96, green: 0.71, blue: 0.0)
        case .working: return Color(red: 0.19, green: 0.78, blue: 0.37)
        case .done: return Color.white.opacity(0.5)
        case .error: return Color.red
        }
    }
}

/// One session: what it's doing, plus every file it changed (click to open in VS Code).
struct SessionBlock: View {
    let session: ClaudeCode.Session

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                DangleView(size: 14, mood: DangleMood(session.state), animated: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.project).font(.system(size: 13, weight: .semibold))
                    Text(session.detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Text(RelativeDateTimeFormatter().localizedString(for: session.updated, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if !session.cwd.isEmpty {
                    Button { QuickActions.open([URL(fileURLWithPath: session.cwd)], withApp: "com.apple.Terminal") } label: {
                        Image(systemName: "terminal").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Open this folder in Terminal")
                }
            }
            if !session.files.isEmpty {
                Text("FILES CHANGED · \(session.files.count)").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).padding(.top, 2)
                ForEach(session.files) { file in
                    Button {
                        QuickActions.open([URL(fileURLWithPath: file.path)], withApp: "com.microsoft.VSCode")
                    } label: {
                        HStack(spacing: 6) {
                            Text("+\(file.added)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.green)
                            Text("−\(file.removed)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.red.opacity(0.85))
                            Text(SessionBlock.shortPath(file.path, in: session.cwd)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in VS Code")
                }
            }
        }
    }

    static func shortPath(_ path: String, in folder: String) -> String {
        if !folder.isEmpty, path.hasPrefix(folder + "/") { return String(path.dropFirst(folder.count + 1)) }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
