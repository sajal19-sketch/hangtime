import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - Widgets and pages

enum WidgetKind: String, CaseIterable, Identifiable {
    case files, tools, system, music, links
    case claude, tokens, ask
    case due, projects, github

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files (downloads, shelf, folders)"
        case .tools: return "Notes, clipboard, search, actions"
        case .system: return "CPU + memory"
        case .music: return "Now playing + volume"
        case .links: return "Quick links (open in Chrome)"
        case .claude: return "Claude usage"
        case .tokens: return "Claude Code today"
        case .ask: return "Ask AI"
        case .projects: return "Projects"
        case .github: return "GitHub activity"
        case .due: return "Due soon (course deadlines)"
        }
    }
}

struct DockPage: Identifiable {
    let id: Int
    let name: String
    let symbol: String
    let kinds: [WidgetKind]

    static let all: [DockPage] = [
        DockPage(id: 0, name: "Mac", symbol: "laptopcomputer", kinds: [.files, .tools, .system, .music]),
        DockPage(id: 1, name: "Claude", symbol: "sparkle", kinds: [.claude, .tokens, .ask]),
        DockPage(id: 2, name: "Code", symbol: "chevron.left.forwardslash.chevron.right", kinds: [.due, .projects, .links, .github])
    ]
}

struct QuickLink: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var symbol: String
}

enum Accent: String, CaseIterable, Identifiable {
    case blue, purple, green, orange, pink, mono

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.35, green: 0.61, blue: 1.0)
        case .purple: return Color(red: 0.62, green: 0.42, blue: 1.0)
        case .green: return Color(red: 0.22, green: 0.80, blue: 0.42)
        case .orange: return Color(red: 1.0, green: 0.60, blue: 0.18)
        case .pink: return Color(red: 1.0, green: 0.36, blue: 0.56)
        case .mono: return Color(white: 0.88)
        }
    }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case glass, midnight

    var id: String { rawValue }
    var title: String { self == .glass ? "Dark glass" : "Solid dark" }
}

enum AIService: String, CaseIterable, Identifiable {
    case claude, gemini

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Gemini" }
    var color: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.30, green: 0.55, blue: 1.0) }
}

// MARK: - Store

/// Everything the user can change, saved to UserDefaults.
final class Store: ObservableObject {
    static let shared = Store()
    private let defaults = UserDefaults.standard

