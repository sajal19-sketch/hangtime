import AppKit
import SwiftUI
import Combine
import QuartzCore
import Carbon.HIToolbox

/// Writes the first 600 lines of each run to ~/Library/Logs/Hangtime-debug.log.
private let debugLock = NSLock()
private var debugCount = 0
private let debugStart = Date()

func debugLog(_ line: String) {
    debugLock.lock()
    defer { debugLock.unlock() }
    guard debugCount < 600 else { return }
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Hangtime-debug.log")
    if debugCount == 0 {
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    debugCount += 1
    let stamp = String(format: "%6.2f ", Date().timeIntervalSince(debugStart))
    if let data = (stamp + line + "\n").data(using: .utf8) {
        handle.seekToEndOfFile()
        handle.write(data)
    }
    try? handle.close()
}

/// A borderless floating panel that can still take keyboard focus.
final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the very first click on the bar count, even when another app is active.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shared layout state: the bar shrinks itself if it is wider than the screen.
final class DockLayout: ObservableObject {
    static let shared = DockLayout()
    @Published var scale: CGFloat = 1
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: DockPanel!
    var hosting: NSView?
    var ideal = CGSize(width: 900, height: 96)
    var bag = Set<AnyCancellable>()
    var measureTimer: Timer?
    var mouseTimer: Timer?

    var shown = true
    var pinned = false                               // held open with the keyboard shortcut
    var animatingUntil = Date.distantPast
    var lastWanted = Date().addingTimeInterval(3)    // stay visible a few seconds after launch
    var lastLogged = ""
    var lastBusy = ""
    var lastState = ""

    var scrollAccumulated: CGFloat = 0
    var scrollUsed = false
    var scrollCooldown = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("launch")
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }

        panel = DockPanel(
            contentRect: NSRect(origin: .zero, size: ideal),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = ClickThroughHostingView(rootView: DockView())
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.hosting = hosting

        NoticeCenter.shared.start()
        Deadlines.shared.start()
        SystemStats.shared.start()
        NowPlaying.shared.start()
        ClipboardWatcher.shared.start()
        VolumeControl.shared.start()
        FilesModel.shared.start()
        GitHubActivity.shared.start()
        Projects.shared.start()
        ClaudeUsage.shared.start()
        ClaudeCode.shared.start()
        PermissionCheck.shared.refresh()
        LoginItem.removeLegacy()
        LoginItem.set(Store.shared.launchAtLogin)
        debugLog("services started")

        place()
        panel.orderFrontRegardless()

        measureTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.remeasure()
        }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.checkMouse()
        }
        if let timer = mouseTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // Control + Option + Space shows the bar and keeps it open; press again to hide.
        HotKey.register(id: 1, key: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            guard let self = self else { return }
            self.pinned.toggle()
            if self.pinned {
                self.setShown(true)
            } else {
                self.lastWanted = .distantPast
            }
            debugLog("hotkey pinned=\(self.pinned)")
        }
        // Command + Shift + Space opens or closes the mini Claude / Gemini window.
        HotKey.register(id: 2, key: kVK_Space, modifiers: cmdKey | shiftKey) {
            MiniAI.shared.toggle()
        }

        // Two-finger swipe (or mouse wheel) on the bar switches pages.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, event.window === self.panel else { return event }
            self.handleScroll(event)
            return event
        }

        Store.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                debugLog("store changed")
                self?.lastWanted = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.remeasure() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.remeasure() }
            }
            .store(in: &bag)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.place()
        }
        debugLog("ready")

        // Developer check: `Hangtime --snapshot <folder>` saves a picture of each page, then quits.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Task { @MainActor in Snapshot.pages(to: folder) } }
        }
    }

    // MARK: Geometry

    private func dockInset(_ screen: NSScreen) -> CGFloat {
        let defaults = UserDefaults.standard
        let gap = screen.visibleFrame.minY - screen.frame.minY
        if gap > 1 {
            defaults.set(Double(gap), forKey: "dockHeight")
            return gap
        }
        let dock = UserDefaults(suiteName: "com.apple.dock")
        if (dock?.string(forKey: "orientation") ?? "bottom") != "bottom" { return 0 }
        let saved = defaults.double(forKey: "dockHeight")
        if saved > 1 { return CGFloat(saved) }
        let tile = dock?.double(forKey: "tilesize") ?? 0
        return CGFloat(tile > 0 ? tile + 30 : 90)
    }

    /// The window is a full-width transparent strip; the bar is centred inside it.
    private func shownFrame() -> NSRect? {
        guard let screen = NSScreen.screens.first, ideal.width > 1, ideal.height > 1 else { return nil }
        let full = screen.frame
        let scale = min(1, (full.width - 16) / ideal.width)
        if abs(DockLayout.shared.scale - scale) > 0.001 {
            DockLayout.shared.scale = scale
        }
        let height = (ideal.height * scale).rounded(.up)
        let y: CGFloat
        if Store.shared.atTop {
            y = screen.visibleFrame.maxY - height - 4
        } else {
            y = full.minY + dockInset(screen) + 6
        }
        return NSRect(x: full.minX, y: y, width: full.width, height: height)
    }

    private func hiddenFrame(from frame: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first else { return frame }
        var hidden = frame
        hidden.origin.y = Store.shared.atTop ? screen.frame.maxY + 6 : screen.frame.minY - frame.height - 6
        return hidden
    }

    private func barRect() -> NSRect {
        let frame = panel.frame
        let width = ideal.width * DockLayout.shared.scale
        return NSRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
    }

    func place() {
        guard Date() > animatingUntil, let target = shownFrame() else { return }
        let frame = shown ? target : hiddenFrame(from: target)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        panel.alphaValue = shown ? 1 : 0
        NoticeCenter.shared.barBottom = shown && Store.shared.atTop ? frame.minY : nil
        let summary = "ideal=\(Int(ideal.width))x\(Int(ideal.height)) scale=\(String(format: "%.3f", DockLayout.shared.scale)) shown=\(shown) page=\(Store.shared.page)"
        if summary != lastLogged {
            lastLogged = summary
            debugLog(summary)
        }
    }

    private func remeasure() {
        guard let hosting = hosting else { return }
        let size = hosting.intrinsicContentSize
        guard size.width > 1, size.height > 1 else { return }
        if abs(size.width - ideal.width) > 0.5 || abs(size.height - ideal.height) > 0.5 {
            ideal = size
        }
        place()
    }

    // MARK: Show / hide

    private func setShown(_ value: Bool) {
        guard value != shown, let target = shownFrame() else { return }
        shown = value
        let frame = value ? target : hiddenFrame(from: target)
        NoticeCenter.shared.barBottom = value && Store.shared.atTop ? target.minY : nil
        animatingUntil = Date().addingTimeInterval(0.4)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = value ? 0.28 : 0.2
            context.timingFunction = value
                ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                : CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = value ? 1 : 0
        }
    }

    private func checkMouse() {
        guard let screen = NSScreen.screens.first else { return }
        let full = screen.frame
        let mouse = NSEvent.mouseLocation
        let bar = barRect()

        // Only the bar itself catches clicks; the rest of the strip is click-through.
        let overBar = shown && bar.contains(mouse)
        if panel.ignoresMouseEvents == overBar {
            panel.ignoresMouseEvents = !overBar
        }

        if pinned || !Store.shared.autoHide {
            let state = "held open: pinned=\(pinned) autoHide=\(Store.shared.autoHide)"
            if state != lastState {
                lastState = state
                debugLog(state)
            }
            if !shown { setShown(true) }
            return
        }

        let reach = CGFloat(Store.shared.triggerWidth)
        let trigger: Bool
        let barZone = bar.insetBy(dx: -14, dy: -14)
        var keep = barZone
        if Store.shared.atTop {
            trigger = mouse.y >= full.maxY - 5 && abs(mouse.x - full.midX) <= reach
            // The gap between the bar and the camera keeps it open too, but only in the
            // middle of the screen, so using menus or browser tabs elsewhere lets it hide.
            let corridor = NSRect(x: full.midX - reach, y: barZone.minY, width: reach * 2, height: full.maxY - barZone.minY + 2)
            keep = barZone.union(corridor)
        } else {
            let onEdge = mouse.y <= full.minY + 4
            let nearEdge = mouse.y <= full.minY + 200
            let nearSide = mouse.x <= full.minX + reach || mouse.x >= full.maxX - reach
            let onSide = mouse.x <= full.minX + 3 || mouse.x >= full.maxX - 3
            trigger = (onEdge && nearSide) || (onSide && nearEdge)
        }

        let inside = shown && keep.contains(mouse)
        let busy = busyReason()
        let state = "shown=\(shown) pinned=\(pinned) autoHide=\(Store.shared.autoHide) top=\(Store.shared.atTop) trigger=\(trigger) inside=\(inside) busy=\(busy.isEmpty ? "-" : busy)"
        if state != lastState {
            lastState = state
            debugLog(state + " mouse=\(Int(mouse.x)),\(Int(mouse.y))")
        }
        if busy != lastBusy {
            lastBusy = busy
            debugLog("busy -> \(busy.isEmpty ? "none" : busy)")
        }

        if trigger || inside || !busy.isEmpty {
            if lastWanted < Date() { lastWanted = Date() }
            if !shown {
                setShown(true)
                debugLog("show (trigger=\(trigger) inside=\(inside))")
            }
        } else if shown && Date().timeIntervalSince(lastWanted) > 0.6 {
            setShown(false)
            debugLog("hide")
        }
    }

    /// Something of ours that needs the bar to stay put: an open pop-up, the
    /// Add-app dialog, or a right-click menu. Tooltips and leftovers don't count.
    private func busyReason() -> String {
        if NSApp.modalWindow != nil { return "modal" }
        for window in NSApp.windows where window !== panel && window.isVisible && window.alphaValue > 0.01 {
            let name = String(describing: type(of: window))
            if name.contains("Popover") || window is NSOpenPanel || window is NSSavePanel {
                return name
            }
        }
        return ""
    }

    // MARK: Swipe between pages

    private func switchPage(_ direction: Int) {
        let count = DockPage.all.count
        Store.shared.page = (Store.shared.page + direction + count) % count
        scrollCooldown = Date().addingTimeInterval(0.45)
    }

    /// Scrolling up/down (or sideways) anywhere on the bar moves to the next or previous page.
    private func handleScroll(_ event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let delta = abs(dy) >= abs(dx) ? dy : dx
        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: one notch = one page.
            if abs(delta) > 0, Date() > scrollCooldown {
                switchPage(delta < 0 ? 1 : -1)
                debugLog("wheel -> page \(Store.shared.page)")
            }
            return
        }
        // Trackpad: one swipe = one page, momentum is ignored.
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            scrollAccumulated = 0
            scrollUsed = false
        }
        if !event.momentumPhase.isEmpty { return }
        scrollAccumulated += delta
        if !scrollUsed, abs(scrollAccumulated) > 28, Date() > scrollCooldown {
            scrollUsed = true
            switchPage(scrollAccumulated < 0 ? 1 : -1)
            debugLog("swipe -> page \(Store.shared.page)")
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollAccumulated = 0
            scrollUsed = false
        }
    }
}

/// The app used to be called MyDock. macOS keeps settings per app ID, so on the
/// first launch as Hangtime, copy everything saved under the old ID across.
enum Migration {
    static let oldID = "local.mydock.app"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromMyDock") else { return }
        if let old = defaults.persistentDomain(forName: oldID) {
            var copied = 0
            for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
                if defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                    copied += 1
                }
            }
            debugLog("migration: copied \(copied) settings from MyDock")
        }
        defaults.set(true, forKey: "migratedFromMyDock")
        LoginItem.removeLegacy()
    }
}

Migration.run()   // must run before anything reads Store.shared

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
