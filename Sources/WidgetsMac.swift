import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Files model (Downloads, Tailored Resumes, dropped files, pinned folders)

final class FilesModel: ObservableObject {
    static let shared = FilesModel()
    static let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    static let resumesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Tailored Resumes", isDirectory: true)

    @Published var downloads: [URL] = []
    @Published var resumes: [URL] = []

    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private let queue = DispatchQueue(label: "hangtime.files")

    func start() {
        // Opening the folders can show a macOS permission prompt, which would freeze the
        // bar if done on the main thread, so it happens in the background.
        queue.async {
            self.watch(FilesModel.downloadsURL)
            self.watch(FilesModel.resumesURL)
        }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    /// macOS tells us when a folder changes, so new downloads appear right away without polling.
    private func watch(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    func scan() {
        queue.async {
            let downloads = FilesModel.list(FilesModel.downloadsURL, limit: 40)
            let resumes = FilesModel.list(FilesModel.resumesURL, limit: 40)
            DispatchQueue.main.async {
                if downloads != self.downloads { self.downloads = downloads }
                if resumes != self.resumes { self.resumes = resumes }
            }
        }
    }

    /// Newest first. Half-finished downloads are skipped.
    static func list(_ folder: URL, limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let partial: Set<String> = ["crdownload", "download", "part"]
        return items
            .filter { !partial.contains($0.pathExtension.lowercased()) }
            .map { ($0, added($0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    static func added(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && url.pathExtension != "app"
    }

    var shelfItems: [URL] {
        resumes + Store.shared.shelf.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var folderItems: [URL] {
        Store.shared.pinnedFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func items(tab: Int) -> [URL] {
        switch tab {
        case 0: return downloads
        case 1: return shelfItems
        default: return folderItems
        }
    }

    static func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Pin a folder to Hangtime"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !Store.shared.pinnedFolders.contains(url.path) {
                Store.shared.pinnedFolders.append(url.path)
            }
        }
    }
}

/// A coloured symbol per kind of file, instead of the file name.
enum FileStyle {
    static func of(_ url: URL) -> (symbol: String, color: Color) {
        if FilesModel.isFolder(url) { return ("folder.fill", Color(red: 0.36, green: 0.62, blue: 1.0)) }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        func conforms(_ other: UTType) -> Bool { type?.conforms(to: other) ?? false }
        if ext == "app" { return ("app.fill", Color(white: 0.85)) }
        if conforms(.pdf) { return ("doc.richtext.fill", Color(red: 1.0, green: 0.42, blue: 0.43)) }
        if conforms(.image) { return ("photo.fill", Color(red: 0.45, green: 0.68, blue: 1.0)) }
        if conforms(.movie) { return ("film.fill", Color(red: 1.0, green: 0.45, blue: 0.70)) }
        if conforms(.audio) { return ("music.note", Color(red: 0.70, green: 0.52, blue: 1.0)) }
        if conforms(.archive) || ["zip", "dmg", "pkg", "rar", "7z", "gz", "tar"].contains(ext) {
            return ("doc.zipper", Color(red: 1.0, green: 0.80, blue: 0.30))
        }
        if conforms(.spreadsheet) || ["csv", "xlsx", "xls", "numbers"].contains(ext) {
            return ("tablecells.fill", Color(red: 0.45, green: 0.88, blue: 0.58))
        }
        if conforms(.presentation) || ["key", "pptx", "ppt"].contains(ext) {
            return ("rectangle.on.rectangle", Color(red: 1.0, green: 0.62, blue: 0.30))
        }
        if conforms(.sourceCode) || ["swift", "js", "ts", "tsx", "py", "json", "html", "css", "sh", "yml", "yaml"].contains(ext) {
            return ("chevron.left.forwardslash.chevron.right", Color(red: 0.35, green: 0.85, blue: 0.85))
        }
        if conforms(.text) || ["doc", "docx", "pages", "rtf", "md"].contains(ext) {
            return ("doc.text.fill", Color(white: 0.92))
        }
        return ("doc.fill", Color(white: 0.78))
    }
}

/// One file on the tile: just its coloured type icon. Click opens, drag takes it anywhere.
struct FileChip: View {
    let url: URL
    var size: CGFloat = 28

    var body: some View {
        let style = FileStyle.of(url)
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(style.color)
                .frame(width: size, height: size + 2)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.color.opacity(0.20)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.lastPathComponent)
    }
}

/// Left half: your Downloads folder (click to open it). Right half: a shelf you drop files on
/// to keep them handy, then drag them out into any upload box or folder.
struct FilesWidget: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var files = FilesModel.shared
    @StateObject private var showingShelf = Box(false)
    @StateObject private var targeted = Box(false)

    var body: some View {
        let shelf = store.shelf.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        Tile(padding: 8) {
            HStack(spacing: 8) {
                // Downloads
                VStack(alignment: .leading, spacing: 6) {
                    Button { NSWorkspace.shared.open(FilesModel.downloadsURL) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 10))
                            Text("Downloads").font(.system(size: 10, weight: .semibold))
                            Image(systemName: "arrow.up.forward").font(.system(size: 7, weight: .bold)).foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open your Downloads folder")
                    HStack(spacing: 4) {
                        ForEach(Array(files.downloads.prefix(3)), id: \.self) { url in
                            FileChip(url: url, size: 26)
                        }
                        if files.downloads.isEmpty {
                            Text("Empty").font(.system(size: 10)).foregroundColor(.secondary).frame(height: 28)
                        }
                    }
                }
                .frame(width: 92, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(FilesModel.downloadsURL) }

                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: Metrics.tile - 22)

                // Shelf (drop zone)
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        showingShelf.value.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 10))
                            Text(shelf.isEmpty ? "Shelf" : "Shelf · \(shelf.count)").font(.system(size: 10, weight: .semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show everything on the shelf")
                    .popover(isPresented: $showingShelf.value, arrowEdge: store.atTop ? .bottom : .top) {
                        ShelfPane().padding(14)
                    }
                    if shelf.isEmpty {
                        Text("Drop files here")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(targeted.value ? store.accentColor : .secondary)
                            .frame(width: 92, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundColor(targeted.value ? store.accentColor : Color.white.opacity(0.25)))
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(shelf.suffix(shelf.count > 3 ? 2 : 3).reversed()), id: \.self) { url in
                                FileChip(url: url, size: 26)
                                    .contextMenu {
                                        Button("Open") { NSWorkspace.shared.open(url) }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                        Button("Remove from shelf") { store.shelf.removeAll { $0 == url.path } }
                                    }
                            }
                            if shelf.count > 3 {
                                Button {
                                    NSApp.activate(ignoringOtherApps: true)
                                    showingShelf.value.toggle()
                                } label: {
                                    Text("+\(shelf.count - 2)")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(width: 26, height: 28)
                                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.10)))
                                }
                                .buttonStyle(Pressable())
                            }
                        }
                    }
                }
                .frame(width: 92, alignment: .leading)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(store.accentColor.opacity(targeted.value ? 0.18 : 0)))
                .onDrop(of: [UTType.fileURL], isTargeted: $targeted.value) { providers in
                    FileDrop.load(providers) { urls in
                        for url in urls where !store.shelf.contains(url.path) {
                            store.shelf.append(url.path)
                        }
                    }
                    return true
                }
                .help("Drop files here to keep them handy. Drag them out to use them.")
            }
        }
    }
}

