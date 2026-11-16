import AppKit
import SwiftUI
import WebKit
import QuartzCore

/// A small glass window in the top-left corner with Claude (or Gemini) inside.
/// It uses the same sign-in as the Claude usage widget, so your chats are the
/// same ones you see in the Claude app.
final class MiniAI: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = MiniAI()
    static let size = NSSize(width: 430, height: 640)
    static let home: [AIService: URL] = [
        .claude: URL(string: "https://claude.ai/new")!,
        .gemini: URL(string: "https://gemini.google.com/app")!
    ]
    static let apps: [AIService: String] = [.claude: "com.anthropic.claudefordesktop", .gemini: "com.google.GeminiMacOS"]

    @Published var service: AIService = .claude
    @Published var pinned = false
    @Published var visible = false

    private var panel: MiniPanel?
    private var views: [AIService: WKWebView] = [:]
    private var resignObserver: Any?

    func webView(for service: AIService) -> WKWebView {
        if let view = views[service] { return view }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = ClaudeUsage.agent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: MiniAI.home[service]!))
        views[service] = view
        return view
    }

    // MARK: Showing and hiding

    func toggle() {
        if visible { hide() } else { show() }
    }

    func show(_ service: AIService? = nil, then action: ((WKWebView) -> Void)? = nil) {
        if let service = service { self.service = service }
        let panel = self.panel ?? makePanel()
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let area = screen?.visibleFrame {
            let frame = NSRect(x: area.minX + 12, y: area.maxY - MiniAI.size.height - 12,
                               width: MiniAI.size.width, height: MiniAI.size.height)
            if !visible {
                panel.setFrame(frame.offsetBy(dx: -20, dy: 0), display: false)
                panel.alphaValue = 0
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        visible = true
        let view = webView(for: self.service)
        whenReady(view, attempts: 25) { found in
            if found { action?(view) }
        }
    }

    func hide() {
        guard let panel = panel else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    func reload() {
        webView(for: service).load(URLRequest(url: MiniAI.home[service]!))
    }

    func openFullApp() {
        if let bundle = MiniAI.apps[service], QuickActions.appInstalled(bundle) {
            QuickActions.openApp(bundle)
        } else {
            NSWorkspace.shared.open(webView(for: service).url ?? MiniAI.home[service]!)
        }
        if !pinned { hide() }
    }

    private func makePanel() -> MiniPanel {
        let panel = MiniPanel(
            contentRect: NSRect(origin: .zero, size: MiniAI.size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 340, height: 420)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: MiniAIView())
        self.panel = panel
        // Clicking into another app hides the window, unless it is pinned.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.visible, !self.pinned else { return }
            self.hide()
        }
        return panel
    }

    // MARK: Typing into the page

    private static let focusScript = """
    (function(){var e=document.querySelector('div.ProseMirror[contenteditable=true]')||document.querySelector('rich-textarea [contenteditable=true]')||document.querySelector('[contenteditable=true]')||document.querySelector('textarea');if(!e){return false;}e.focus();return true;})()
    """

    /// Waits until the chat box exists (the page may still be loading), then focuses it.
    private func whenReady(_ view: WKWebView, attempts: Int, _ done: @escaping (Bool) -> Void) {
        view.evaluateJavaScript(MiniAI.focusScript) { [weak self] result, _ in
            if (result as? Bool) == true {
                self?.panel?.makeFirstResponder(view)
                done(true)
            } else if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.whenReady(view, attempts: attempts - 1, done)
                }
            } else {
                done(false)
            }
        }
    }

    private static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// Opens the window and types `text` into the chat box (you press Return to send).
    func ask(_ text: String, service: AIService? = nil) {
        show(service) { view in
            view.evaluateJavaScript("document.execCommand('insertText', false, \(MiniAI.literal(text)))", completionHandler: nil)
        }
    }

    /// Opens the window and starts macOS dictation in the chat box.
    func dictate(_ service: AIService? = nil) {
        show(service) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
            }
        }
    }

    /// Drag over part of the screen; the picture is pasted into the chat so you can ask about it.
    func screenSearch(_ service: AIService? = nil) {
        if visible { hide() }
        let before = NSPasteboard.general.changeCount
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-i", "-c", "-x"]
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                guard NSPasteboard.general.changeCount != before,
                      NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue]) else { return }
                self.show(service) { view in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        view.window?.makeFirstResponder(view)
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    }
                }
            }
        }
    }

    // MARK: WebKit

    /// The page's own "attach file" button.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        if let window = self.panel {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    /// Links that want a new window open in your normal browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

/// Borderless, but can still take the keyboard.
final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        MiniAI.shared.hide()
    }
}

/// Lets you drag the borderless window by its header.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shows the web view for the chosen service, keeping both alive so nothing reloads.
struct WebSwitcher: NSViewRepresentable {
    let service: AIService

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        attach(MiniAI.shared.webView(for: service), to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = MiniAI.shared.webView(for: service)
        if view.superview !== container { attach(view, to: container) }
    }

    private func attach(_ view: WKWebView, to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

struct MiniAIView: View {
    @ObservedObject private var mini = MiniAI.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                WindowDragArea()
                HStack(spacing: 6) {
                    ForEach(AIService.allCases) { service in
                        Button {
                            mini.service = service
                            store.askService = service.rawValue
                        } label: {
                            Text(service.title)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(mini.service == service ? service.color : Color.white.opacity(0.10)))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(Pressable())
                    }
                    Spacer()
                    header("arrow.clockwise", "Reload") { mini.reload() }
                    header(mini.pinned ? "pin.fill" : "pin", mini.pinned ? "Unpin (hide when you click elsewhere)" : "Pin (stay open)") { mini.pinned.toggle() }
                        .foregroundColor(mini.pinned ? store.accentColor : .primary)
                    header("arrow.up.forward.app", "Open in the full app") { mini.openFullApp() }
                    header("xmark", "Close (Esc)") { mini.hide() }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 30)
            WebSwitcher(service: mini.service)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .padding(.top, 4)
        .background(GlassBackground(radius: 18))
    }

    private func header(_ symbol: String, _ hint: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help(hint)
    }
}
