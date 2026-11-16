import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Building blocks

/// Small piece of view-local state (used instead of @State so the app builds
/// with Apple's Command Line Tools alone, without the full Xcode).
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// Sizes follow the system Dock's icon size so the bar is as tall as the Dock.
enum Metrics {
    static let icon: CGFloat = {
        let size = UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 0
        if size <= 0 { return 56 }
        return CGFloat(min(max(size, 44), 72))
    }()
    static var tile: CGFloat { icon + 12 }
}

/// macOS's own frosted glass, so the bar picks up the colours of whatever is behind it.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Buttons shrink slightly while pressed, which makes the bar feel responsive.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The glass (or solid) background shared by the bar and every pop-up window.
struct GlassBackground: View {
    @ObservedObject private var store = Store.shared
    var radius: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if store.barStyle == .glass {
                VisualEffect().clipShape(shape)
                shape.fill(Color.black.opacity(0.30))
            } else {
                shape.fill(Color(white: 0.035).opacity(0.97))
            }
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }
}

struct Tile<Content: View>: View {
    @ObservedObject private var store = Store.shared
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(.horizontal, padding)
            .frame(height: Metrics.tile)
            .background(shape.fill(store.barStyle == .glass ? Color.white.opacity(0.08) : Color(white: 0.11)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// A tile that opens a popover when clicked.
struct PopTile<Label: View, Content: View>: View {
    @ObservedObject private var store = Store.shared
    @StateObject private var showing = Box(false)
    let padding: CGFloat
    let label: Label
    let content: Content

    init(padding: CGFloat = 10, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.label = label()
        self.content = content()
    }

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            showing.value.toggle()
        } label: {
            Tile(padding: padding) { label }
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .popover(isPresented: $showing.value, arrowEdge: store.atTop ? .bottom : .top) {
            content.padding(14)
        }
    }
}

/// A small icon button that opens a popover when clicked.
struct PopIcon<Content: View>: View {
    @ObservedObject private var store = Store.shared
    @StateObject private var showing = Box(false)
    let symbol: String
    let hint: String
    let content: Content

    init(_ symbol: String, hint: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            showing.value.toggle()
        } label: {
            IconFace(symbol: symbol, active: showing.value)
        }
        .buttonStyle(Pressable())
        .help(hint)
        .popover(isPresented: $showing.value, arrowEdge: store.atTop ? .bottom : .top) {
            content.padding(14)
        }
    }
}

/// A small icon button that runs something straight away.
struct IconButton: View {
    let symbol: String
    let hint: String
    let run: () -> Void

    init(_ symbol: String, hint: String, run: @escaping () -> Void) {
        self.symbol = symbol
        self.hint = hint
        self.run = run
    }

    var body: some View {
        Button(action: run) { IconFace(symbol: symbol, active: false) }
            .buttonStyle(Pressable())
            .help(hint)
    }
}

struct IconFace: View {
    let symbol: String
    let active: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(active ? 0.16 : 0)))
            .contentShape(Rectangle())
    }
}

struct PaneTitle: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundColor(Store.shared.accentColor)
            Text(text).font(.headline)
        }
    }
}

struct SmallLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
    }
}

/// A thin rounded progress bar.
struct ProgressLine: View {
    let value: Double          // 0...1
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, proxy.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: height)
    }
}

struct Ring: View {
    let value: Double
    let color: Color
    let text: String
    let caption: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, value))))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: value)
            VStack(spacing: -1) {
                Text(text)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: Metrics.tile - 18, height: Metrics.tile - 18)
    }
}

