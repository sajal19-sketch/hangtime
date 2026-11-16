import Foundation
import AppKit
import SwiftUI
import WebKit

/// Reads the plan usage shown on claude.ai's Usage page. You sign in yourself in a
/// normal web view (Hangtime never sees your password); after that Hangtime asks claude.ai
/// for the same numbers the Usage page shows, once a minute, like a browser tab would.
final class ClaudeUsage: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = ClaudeUsage()
    static let usagePage = URL(string: "https://claude.ai/settings/usage")!
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    struct Limit: Identifiable {
        let id: String
        let label: String
        let percent: Double
        let resets: Date?
    }

    @Published var limits: [Limit] = []
    @Published var signedIn: Bool? = nil          // nil = not checked yet
    @Published var message = "Loading"
    @Published var updated: Date? = nil
    @Published var account = ""

    private var webView: WKWebView!
    private var pageReady = false
    private var pending = false
    private var timer: Timer?

    private var loginWindow: NSWindow?
    private var loginView: WKWebView?
    private var urlWatch: NSKeyValueObservation?

    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        webView.customUserAgent = ClaudeUsage.agent
        webView.navigationDelegate = self
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        if pageReady {
            fetchUsage()
        } else {
            pending = true
            webView.load(URLRequest(url: ClaudeUsage.usagePage))
        }
    }

    // MARK: Navigation

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        if view === webView {
            pageReady = view.url?.host?.hasSuffix("claude.ai") == true
            if pending {
                pending = false
                fetchUsage()
            }
        } else if view === loginView {
            checkLogin()
        }
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if view === webView { fail("Offline") }
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if view === webView { fail("Offline") }
    }

    private func fail(_ text: String) {
        pending = false
        pageReady = false
        message = text
    }

    // MARK: Reading usage

    private func fetchUsage() {
        let script = """
        const r = await fetch('/api/organizations', {credentials: 'include'});
        if (!r.ok) { return JSON.stringify({error: String(r.status)}); }
        const orgs = await r.json();
        if (!Array.isArray(orgs) || orgs.length === 0) { return JSON.stringify({error: 'no-org'}); }
        for (const o of orgs) {
            const u = await fetch('/api/organizations/' + o.uuid + '/usage', {credentials: 'include'});
            if (!u.ok) { continue; }
            const t = await u.text();
            if (t.indexOf('utilization') >= 0) {
                return JSON.stringify({name: o.name || '', body: t});
            }
        }
        return JSON.stringify({error: 'no-usage'});
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            DispatchQueue.main.async {
                self?.handle(result)
            }
        }
    }

    private func handle(_ result: Result<Any, Error>) {
        guard case .success(let value) = result,
              let text = value as? String,
              let data = text.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if case .failure(let error) = result { debugLog("claude: script failed \(error.localizedDescription)") }
            pageReady = false
            message = "Couldn't reach claude.ai"
            return
        }
        if let error = outer["error"] as? String {
            debugLog("claude: error \(error)")
            if error == "401" || error == "403" {
                signedIn = false
                limits = []
                message = "Sign in to Claude"
            } else {
                message = error == "no-usage" ? "No usage data" : "Couldn't read usage"
            }
            return
        }
        guard let body = outer["body"] as? String,
              let bodyData = body.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            message = "Couldn't read usage"
            return
        }
        debugLog("claude: usage keys \(json.keys.sorted())")

        var found: [Limit] = []
        for (key, raw) in json {
            guard let item = raw as? [String: Any], let percent = ClaudeUsage.number(item["utilization"]) else { continue }
            found.append(Limit(id: key, label: ClaudeUsage.label(for: key), percent: percent,
                               resets: ClaudeUsage.date(item["resets_at"])))
        }
        let order = ["five_hour": 0, "seven_day": 1]
        found.sort { (order[$0.id] ?? 9, $0.id) < (order[$1.id] ?? 9, $1.id) }

        limits = found
        signedIn = true
        account = outer["name"] as? String ?? ""
        updated = Date()
        message = found.isEmpty ? "No limits reported" : "Live"
        checkAlerts(found)
    }

    /// Pops up once per limit window when the session or the week passes 85%.
    private func checkAlerts(_ found: [Limit]) {
        let defaults = UserDefaults.standard
        var shown = Set(defaults.stringArray(forKey: "usageAlertsShown") ?? [])
        for limit in found where (limit.id == "five_hour" || limit.id == "seven_day") && limit.percent >= 85 {
            let window = limit.resets.map { String(Int($0.timeIntervalSince1970 / 600)) } ?? "none"
            let key = limit.id + ":" + window
            guard !shown.contains(key) else { continue }
            shown.insert(key)
            let what = limit.id == "five_hour" ? "session" : "weekly limit"
            let reset = limit.resets.map { "Resets in " + Countdown.text($0) } ?? "Slow down a little to avoid hitting the limit."
            NoticeCenter.shared.show(NoticeCenter.Alert(
                title: "Claude \(what) at \(Int(limit.percent.rounded()))%",
                detail: reset,
                symbol: "exclamationmark.triangle.fill",
                color: limit.percent >= 95 ? .red : .orange
            ))
        }
        defaults.set(Array(shown.suffix(40)), forKey: "usageAlertsShown")
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "Current session"
        case "seven_day": return "Weekly · all models"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        default:
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Sign in / out

    func signIn() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = loginWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 720), configuration: config)
        view.customUserAgent = ClaudeUsage.agent
        view.navigationDelegate = self
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in to Claude (for Hangtime)"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        loginWindow = window
        loginView = view
        urlWatch = view.observe(\.url, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.checkLogin() }
        }
        view.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    /// Once the sign-in window lands anywhere past the login pages, you're in.
    private func checkLogin() {
        guard let view = loginView, let url = view.url, url.host?.hasSuffix("claude.ai") == true else { return }
        let path = url.path
        let stillLoggingIn = path.hasPrefix("/login") || path.hasPrefix("/magic-link") || path.hasPrefix("/oauth") || path == "/" || path.isEmpty
        if stillLoggingIn { return }
        debugLog("claude: signed in, now at \(path)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.closeLogin()
            self?.pageReady = false
            self?.refresh()
        }
    }

    private func closeLogin() {
        urlWatch = nil
        loginWindow?.orderOut(nil)
        loginWindow = nil
        loginView = nil
    }

    func signOut() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let claude = records.filter { $0.displayName.contains("claude") || $0.displayName.contains("anthropic") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: claude) {
                DispatchQueue.main.async {
                    self.limits = []
                    self.signedIn = false
                    self.pageReady = false
                    self.message = "Signed out"
                }
            }
        }
    }
}

// MARK: - Widget

struct ClaudeWidget: View {
    @ObservedObject private var usage = ClaudeUsage.shared
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    static func color(_ percent: Double) -> Color {
        if percent >= 85 { return .red }
        if percent >= 60 { return .orange }
        return .green
    }

    var body: some View {
        let session = usage.limits.first { $0.id == "five_hour" } ?? usage.limits.first
        let week = usage.limits.first { $0.id == "seven_day" }
        PopTile {
            HStack(spacing: 9) {
                Ring(
                    value: (session?.percent ?? 0) / 100,
                    color: ClaudeWidget.color(session?.percent ?? 0),
                    text: session.map { "\(Int($0.percent.rounded()))" } ?? "–",
                    caption: "SESSION"
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundColor(ClaudeWidget.claudeOrange)
                        Text("Claude").font(.system(size: 12, weight: .semibold))
                    }
                    if usage.signedIn == true, let session = session {
                        TimelineView(.periodic(from: Date(), by: 30)) { context in
                            Text(session.resets.map { "resets " + Countdown.text($0, now: context.date) } ?? usage.message)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        if let week = week {
                            HStack(spacing: 4) {
                                Text("Week").font(.system(size: 9)).foregroundColor(.secondary)
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.12))
                                        Capsule()
                                            .fill(ClaudeWidget.color(week.percent))
                                            .frame(width: proxy.size.width * CGFloat(min(1, week.percent / 100)))
                                    }
                                }
                                .frame(height: 4)
                                Text("\(Int(week.percent.rounded()))%").font(.system(size: 9, weight: .bold)).monospacedDigit()
                            }
                        }
                    } else {
                        Text(usage.signedIn == false ? "Click to sign in" : usage.message)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 96, alignment: .leading)
            }
        } content: {
            ClaudePane()
        }
    }
}

struct ClaudePane: View {
    @ObservedObject private var usage = ClaudeUsage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundColor(ClaudeWidget.claudeOrange)
                Text("Claude usage").font(.headline)
                Spacer()
                if usage.signedIn == true {
                    Text(usage.message).font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                }
            }
            if usage.signedIn != true {
                Text("Sign in to Claude in the window that opens. You type your details into claude.ai itself; Hangtime never sees your password. After that it shows your usage limits here and updates every minute.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tip: use “Continue with email”. Google sign-in may not work inside apps.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign in to Claude") { usage.signIn() }
            } else {
                if !usage.account.isEmpty {
                    Text(usage.account).font(.system(size: 11)).foregroundColor(.secondary)
                }
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(usage.limits) { limit in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(limit.label).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text("\(Int(limit.percent.rounded()))% used")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundColor(ClaudeWidget.color(limit.percent))
                                }
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.12))
                                        Capsule()
                                            .fill(ClaudeWidget.color(limit.percent))
                                            .frame(width: proxy.size.width * CGFloat(min(1, limit.percent / 100)))
                                    }
                                }
                                .frame(height: 6)
                                if let resets = limit.resets {
                                    Text("Resets in \(Countdown.text(resets, now: context.date)) · \(resets.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                if let updated = usage.updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Button("Refresh") { usage.refresh() }
                Button("Open usage page") { NSWorkspace.shared.open(ClaudeUsage.usagePage) }
                if usage.signedIn == true {
                    Spacer()
                    Button("Sign out") { usage.signOut() }
                }
            }
        }
        .frame(width: 310, alignment: .leading)
    }
}
