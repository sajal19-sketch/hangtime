import SwiftUI
import AppKit

// MARK: - Projects (your code folders)

final class Projects: ObservableObject {
    static let shared = Projects()

    struct Project: Identifiable, Equatable {
        var id: String { path }
        let name: String
        let path: String
        let github: URL?
        let touched: Date
    }

    @Published var items: [Project] = []

    private var timer: Timer?
    private let queue = DispatchQueue(label: "hangtime.projects")
    static let markers = [".git", "package.json", "Package.swift", "pyproject.toml", "requirements.txt",
                          "Cargo.toml", "go.mod", "build.command", "pom.xml", "Gemfile"]

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Looks one and two levels into your usual code folders for anything that looks like a project.
    func refresh() {
        let extra = Store.shared.extraProjects
        let hidden = Set(Store.shared.hiddenProjects)
        queue.async { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let roots = ["Documents", "Desktop", "Developer", "Projects", "projects", "code", "Code", "dev", "GitHub", "src"]
                .map { home.appendingPathComponent($0) }
            var found = Set<String>()
            for root in roots {
                for child in Projects.folders(in: root) {
                    if Projects.isProject(child) {
                        found.insert(child.path)
                    } else if !child.lastPathComponent.hasPrefix(".") {
                        for grandchild in Projects.folders(in: child) where Projects.isProject(grandchild) {
                            found.insert(grandchild.path)
                        }
                    }
                }
            }
            found.formUnion(extra.filter { FileManager.default.fileExists(atPath: $0) })
            let list = found.subtracting(hidden).map { path -> Project in
                let url = URL(fileURLWithPath: path)
                return Project(name: url.lastPathComponent, path: path, github: Projects.githubURL(url), touched: Projects.touched(url))
            }
            .sorted { $0.touched > $1.touched }
            DispatchQueue.main.async {
                if list != self?.items { self?.items = list }
            }
        }
    }

    private static func folders(in url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !["node_modules", "Library", "Applications"].contains($0.lastPathComponent)
                && $0.pathExtension.isEmpty
        }
    }

    private static func isProject(_ url: URL) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Most recent change to the folder, its git index, or its sources.
    private static func touched(_ url: URL) -> Date {
        let candidates = [url, url.appendingPathComponent(".git/index"), url.appendingPathComponent(".git/HEAD"), url.appendingPathComponent("Sources")]
        return candidates.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max() ?? .distantPast
    }

    /// Reads the "origin" remote from .git/config and turns it into a github.com link.
    static func githubURL(_ url: URL) -> URL? {
        guard let config = try? String(contentsOf: url.appendingPathComponent(".git/config"), encoding: .utf8) else { return nil }
        for line in config.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("url"), let equals = trimmed.firstIndex(of: "=") else { continue }
            var remote = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard remote.contains("github.com") else { continue }
            if remote.hasPrefix("git@github.com:") {
                remote = "https://github.com/" + remote.dropFirst("git@github.com:".count)
            }
            if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }
            if let at = remote.range(of: "@github.com") { remote = "https://github.com" + remote[at.upperBound...] }
            return URL(string: remote)
        }
        return nil
    }

    static func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Add a project folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                Store.shared.hiddenProjects.removeAll { $0 == url.path }
                if !Store.shared.extraProjects.contains(url.path) { Store.shared.extraProjects.append(url.path) }
            }
            Projects.shared.refresh()
        }
    }

    // Opening a project in each tool.
    static func openCode(_ project: Project) {
        QuickActions.open([URL(fileURLWithPath: project.path)], withApp: "com.microsoft.VSCode")
    }

    static func openTerminal(_ project: Project) {
        QuickActions.open([URL(fileURLWithPath: project.path)], withApp: "com.apple.Terminal")
    }

    static func openFinder(_ project: Project) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }

    static func openGitHub(_ project: Project) {
        if let url = project.github { NSWorkspace.shared.open(url) }
    }
}

struct ProjectActions: View {
    let project: Projects.Project
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            action("chevron.left.forwardslash.chevron.right", "Open in VS Code") { Projects.openCode(project) }
            action("terminal", "Open in Terminal") { Projects.openTerminal(project) }
            action("folder", "Show in Finder") { Projects.openFinder(project) }
            action("arrow.up.right.square", project.github == nil ? "No GitHub remote" : "Open on GitHub") { Projects.openGitHub(project) }
                .opacity(project.github == nil ? 0.3 : 1)
                .disabled(project.github == nil)
        }
    }

    private func action(_ symbol: String, _ hint: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size + 12, height: size + 8)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help(hint)
    }
}