struct Sparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                path(in: proxy.size, closed: true)
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                path(in: proxy.size, closed: false)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func path(in size: CGSize, closed: Bool) -> Path {
        var path = Path()
        guard samples.count > 1, size.width > 0, size.height > 0 else { return path }
        let step = size.width / CGFloat(samples.count - 1)
        for (index, sample) in samples.enumerated() {
            let clamped = CGFloat(max(0, min(1, sample)))
            let point = CGPoint(x: CGFloat(index) * step, y: size.height - 1 - clamped * (size.height - 2))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

enum Countdown {
    static func text(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds < 0 { return "now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }
}

// MARK: - The bar

struct DockView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var layout = DockLayout.shared

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                ForEach([store.page], id: \.self) { index in
                    PageView(page: DockPage.all[min(max(index, 0), DockPage.all.count - 1)])
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 16)),
                            removal: .opacity
                        ))
                }
            }
            SideColumn()
        }
        .padding(8)
        .background(GlassBackground())
        .fixedSize()
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.page)
        .scaleEffect(layout.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PageView: View {
    let page: DockPage
    @ObservedObject private var store = Store.shared

    var body: some View {
        let shown = page.kinds.filter { store.isOn($0) }
        HStack(spacing: 6) {
            ForEach(shown) { kind in
                WidgetView(kind: kind)
            }
            if shown.isEmpty {
                Tile {
                    Text("All \(page.name) widgets are off. Turn them on in Settings.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct WidgetView: View {
    let kind: WidgetKind

    var body: some View {
        switch kind {
        case .files: FilesWidget()
        case .tools: ToolsWidget()
        case .system: SystemWidget()
        case .music: MusicWidget()
        case .links: LinksWidget()
        case .due: DueWidget()
        case .claude: ClaudeWidget()
        case .tokens: TokensWidget()
        case .ask: AskAIWidget()
        case .projects: ProjectsWidget()
        case .github: GitHubWidget()
        }
    }
}

/// Right edge of the bar: Claude Code status dot, page dots, settings.
struct SideColumn: View {
    var body: some View {
        VStack(spacing: 7) {
            StatusDot()
            PageDots()
            SettingsButton()
        }
        .frame(width: 18, height: Metrics.tile)
    }
}

/// Dangle sits at the top of the bar's right edge: it glows amber when a Claude Code
/// session is waiting for you, swings while one is working, and dims when nothing runs.
struct StatusDot: View {
    @ObservedObject private var code = ClaudeCode.shared
    @ObservedObject private var store = Store.shared
    @StateObject private var showing = Box(false)

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            showing.value.toggle()
        } label: {
            DangleView(size: 15, mood: DangleMood(code.overall))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help("Claude Code sessions and files changed")
        .popover(isPresented: $showing.value, arrowEdge: store.atTop ? .bottom : .top) {
            SessionsPane().padding(14)
        }
    }
}

struct PageDots: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        Button {
            store.page = (store.page + 1) % DockPage.all.count
        } label: {
            VStack(spacing: 4) {
                ForEach(DockPage.all) { page in
                    Capsule()
                        .fill(page.id == store.page ? store.accentColor : Color.white.opacity(0.28))
                        .frame(width: 5, height: page.id == store.page ? 12 : 5)
                }
            }
            .frame(width: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help("\(DockPage.all[min(store.page, DockPage.all.count - 1)].name) page. Click, or swipe on the bar, to change page.")
        .contextMenu {
            ForEach(DockPage.all) { page in
                Button(page.name) { store.page = page.id }
            }
        }
    }
}

struct SettingsButton: View {
    @ObservedObject private var store = Store.shared
    @StateObject private var showing = Box(false)

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            PermissionCheck.shared.refresh()
            showing.value.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 18, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help("Settings")
        .popover(isPresented: $showing.value, arrowEdge: store.atTop ? .bottom : .top) {
            SettingsPane().padding(14)
        }
    }
}

// MARK: - Settings

struct SettingsPane: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PaneTitle(text: "Hangtime", symbol: "dock.rectangle")

                PermissionsSection()

                Divider()
                Group {
                    SmallLabel(text: "Look")
                    Picker("Style", selection: $store.style) {
                        ForEach(BarStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 8) {
                        ForEach(Accent.allCases) { accent in
                            Button {
                                store.accent = accent.rawValue
                            } label: {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: store.accent == accent.rawValue ? 2 : 0))
                            }
                            .buttonStyle(Pressable())
                            .help(accent.title)
                        }
                    }
                }

                Divider()
                Group {
                    SmallLabel(text: "Behaviour")
                    Toggle("Open at login", isOn: $store.launchAtLogin)
                    Toggle("Auto-hide", isOn: $store.autoHide)
                    Toggle("Drop down from the top (near the camera)", isOn: $store.atTop)
                    Toggle("Show Dangle and Claude Code activity under the notch", isOn: $store.showActivity)
                    HStack {
                        Text("Trigger area").font(.system(size: 12))
                        Slider(value: $store.triggerWidth, in: 100...600)
                    }
                    Text("⌃⌥Space keeps the bar open · ⌘⇧Space opens the mini AI window")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Divider()
                Group {
                    SmallLabel(text: "GitHub")
                    HStack {
                        TextField("GitHub username", text: $store.githubUser)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { GitHubActivity.shared.refresh() }
                        Button("Update") { GitHubActivity.shared.refresh() }
                    }
                }

                Divider()
                SmallLabel(text: "Widgets")
                ForEach(DockPage.all) { page in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.name).font(.system(size: 11, weight: .semibold))
                        ForEach(page.kinds) { kind in
                            Toggle(kind.title, isOn: Binding(
                                get: { store.isOn(kind) },
                                set: { store.set(kind, $0) }
                            ))
                        }
                    }
                }

                Divider()
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Quit Hangtime") { NSApp.terminate(nil) }
                }
            }
            .padding(.trailing, 6)
        }
        .frame(width: 340, height: 520)
    }
}