struct ShelfPane: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var files = FilesModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: "Shelf", symbol: "tray.and.arrow.down.fill")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if store.shelf.isEmpty {
                        Text("Drop files on the Shelf half of the tile. They stay here until you remove them, and you can drag them into any upload box or folder.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(store.shelf.reversed(), id: \.self) { path in
                        FileRow(url: URL(fileURLWithPath: path)) { store.shelf.removeAll { $0 == path } }
                    }
                    if !files.resumes.isEmpty {
                        SmallLabel(text: "Tailored Resumes").padding(.top, 6)
                        ForEach(files.resumes, id: \.self) { FileRow(url: $0) }
                    }
                }
            }
            .frame(height: 280)
            HStack {
                if !store.shelf.isEmpty { Button("Clear shelf") { store.shelf.removeAll() } }
                Spacer()
                Text("Double-click to open · drag to use").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .frame(width: 320, alignment: .leading)
    }
}

struct FileRow: View {
    let url: URL
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(RelativeDateTimeFormatter().localizedString(for: FilesModel.added(url), relativeTo: Date()))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            if let onRemove = onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain)
                    .help("Remove")
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

// MARK: - Tools: notes, clipboard, search, quick actions, screenshot, colour picker

struct ToolsWidget: View {
    var body: some View {
        Tile(padding: 6) {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    PopIcon("note.text", hint: "Quick notes") { NotesPane() }
                    PopIcon("doc.on.clipboard", hint: "Clipboard history") { ClipboardPane() }
                    PopIcon("magnifyingglass", hint: "Search the web") { SearchPane() }
                }
                HStack(spacing: 2) {
                    PopIcon("bolt.fill", hint: "Quick actions") { ActionsPane() }
                    IconButton("camera.viewfinder", hint: "Screenshot a region to the clipboard") { QuickActions.screenshot() }
                    IconButton("eyedropper.halffull", hint: "Pick a colour (copies the hex code)") { QuickActions.pickColor() }
                }
            }
        }
    }
}

