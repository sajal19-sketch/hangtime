import AppKit
import SwiftUI
import Carbon
import CoreGraphics

/// One place to see and grant everything Hangtime needs. macOS never lets an app
/// give itself permissions, so each one still needs your click once; after that it sticks
/// (as long as builds are signed with the same certificate, see build.command).
final class PermissionCheck: ObservableObject {
    static let shared = PermissionCheck()

    enum Status { case granted, missing, unknown }

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        var status: Status
    }

    @Published var items: [Item] = []
    @Published var stableSigning: Bool? = nil
    @Published var busy = false

    private static let automationTargets = [
        ("com.apple.systemevents", "System Events"),
        ("com.google.Chrome", "Chrome"),
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music")
    ]

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let files = PermissionCheck.filesStatus()
            let automation = PermissionCheck.automationStatus(ask: false)
            let screen: Status = CGPreflightScreenCaptureAccess() ? .granted : .missing
            let signing = PermissionCheck.signedWithCertificate()
            DispatchQueue.main.async {
                self.items = [
                    Item(id: "files", title: "Files and folders", detail: "Downloads, Documents and Desktop, for the Files and Projects widgets", symbol: "folder.fill", status: files),
                    Item(id: "automation", title: "Control music and dark mode", detail: "YouTube Music in Chrome, Spotify, Music and System Events", symbol: "music.note", status: automation),
                    Item(id: "screen", title: "Screen recording", detail: "Screen search in Ask AI", symbol: "viewfinder", status: screen),
                    Item(id: "claude", title: "Claude Code connection", detail: "Status dot and permission pop-ups", symbol: "terminal.fill",
                         status: ClaudeCode.shared.connected ? .granted : .missing)
                ]
                self.stableSigning = signing
            }
        }
    }

    // MARK: Checks

    private static func filesStatus() -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["Downloads", "Documents", "Desktop"].map { home.appendingPathComponent($0).path }
        let readable = folders.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
        return readable ? .granted : .missing
    }

    /// noErr = allowed, -1743 = denied, -1744 = not asked yet, -600 = app not running.
    private static func automation(_ bundle: String, ask: Bool) -> OSStatus {
        var address = AEAddressDesc()
        let bytes = Array(bundle.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &address)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&address) }
        return AEDeterminePermissionToAutomateTarget(&address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    private static func automationStatus(ask: Bool) -> Status {
        var anyMissing = false
        var anyGranted = false
        for (bundle, _) in automationTargets {
            switch automation(bundle, ask: ask) {
            case noErr: anyGranted = true
            case -1743, -1744: anyMissing = true
            default: break            // app not installed or not running: nothing to ask yet
            }
        }
        if anyMissing { return .missing }
        return anyGranted ? .granted : .unknown
    }

    /// True when the app is signed with the "Hangtime Developer" certificate (permissions survive rebuilds).
    private static func signedWithCertificate() -> Bool {
        let result = Shell.run("/usr/bin/codesign", ["-dvv", Bundle.main.bundlePath])
        return result.output.contains("Authority=Hangtime Developer")
    }

    // MARK: Granting

    func grant(_ id: String) {
        switch id {
        case "files":
            DispatchQueue.global(qos: .userInitiated).async {
                if PermissionCheck.filesStatus() != .granted {
                    PermissionCheck.openSettings("Privacy_FilesAndFolders")
                }
                self.refreshSoon()
            }
        case "automation":
            busy = true
            DispatchQueue.global(qos: .userInitiated).async {
                if let events = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systemevents") {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    NSWorkspace.shared.openApplication(at: events, configuration: config, completionHandler: nil)
                    Thread.sleep(forTimeInterval: 1.0)
                }
                var denied = false
                for (bundle, _) in PermissionCheck.automationTargets where PermissionCheck.automation(bundle, ask: true) == -1743 {
                    denied = true
                }
                if denied { PermissionCheck.openSettings("Privacy_Automation") }
                DispatchQueue.main.async { self.busy = false }
                self.refreshSoon()
            }
        case "screen":
            if !CGRequestScreenCaptureAccess() {
                PermissionCheck.openSettings("Privacy_ScreenCapture")
            }
            refreshSoon()
        case "claude":
            ClaudeCode.shared.installHooks()
            refreshSoon()
        default:
            break
        }
    }

    /// Asks for everything in one go.
    func grantAll() {
        for item in items where item.status != .granted && item.id != "files" {
            grant(item.id)
        }
        if items.first(where: { $0.id == "files" })?.status != .granted { grant("files") }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refresh() }
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }
}

struct PermissionsSection: View {
    @ObservedObject private var check = PermissionCheck.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SmallLabel(text: "Setup")
                Spacer()
                if check.items.contains(where: { $0.status == .missing }) {
                    Button(check.busy ? "Asking…" : "Grant all") { check.grantAll() }
                        .controlSize(.small)
                        .disabled(check.busy)
                }
            }
            ForEach(check.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol).frame(width: 18).foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.system(size: 12, weight: .semibold))
                        Text(item.detail).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer()
                    switch item.status {
                    case .granted:
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    case .missing:
                        Button("Grant") { check.grant(item.id) }.controlSize(.small)
                    case .unknown:
                        Text("Open the app first").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
            if check.stableSigning == false {
                Label("This build isn't signed with the Hangtime certificate, so macOS may ask again after every rebuild. See the steps at the top of build.command.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
