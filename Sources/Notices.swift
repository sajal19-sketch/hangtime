import AppKit
import SwiftUI
import Combine
import QuartzCore

/// A floating glass window under the camera for things that need you right now:
/// Claude Code permission requests and the 85% usage alert. It shows even when the bar is hidden.
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    struct Alert: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let symbol: String
        let color: Color
    }

    @Published var alerts: [Alert] = []
    /// True while the bar is hidden, so Dangle hangs straight from the notch.
    @Published var hanging = true

    /// Bottom edge of the bar while it is visible, so notices sit just below it.
    var barBottom: CGFloat? = nil {
        didSet { if oldValue != barBottom { layout() } }
    }

    private var panel: DockPanel?
    private var hosting: NSView?
    private var bag = Set<AnyCancellable>()

    func start() {
        let panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let hosting = ClickThroughHostingView(rootView: NoticeStack())
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting

        ClaudeCode.shared.$requests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSoon() }
            .store(in: &bag)
        ClaudeCode.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSoon() }
            .store(in: &bag)
        ClaudeCode.shared.$finished
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSoon() }
            .store(in: &bag)
        Deadlines.shared.$showing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSoon() }
            .store(in: &bag)
        Store.shared.$showActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSoon() }
            .store(in: &bag)
        $alerts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutSoon() }
            .store(in: &bag)
    }

    func show(_ alert: Alert) {
        alerts.append(alert)
        NSSound(named: "Submarine")?.play()
    }

    func dismiss(_ alert: Alert) {
        alerts.removeAll { $0.id == alert.id }
    }

    private func layoutSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.layout() }
    }

    /// The session to show in the activity pill: the most recently active one that is working.
    static var activeSession: ClaudeCode.Session? {
        guard Store.shared.showActivity else { return nil }
        return ClaudeCode.shared.sessions.filter { $0.state == .working || $0.state == .error }.max { $0.updated < $1.updated }
    }

    static var showsActivity: Bool {
        activeSession != nil || (Store.shared.showActivity && ClaudeCode.shared.finished != nil)
    }

    /// Height of the notch (or of the menu bar on screens without one).
    private static func notchHeight(_ screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    func layout() {
        guard let panel = panel, let hosting = hosting, let screen = NSScreen.screens.first else { return }
        let hang = barBottom == nil && Store.shared.showActivity
        if hanging != hang { hanging = hang }
        let empty = ClaudeCode.shared.requests.isEmpty && alerts.isEmpty && !NoticeCenter.showsActivity && Deadlines.shared.showing == nil
        if empty {
            if panel.isVisible {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: { panel.orderOut(nil) })
            }
            return
        }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let top = barBottom.map { $0 - 8 } ?? (hang ? screen.frame.maxY - NoticeCenter.notchHeight(screen) : screen.visibleFrame.maxY - 8)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let appearing = !panel.isVisible
        if appearing {
            panel.alphaValue = 0
            panel.setFrame(frame.offsetBy(dx: 0, dy: 12), display: true)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? 0.28 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }
}

struct NoticeStack: View {
    @ObservedObject private var code = ClaudeCode.shared
    @ObservedObject private var center = NoticeCenter.shared
    @ObservedObject private var deadlines = Deadlines.shared

    var body: some View {
        VStack(spacing: 8) {
            if center.hanging {
                HangingDangle(mood: mood)
                    .padding(.bottom, -4)
            }
            if let session = NoticeCenter.activeSession, code.requests.isEmpty {
                ActivityPill(session: session)
            } else if let done = code.finished, code.requests.isEmpty, Store.shared.showActivity {
                DonePill(done: done)
            }
            ForEach(code.requests) { request in
                PermissionCard(request: request)
            }
            if let reminder = deadlines.showing {
                DueCard(reminder: reminder)
            }
            ForEach(center.alerts) { alert in
                AlertCard(alert: alert)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, center.hanging ? 0 : 10)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension NoticeStack {
    var mood: DangleMood {
        if !code.requests.isEmpty { return .waiting }
        if let reminder = deadlines.showing { return reminder.kind == .today ? .error : .waiting }
        if !center.alerts.isEmpty { return .waiting }
        if let session = NoticeCenter.activeSession { return session.state == .error ? .error : .working }
        if code.finished != nil { return .done }
        return .idle
    }
}

/// Dangle hanging from the notch. Waiting: it drops lower on a thread and glows.
/// Done: a quick bounce with a check before it climbs back in.
struct HangingDangle: View {
    let mood: DangleMood
    @StateObject private var bounce = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            if mood == .waiting {
                Rectangle().fill(Color.white.opacity(0.45)).frame(width: 2, height: 14)
            }
            DangleView(size: 40, mood: mood)
                .overlay(alignment: .topTrailing) {
                    if mood == .done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.green))
                            .offset(x: 12, y: 10)
                    }
                }
                .offset(y: bounce.value ? 6 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.35), value: bounce.value)
        }
        .onAppear { if mood == .done { kick() } }
        .onChange(of: mood == .done) { isDone in if isDone { kick() } }
    }

    private func kick() {
        bounce.value = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { bounce.value = false }
    }
}

/// "deckhand · Editing Views.swift · 2m": what Claude is doing right now.
struct ActivityPill: View {
    let session: ClaudeCode.Session
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(SessionsPane.color(session.state)).frame(width: 7, height: 7)
            Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Image(systemName: session.symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(store.accentColor)
            Text(session.detail).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(ActivityPill.elapsed(since: session.started, now: context.date))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(GlassBackground(radius: 16))
        .onTapGesture { QuickActions.open([URL(fileURLWithPath: session.cwd)], withApp: "com.apple.Terminal") }
        .help("Click to open this project in Terminal")
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

struct DonePill: View {
    let done: ClaudeCode.Finished

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text("Done").font(.system(size: 12, weight: .semibold))
            Text("· \(done.project)").font(.system(size: 12)).foregroundColor(.secondary)
            if done.files > 0 {
                Text("· \(done.files) file\(done.files == 1 ? "" : "s") changed").font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(GlassBackground(radius: 16))
    }
}

struct PermissionCard: View {
    let request: ClaudeCode.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 0.96, green: 0.71, blue: 0.0)).frame(width: 8, height: 8)
                Text("Claude Code needs permission").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(request.project).font(.system(size: 11)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(request.tool).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                Text(request.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            HStack(spacing: 8) {
                Button("Answer in Claude") { request.reply("") }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .help("Hand this back to Claude Code's own prompt")
                Spacer()
                pill("Deny", Color.white.opacity(0.12)) { request.reply("deny") }
                if request.canAlwaysAllow {
                    pill("Always allow", Color.white.opacity(0.12)) { request.reply("always") }
                }
                pill("Allow", Color(red: 0.35, green: 0.61, blue: 1.0)) { request.reply("allow") }
            }
        }
        .padding(13)
        .background(GlassBackground(radius: 18))
    }

    private func pill(_ title: String, _ color: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
    }
}

struct AlertCard: View {
    let alert: NoticeCenter.Alert

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.symbol).font(.system(size: 18)).foregroundColor(alert.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(.system(size: 13, weight: .semibold))
                Text(alert.detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Button { NoticeCenter.shared.dismiss(alert) } label: {
                Text("Got it")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(Pressable())
        }
        .padding(13)
        .background(GlassBackground(radius: 18))
    }
}