struct NotesPane: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: "Quick notes", symbol: "note.text")
            TextEditor(text: $store.notes)
                .font(.system(size: 13))
                .frame(width: 290, height: 220)
        }
    }
}

struct ClipboardPane: View {
    @ObservedObject private var clipboard = ClipboardWatcher.shared
    @StateObject private var copied = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: copied.value.isEmpty ? "Clipboard history" : "Copied", symbol: "doc.on.clipboard")
            if clipboard.items.isEmpty {
                Text("Text you copy will show up here. Passwords are never saved.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(clipboard.items, id: \.self) { text in
                            Button {
                                clipboard.copy(text)
                                copied.value = text
                            } label: {
                                Text(text)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(copied.value == text ? 0.18 : 0.07)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 230)
            }
        }
        .frame(width: 290)
    }
}

struct SearchPane: View {
    @StateObject private var query = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: "Search", symbol: "magnifyingglass")
            TextField("Type and press Return", text: $query.value)
                .textFieldStyle(.roundedBorder)
                .onSubmit { go("https://www.google.com/search?q=") }
            HStack {
                Button("Google") { go("https://www.google.com/search?q=") }
                Button("GitHub") { go("https://github.com/search?q=") }
                Button("Stack Overflow") { go("https://stackoverflow.com/search?q=") }
                Button("YouTube") { go("https://www.youtube.com/results?search_query=") }
            }
            .controlSize(.small)
        }
        .frame(width: 320)
    }

    private func go(_ base: String) {
        let text = query.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: base + encoded) else { return }
        NSWorkspace.shared.open(url)
        query.value = ""
    }
}

struct ActionsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PaneTitle(text: "Quick actions", symbol: "bolt.fill")
            row("camera.viewfinder", "Screenshot a region to clipboard") { QuickActions.screenshot() }
            row("eyedropper", "Pick a colour (copies hex code)") { QuickActions.pickColor() }
            row("circle.lefthalf.filled", "Toggle dark mode") { QuickActions.toggleDarkMode() }
            row("arrow.down.circle", "Open Downloads") { QuickActions.openDownloads() }
            row("moon.fill", "Sleep the display") { QuickActions.sleepDisplay() }
        }
        .frame(width: 260, alignment: .leading)
    }

    private func row(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }
}

// MARK: - CPU + memory