struct ProjectsWidget: View {
    @ObservedObject private var projects = Projects.shared
    @ObservedObject private var store = Store.shared
    @StateObject private var showing = Box(false)

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("PROJECTS").font(.system(size: 8, weight: .heavy)).foregroundColor(.secondary)
                    Spacer()
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        projects.refresh()
                        showing.value.toggle()
                    } label: {
                        Text(projects.items.count > 2 ? "All \(projects.items.count)" : "Manage")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(store.accentColor)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showing.value, arrowEdge: store.atTop ? .bottom : .top) {
                        ProjectsPane().padding(14)
                    }
                }
                if projects.items.isEmpty {
                    Text("No projects found yet").font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(projects.items.prefix(2)) { project in
                    HStack(spacing: 6) {
                        Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        ProjectActions(project: project, size: 10)
                    }
                }
            }
            .frame(width: 230, alignment: .leading)
        }
    }
}

struct ProjectsPane: View {
    @ObservedObject private var projects = Projects.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: "Projects", symbol: "folder.fill.badge.gearshape")
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(projects.items) { project in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            ProjectActions(project: project)
                            Button {
                                store.extraProjects.removeAll { $0 == project.path }
                                if !store.hiddenProjects.contains(project.path) { store.hiddenProjects.append(project.path) }
                                projects.refresh()
                            } label: {
                                Image(systemName: "eye.slash").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("Hide this project")
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    }
                }
            }
            .frame(height: 300)
            HStack {
                Button("Add a folder…") { Projects.addFolder() }
                if !store.hiddenProjects.isEmpty {
                    Button("Show hidden (\(store.hiddenProjects.count))") {
                        store.hiddenProjects.removeAll()
                        projects.refresh()
                    }
                }
                Spacer()
            }
            Text("Found in Documents, Desktop, Developer, Projects and code folders: anything with git, package.json and similar.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 380, alignment: .leading)
    }
}

// MARK: - GitHub activity

struct GitHubWidget: View {
    @ObservedObject private var github = GitHubActivity.shared
    private let green = Color(red: 0.22, green: 0.83, blue: 0.33)

    var body: some View {
        PopTile {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(0..<GitHubActivity.weeks, id: \.self) { week in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { day in
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(color(for: level(week, day)))
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    if github.streak > 0 {
                        Image(systemName: "flame.fill").font(.system(size: 9)).foregroundColor(.orange)
                        Text("\(github.streak) day streak").font(.system(size: 9, weight: .semibold))
                    } else {
                        Text(github.status).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let total = github.total {
                        Text("\(total)").font(.system(size: 9, weight: .bold, design: .rounded))
                    }
                }
            }
            .frame(width: CGFloat(GitHubActivity.weeks) * 8 - 2)
        } content: {
            GitHubPane()
        }
    }

    private func level(_ week: Int, _ day: Int) -> Int {
        let index = week * 7 + day
        return index < github.levels.count ? github.levels[index] : 0
    }

    private func color(for level: Int) -> Color {
        switch level {
        case ..<0: return Color.clear
        case 0: return Color.white.opacity(0.12)
        case 1: return green.opacity(0.35)
        case 2: return green.opacity(0.58)
        case 3: return green.opacity(0.80)
        default: return green
        }
    }
}

struct GitHubPane: View {
    @ObservedObject private var github = GitHubActivity.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneTitle(text: github.status, symbol: "chevron.left.forwardslash.chevron.right")
            HStack(spacing: 8) {
                stat("\(github.total ?? 0)", "this year", "square.grid.3x3.fill", .green)
                stat("\(github.streak)", "day streak", "flame.fill", .orange)
                stat("\(github.longest)", "best streak", "trophy.fill", .yellow)
            }
            if !github.todayActive {
                Label("No contributions yet today: push something to keep the streak going.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            Divider()
            SmallLabel(text: "Recently pushed")
            if github.repos.isEmpty {
                Text("Loading repositories…").font(.system(size: 12)).foregroundColor(.secondary)
            }
            ForEach(github.repos) { repo in
                Button {
                    if let url = URL(string: repo.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack {
                        Image(systemName: "book.closed.fill").foregroundColor(store.accentColor)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(repo.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            HStack(spacing: 6) {
                                if let language = repo.language { Text(language) }
                                if let pushed = repo.pushed {
                                    Text("updated " + RelativeDateTimeFormatter().localizedString(for: pushed, relativeTo: Date()))
                                }
                            }
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                        if repo.stars > 0 {
                            Label("\(repo.stars)", systemImage: "star.fill").font(.system(size: 10))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Open profile") {
                    if let url = URL(string: "https://github.com/" + store.githubUser) { NSWorkspace.shared.open(url) }
                }
                Button("Refresh") { github.refresh() }
            }
        }
        .frame(width: 310, alignment: .leading)
    }

    private func stat(_ value: String, _ caption: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).foregroundColor(color)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(caption).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}