    @Published var enabled: [String] { didSet { defaults.set(enabled, forKey: "enabled6") } }
    @Published var atTop: Bool { didSet { defaults.set(atTop, forKey: "atTop2") } }
    @Published var autoHide: Bool { didSet { defaults.set(autoHide, forKey: "autoHide2") } }
    @Published var page: Int
    @Published var notes: String { didSet { defaults.set(notes, forKey: "notes") } }
    @Published var accent: String { didSet { defaults.set(accent, forKey: "accent") } }
    @Published var style: String { didSet { defaults.set(style, forKey: "style") } }
    @Published var triggerWidth: Double { didSet { defaults.set(triggerWidth, forKey: "triggerWidth") } }
    @Published var shelf: [String] { didSet { defaults.set(shelf, forKey: "shelf") } }
    @Published var filesTab: Int { didSet { defaults.set(filesTab, forKey: "filesTab") } }
    @Published var pinnedFolders: [String] { didSet { defaults.set(pinnedFolders, forKey: "pinnedFolders") } }
    @Published var extraProjects: [String] { didSet { defaults.set(extraProjects, forKey: "extraProjects") } }
    @Published var hiddenProjects: [String] { didSet { defaults.set(hiddenProjects, forKey: "hiddenProjects") } }
    @Published var savedPrompts: [String] { didSet { defaults.set(savedPrompts, forKey: "savedPrompts") } }
    @Published var githubUser: String { didSet { defaults.set(githubUser, forKey: "githubUser") } }
    @Published var showActivity: Bool { didSet { defaults.set(showActivity, forKey: "showActivity") } }
    @Published var askService: String { didSet { defaults.set(askService, forKey: "askService") } }
    @Published var quickLinks: [QuickLink] {
        didSet { if let data = try? JSONEncoder().encode(quickLinks) { defaults.set(data, forKey: "quickLinks") } }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            LoginItem.set(launchAtLogin)
        }
    }

    private init() {
        let d = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list = d.stringArray(forKey: "enabled6") ?? WidgetKind.allCases.map { $0.rawValue }
        if !d.bool(forKey: "added.links") {          // new widget: switch it on once
            if !list.contains(WidgetKind.links.rawValue) { list.append(WidgetKind.links.rawValue) }
            d.set(true, forKey: "added.links")
            d.set(list, forKey: "enabled6")
        }
        if !d.bool(forKey: "added.due") {            // deadline reminders: switch the tile on once
            if !list.contains(WidgetKind.due.rawValue) { list.append(WidgetKind.due.rawValue) }
            d.set(true, forKey: "added.due")
            d.set(list, forKey: "enabled6")
        }
        if !d.bool(forKey: "added.github") {         // GitHub activity came back: switch it on once
            if !list.contains(WidgetKind.github.rawValue) { list.append(WidgetKind.github.rawValue) }
            d.set(true, forKey: "added.github")
            d.set(list, forKey: "enabled6")
        }
        enabled = list
        atTop = (d.object(forKey: "atTop2") as? Bool) ?? true
        autoHide = (d.object(forKey: "autoHide2") as? Bool) ?? true
        page = 0                                   // always open on the Mac page
        githubUser = d.string(forKey: "githubUser") ?? ""
        notes = d.string(forKey: "notes") ?? ""
        accent = d.string(forKey: "accent") ?? Accent.blue.rawValue
        if !d.bool(forKey: "glass3") {             // version 3 switches everyone to the glass look once
            d.set(BarStyle.glass.rawValue, forKey: "style")
            d.set(true, forKey: "glass3")
        }
        style = d.string(forKey: "style") ?? BarStyle.glass.rawValue
        let width = d.double(forKey: "triggerWidth")
        triggerWidth = width > 0 ? width : 220
        shelf = d.stringArray(forKey: "shelf") ?? []
        filesTab = min(max(d.integer(forKey: "filesTab"), 0), 2)
        pinnedFolders = d.stringArray(forKey: "pinnedFolders") ?? [home + "/Documents", home + "/Desktop"]
        extraProjects = d.stringArray(forKey: "extraProjects") ?? []
        hiddenProjects = d.stringArray(forKey: "hiddenProjects") ?? []
        savedPrompts = d.stringArray(forKey: "savedPrompts") ?? [
            "Tailor my resume to this job description:",
            "Explain this code in simple words:",
            "Write a short commit message for these changes:",
            "Review this code for bugs:"
        ]
        showActivity = (d.object(forKey: "showActivity") as? Bool) ?? true
        askService = d.string(forKey: "askService") ?? AIService.claude.rawValue
        launchAtLogin = (d.object(forKey: "launchAtLogin") as? Bool) ?? true
        let defaultLinks = [
            QuickLink(name: "Gmail", url: "https://mail.google.com", symbol: "envelope.fill"),
            QuickLink(name: "Calendar", url: "https://calendar.google.com", symbol: "calendar"),
            QuickLink(name: "Drive", url: "https://drive.google.com", symbol: "doc.text.fill"),
            QuickLink(name: "Sheets", url: "https://docs.google.com/spreadsheets/u/0/", symbol: "tablecells.fill"),
            QuickLink(name: "GitHub", url: "https://github.com", symbol: "star.fill")
        ]
        if d.bool(forKey: "links.v2"),
           let data = d.data(forKey: "quickLinks"), let saved = try? JSONDecoder().decode([QuickLink].self, from: data) {
            quickLinks = saved
        } else {
            quickLinks = defaultLinks                 // your own links (version 2) replace the first guesses once
            d.set(true, forKey: "links.v2")
            if let data = try? JSONEncoder().encode(defaultLinks) { d.set(data, forKey: "quickLinks") }
        }
    }

    var accentColor: Color { (Accent(rawValue: accent) ?? .blue).color }
    var barStyle: BarStyle { BarStyle(rawValue: style) ?? .glass }
    var service: AIService { AIService(rawValue: askService) ?? .claude }

    func isOn(_ kind: WidgetKind) -> Bool {
        enabled.contains(kind.rawValue)
    }

    func set(_ kind: WidgetKind, _ on: Bool) {
        if on {
            if !enabled.contains(kind.rawValue) { enabled.append(kind.rawValue) }
        } else {
            enabled.removeAll { $0 == kind.rawValue }
        }
    }
}