struct SystemWidget: View {
    @ObservedObject private var stats = SystemStats.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("CPU").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int((stats.cpu * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Sparkline(samples: stats.history, color: store.accentColor)
                    .frame(height: 14)
                    .animation(.easeOut(duration: 0.4), value: stats.history)
                HStack {
                    Text("RAM").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int((stats.memory * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                ProgressLine(value: stats.memory, color: Color(red: 0.66, green: 0.48, blue: 1.0))
            }
            .frame(width: 92)
        }
    }
}

// MARK: - Now playing + volume

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    let player: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            shape.fill(LinearGradient(
                colors: [Color(red: 1.0, green: 0.30, blue: 0.45), Color(red: 0.55, green: 0.20, blue: 0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
            if let url = url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: size, height: size)
                .id(url)
                .transition(.opacity)
            }
            if let badge = badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(badge.color))
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .shadow(color: Color.black.opacity(0.4), radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.35), value: url)
    }

    private var badge: (symbol: String, color: Color)? {
        switch player {
        case NowPlaying.youTubeMusic: return ("play.fill", Color(red: 1.0, green: 0.0, blue: 0.0))
        case "Spotify": return ("waveform", Color(red: 0.11, green: 0.73, blue: 0.33))
        case "Music": return ("music.note", Color(red: 0.98, green: 0.24, blue: 0.35))
        default: return nil
        }
    }
}

struct MusicProgress: View {
    @ObservedObject private var music = NowPlaying.shared

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let position = music.currentPosition(at: context.date)
            let fraction = music.duration > 0 ? position / music.duration : 0
            ProgressLine(value: fraction, color: .white, height: 3)
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}

struct MusicWidget: View {
    @ObservedObject private var music = NowPlaying.shared
    @ObservedObject private var volume = VolumeControl.shared
    @StateObject private var setup = Box(false)

    var body: some View {
        Tile(padding: 7) {
            HStack(spacing: 10) {
                Button {
                    music.openPlayer()
                } label: {
                    ArtworkView(url: music.artwork, size: Metrics.tile - 14, player: music.player)
                }
                .buttonStyle(Pressable())
                .help(music.player == nil ? "Open YouTube Music" : "Open \(music.player ?? "")")
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.player == nil ? "Nothing playing" : music.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if music.needsChromeSetting {
                        Button {
                            NSApp.activate(ignoringOtherApps: true)
                            setup.value.toggle()
                        } label: {
                            Label("Turn on full controls", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $setup.value, arrowEdge: Store.shared.atTop ? .bottom : .top) {
                            ChromeSetupPane().padding(14)
                        }
                    } else {
                        Text(music.player == nil ? "YouTube Music · Spotify" : music.artist)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    MusicProgress()
                    HStack(spacing: 9) {
                        Group {
                            control("backward.fill", 10) { music.command("previous track") }
                            control(music.playing ? "pause.fill" : "play.fill", 13) { music.command("playpause") }
                            control("forward.fill", 10) { music.command("next track") }
                        }
                        .disabled(music.player == nil || music.needsChromeSetting)
                        .opacity(music.player == nil ? 0.4 : 1)
                        Image(systemName: volume.level < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Slider(value: Binding(get: { volume.level }, set: { volume.set($0) }), in: 0...100)
                            .controlSize(.mini)
                            .frame(width: 54)
                    }
                }
                .frame(width: 168, alignment: .leading)
            }
        }
        .onHover { inside in
            if inside { volume.refresh() }
        }
        .help(music.needsChromeSetting
              ? "For artist, cover art and buttons: in Chrome choose View > Developer > Allow JavaScript from Apple Events"
              : "Spotify, Apple Music, or YouTube Music in Chrome")
    }

    private func control(_ symbol: String, _ size: CGFloat, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }
}

// MARK: - Quick links (open straight in Chrome)

enum Links {
    static let palette: [Color] = [
        Color(red: 0.35, green: 0.61, blue: 1.0), Color(red: 1.0, green: 0.58, blue: 0.24),
        Color(red: 1.0, green: 0.38, blue: 0.36), Color(red: 0.70, green: 0.52, blue: 1.0),
        Color(red: 0.30, green: 0.80, blue: 0.48), Color(red: 0.35, green: 0.85, blue: 0.85),
        Color(red: 1.0, green: 0.45, blue: 0.70), Color(red: 1.0, green: 0.80, blue: 0.30)
    ]

    static func open(_ link: QuickLink) {
        var text = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return }
        QuickActions.open([url], withApp: "com.google.Chrome")
    }
}

struct LinksWidget: View {
    @ObservedObject private var store = Store.shared
    @StateObject private var editing = Box(false)

    var body: some View {
        Tile(padding: 8) {
            HStack(spacing: 4) {
                ForEach(Array(store.quickLinks.prefix(6).enumerated()), id: \.element.id) { index, link in
                    Button { Links.open(link) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: link.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Links.palette[index % Links.palette.count])
                                .frame(width: 32, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Links.palette[index % Links.palette.count].opacity(0.20)))
                            Text(link.name)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: 42)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .help("Open \(link.name) in Chrome")
                    .contextMenu {
                        Button("Open in Chrome") { Links.open(link) }
                        Button("Copy link") { ClipboardWatcher.shared.copy(link.url) }
                        Divider()
                        Button("Edit links…") {
                            NSApp.activate(ignoringOtherApps: true)
                            editing.value = true
                        }
                    }
                }
                if store.quickLinks.isEmpty {
                    Button("Add links") {
                        NSApp.activate(ignoringOtherApps: true)
                        editing.value = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                }
            }
        }
        .popover(isPresented: $editing.value, arrowEdge: store.atTop ? .bottom : .top) {
            LinksPane().padding(14)
        }
    }
}

struct LinksPane: View {
    @ObservedObject private var store = Store.shared
    private let symbols = ["building.columns.fill", "graduationcap.fill", "envelope.fill", "envelope.badge.fill",
                           "tablecells.fill", "doc.text.fill", "calendar", "globe", "book.fill", "briefcase.fill", "play.rectangle.fill", "star.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: "Quick links", symbol: "link")
            Text("Each one opens in Chrome. Up to 6 show on the bar. Right-click a link on the bar to come back here.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($store.quickLinks) { $link in
                HStack(spacing: 6) {
                    Menu {
                        ForEach(symbols, id: \.self) { symbol in
                            Button { link.symbol = symbol } label: { Label(symbol, systemImage: symbol) }
                        }
                    } label: {
                        Image(systemName: link.symbol)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                    TextField("Name", text: $link.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    TextField("https://…", text: $link.url)
                        .textFieldStyle(.roundedBorder)
                    Button { store.quickLinks.removeAll { $0.id == link.id } } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            HStack {
                Button("Add a link") {
                    store.quickLinks.append(QuickLink(name: "New", url: "https://", symbol: "globe"))
                }
                Spacer()
                Text("Tip: in Gmail links, /u/0/ is your first signed-in account and /u/1/ the second.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 200, alignment: .trailing)
            }
        }
        .frame(width: 400, alignment: .leading)
    }
}

/// Chrome only lets other apps read the YouTube Music page after this one-time switch.
struct ChromeSetupPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: "YouTube Music in Chrome", symbol: "play.rectangle.fill")
            Text("The cover picture works already. For the artist, the progress bar and the play / next buttons, Chrome needs one switch turned on:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("1. Click Chrome so it's the front app.")
            Text("2. In the menu bar choose View › Developer › Allow JavaScript from Apple Events.")
            Text("3. Come back here: it updates within a few seconds.")
            Button("Switch to Chrome") { QuickActions.openApp("com.google.Chrome") }
        }
        .font(.system(size: 12))
        .frame(width: 300, alignment: .leading)
    }
}
