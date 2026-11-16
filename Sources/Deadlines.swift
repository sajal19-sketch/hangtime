import Foundation
import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Course deadlines with reminders: a heads-up the day before, then on the due day a reminder
/// every two hours until you mark it complete. Reminders show under the notch and, if you turn
/// it on, on your phone through the free ntfy app (Android or iPhone).
///
/// The list lives in ~/Library/Application Support/Hangtime/deadlines.json (outside the code),
/// so your courses stay private.
final class Deadlines: ObservableObject {
    static let shared = Deadlines()

    struct Item: Identifiable, Codable, Equatable {
        var id: String
        var due: Date?
        var course: String
        var title: String
        var note: String
        var exam: Bool
        var link: String
        var done: Bool
    }

    enum Kind: String { case tomorrow, today, overdue }

    /// A reminder showing on the Mac right now.
    struct Reminder: Identifiable, Equatable {
        var id: String { kind.rawValue + "|" + itemIDs.joined(separator: ",") }
        let kind: Kind
        let itemIDs: [String]
    }

    @Published var items: [Item] = []
    @Published var showing: Reminder? = nil
    @Published var phoneEnabled: Bool { didSet { UserDefaults.standard.set(phoneEnabled, forKey: "phoneReminders") } }
    @Published var phoneStatus = ""

    let topic: String
    private var timer: Timer?
    private var pollTimer: Timer?
    private var sent: Set<String>
    private var snoozed: [String: Date] = [:]
    private var loadedStamp: Date? = nil

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hangtime/deadlines.json")
    static let firstReminderHour = 9
    static let repeatEvery: TimeInterval = 2 * 3600

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "ntfyTopic"), saved.count >= 20 {
            topic = saved
        } else {
            let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
            topic = "hangtime-" + String((0..<22).map { _ in letters.randomElement()! })
            defaults.set(topic, forKey: "ntfyTopic")
        }
        phoneEnabled = defaults.bool(forKey: "phoneReminders")
        sent = Set(defaults.stringArray(forKey: "reminderSent") ?? [])
    }

    func start() {
        load()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.pollPhone() }
        pollPhone()
    }

    // MARK: Saving

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]; return e
    }()

    func load() {
        guard let data = try? Data(contentsOf: Deadlines.file),
              let list = try? Deadlines.decoder.decode([Item].self, from: data) else {
            debugLog("deadlines: no file or unreadable at \(Deadlines.file.path)")
            return
        }
        items = list
        loadedStamp = Deadlines.stamp()
        debugLog("deadlines loaded: \(list.count) items, \(list.filter { !$0.done && $0.due != nil }.count) upcoming")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Deadlines.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Deadlines.encoder.encode(items) { try? data.write(to: Deadlines.file, options: .atomic) }
        loadedStamp = Deadlines.stamp()
    }

    private static func stamp() -> Date? {
        // FileManager reads the date fresh each time (URL resource values are cached).
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    // MARK: Lists

    var upcoming: [Item] {
        items.filter { !$0.done && $0.due != nil }.sorted { $0.due! < $1.due! }
    }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    static func isOverdue(_ item: Item, now: Date = Date()) -> Bool {
        guard let due = item.due else { return false }
        return !item.done && due < now
    }

    // MARK: Actions

    func markDone(_ id: String, fromPhone: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].done else { return }
        items[index].done = true
        save()
        if var reminder = showing, reminder.itemIDs.contains(id) {
            let rest = reminder.itemIDs.filter { $0 != id }
            reminder = Reminder(kind: reminder.kind, itemIDs: rest)
            showing = rest.isEmpty ? nil : reminder
        }
        NSSound(named: "Glass")?.play()
        if !fromPhone && phoneEnabled {
            push(title: "✅ Done: \(items[index].title)", message: "\(items[index].course) · nice work. No more reminders for this one.",
                 priority: 2, tags: ["white_check_mark"], itemID: nil, link: nil)
        }
        debugLog("deadline done: \(id)\(fromPhone ? " (from phone)" : "")")
    }

    func setDone(_ id: String, _ done: Bool) {
        if done { markDone(id); return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done = false
        save()
    }

    func snooze(_ reminder: Reminder, hours: Double = 1) {
        let until = Date().addingTimeInterval(hours * 3600)
        reminder.itemIDs.forEach { snoozed[$0] = until }
        showing = nil
    }

    func dismiss() { showing = nil }

    func add(course: String, title: String, due: Date?) {
        let id = "custom-" + UUID().uuidString.prefix(8)
        items.append(Item(id: String(id), due: due, course: course, title: title, note: "", exam: false,
                          link: "", done: false))
        save()
        check()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    // MARK: Schedule

    /// Runs every minute. Each reminder slot fires once (it is remembered), so a Mac that was
    /// asleep catches up with only the latest slot, not a burst of old ones.
    func check(now: Date = Date()) {
        // Claude (or you) may have ticked something off in the file: pick that up first.
        if let stamp = Deadlines.stamp(), stamp != loadedStamp {
            debugLog("deadlines file changed, reloading")
            load()
            if let reminder = showing {
                let open = reminder.itemIDs.filter { id in items.first { $0.id == id }?.done == false }
                showing = open.isEmpty ? nil : Reminder(kind: reminder.kind, itemIDs: open)
            }
        }
        let calendar = Calendar.current
        var tomorrow: [Item] = []
        var today: [Item] = []
        var fired = false
        for item in items where !item.done {
            guard let due = item.due, due > now else { continue }
            if let until = snoozed[item.id], until > now { continue }
            let dueDay = calendar.startOfDay(for: due)
            guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: dueDay),
                  let firstBefore = calendar.date(bySettingHour: Deadlines.firstReminderHour, minute: 0, second: 0, of: dayBefore),
                  var firstToday = calendar.date(bySettingHour: Deadlines.firstReminderHour, minute: 0, second: 0, of: dueDay) else { continue }
            // Something due early in the morning gets its first same-day reminder 3 hours before.
            firstToday = min(firstToday, due.addingTimeInterval(-3 * 3600))

            if now >= firstToday {
                let slot = Int(now.timeIntervalSince(firstToday) / Deadlines.repeatEvery)
                if mark("\(item.id)|today|\(slot)") { today.append(item); fired = true }
            } else if now >= firstBefore {
                if mark("\(item.id)|before") { tomorrow.append(item); fired = true }
            }
        }
        if !today.isEmpty { show(.today, today) }
        else if !tomorrow.isEmpty { show(.tomorrow, tomorrow) }
        if fired { UserDefaults.standard.set(Array(sent.suffix(500)), forKey: "reminderSent") }
    }

    private func mark(_ key: String) -> Bool {
        if sent.contains(key) { return false }
        sent.insert(key)
        return true
    }

    private func show(_ kind: Kind, _ list: [Item]) {
        showing = Reminder(kind: kind, itemIDs: list.map { $0.id })
        NSSound(named: kind == .today ? "Sosumi" : "Purr")?.play()
        debugLog("reminder \(kind.rawValue): \(list.map { $0.id })")
        guard phoneEnabled else { return }
        for item in list {
            let when = item.due.map { Deadlines.time($0) } ?? ""
            if kind == .today {
                let left = item.due.map { Countdown.text($0) } ?? ""
                push(title: "⏰ Due today: \(item.title)", message: "\(item.course) · \(when) · \(left) left",
                     priority: 5, tags: ["rotating_light"], itemID: item.id, link: item.link)
            } else {
                push(title: "📅 Due tomorrow: \(item.title)", message: "\(item.course) · \(when)\(item.note.isEmpty ? "" : " · " + item.note)",
                     priority: 4, tags: ["calendar"], itemID: item.id, link: item.link)
            }
        }
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "'today' h:mm a" : "EEE MMM d, h:mm a"
        return formatter.string(from: date)
    }

    // MARK: Phone (ntfy)

    private var doneTopic: String { topic + "-done" }

    /// Sends one notification to your phone. "Mark complete" posts the item's id back to a
    /// second private topic, which Hangtime reads (see pollPhone).
    func push(title: String, message: String, priority: Int, tags: [String], itemID: String?, link: String?) {
        var actions: [[String: Any]] = []
        if let id = itemID {
            actions.append(["action": "http", "label": "Mark complete", "url": "https://ntfy.sh/\(doneTopic)",
                            "method": "POST", "body": id, "clear": true])
        }
        if let link = link, !link.isEmpty, !link.hasPrefix("mailto:") {
            actions.append(["action": "view", "label": "Open", "url": link])
        }
        var body: [String: Any] = ["topic": topic, "title": title, "message": message, "priority": priority, "tags": tags]
        if !actions.isEmpty { body["actions"] = actions }
        guard let url = URL(string: "https://ntfy.sh/"), let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                self?.phoneStatus = error == nil && code == 200 ? "Last sent \(Date().formatted(date: .omitted, time: .shortened))" : "Couldn't reach ntfy (\(code))"
            }
        }.resume()
    }

    func sendTest() {
        push(title: "👋 Hangtime is connected", message: "Due-date reminders will arrive here. Tap Mark complete to stop them.",
             priority: 3, tags: ["tada"], itemID: nil, link: nil)
    }

    /// Picks up "Mark complete" taps from the phone.
    func pollPhone() {
        guard phoneEnabled, let url = URL(string: "https://ntfy.sh/\(doneTopic)/json?poll=1&since=\(UserDefaults.standard.string(forKey: "ntfySince") ?? "2h")") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data else { return }
            var ids: [String] = []
            var last: String? = nil
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      json["event"] as? String == "message" else { continue }
                if let id = json["id"] as? String { last = id }
                if let message = json["message"] as? String { ids.append(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            DispatchQueue.main.async {
                if let last = last { UserDefaults.standard.set(last, forKey: "ntfySince") }
                ids.forEach { self?.markDone($0, fromPhone: true) }
            }
        }.resume()
    }

    var subscribeLink: String { "ntfy://ntfy.sh/\(topic)" }

    func qrImage() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(("https://ntfy.sh/" + topic).utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Views

extension Deadlines.Item {
    var shortTitle: String { title.count > 28 ? String(title.prefix(26)) + "…" : title }
}

/// Code page tile: this week's deadlines, colour-coded.
struct DueWidget: View {
    @ObservedObject private var deadlines = Deadlines.shared

    var body: some View {
        let list = Array(deadlines.upcoming.prefix(3))
        let overdue = deadlines.items.filter { Deadlines.isOverdue($0) }.count
        PopTile {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("DUE SOON").font(.system(size: 8, weight: .heavy)).foregroundColor(.secondary)
                        Spacer()
                        if overdue > 0 {
                            Text("\(overdue) overdue").font(.system(size: 8, weight: .bold)).foregroundColor(.red)
                        }
                    }
                    if list.isEmpty {
                        Text("Nothing due").font(.system(size: 12, weight: .semibold))
                        Text("Click to add deadlines").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    ForEach(list) { item in
                        HStack(spacing: 5) {
                            Circle().fill(DueWidget.color(item.due, now: context.date)).frame(width: 6, height: 6)
                            Text(item.shortTitle).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(DueWidget.when(item.due, now: context.date)).font(.system(size: 9, weight: .medium))
                                .foregroundColor(DueWidget.color(item.due, now: context.date))
                        }
                    }
                }
                .frame(width: 186, alignment: .leading)
            }
        } content: {
            DuePane()
        }
    }

    static func color(_ due: Date?, now: Date) -> Color {
        guard let due = due else { return .secondary }
        let calendar = Calendar.current
        if due < now || calendar.isDate(due, inSameDayAs: now) { return Color(red: 1, green: 0.42, blue: 0.43) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) {
            return Color(red: 1, green: 0.8, blue: 0.3)
        }
        return Color(red: 0.45, green: 0.88, blue: 0.58)
    }

    static func when(_ due: Date?, now: Date) -> String {
        guard let due = due else { return "no date" }
        let calendar = Calendar.current
        if due < now { return "overdue" }
        if calendar.isDate(due, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) { return "tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        if days < 7 { return due.formatted(.dateTime.weekday(.abbreviated)) }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Every deadline: tick off, add your own, and set up phone reminders.
struct DuePane: View {
    @ObservedObject private var deadlines = Deadlines.shared
    @StateObject private var showDone = Box(false)
    @StateObject private var newTitle = Box("")
    @StateObject private var newCourse = Box("")
    @StateObject private var newDate = Box(Date().addingTimeInterval(86400))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PaneTitle(text: "Deadlines", symbol: "calendar.badge.clock")
                Spacer()
                Toggle("Show done", isOn: $showDone.value).toggleStyle(.checkbox).font(.system(size: 10))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let dated = deadlines.items.filter { $0.due != nil && (showDone.value || !$0.done) }.sorted { $0.due! < $1.due! }
                    let undated = deadlines.items.filter { $0.due == nil && (showDone.value || !$0.done) }
                    ForEach(dated) { row($0) }
                    if !undated.isEmpty {
                        SmallLabel(text: "No date yet").padding(.top, 6)
                        ForEach(undated) { row($0) }
                    }
                }
            }
            .frame(height: 300)
            Divider()
            HStack(spacing: 6) {
                TextField("Course", text: $newCourse.value).textFieldStyle(.roundedBorder).frame(width: 80)
                TextField("What's due?", text: $newTitle.value).textFieldStyle(.roundedBorder)
            }
            HStack {
                DatePicker("", selection: $newDate.value, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                Spacer()
                Button("Add") {
                    let title = newTitle.value.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    deadlines.add(course: newCourse.value, title: title, due: newDate.value)
                    newTitle.value = ""
                }
            }
            Divider()
            PhoneSetup()
        }
        .frame(width: 380, alignment: .leading)
    }

    private func row(_ item: Deadlines.Item) -> some View {
        HStack(spacing: 7) {
            Button { deadlines.setDone(item.id, !item.done) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(item.course).font(.system(size: 10, weight: .bold)).foregroundColor(Store.shared.accentColor)
                    if item.exam { Text("EXAM").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 3).background(Capsule().fill(Color.blue.opacity(0.3))) }
                }
                Text(item.title).font(.system(size: 12, weight: .medium)).strikethrough(item.done).lineLimit(2)
                Text(item.due.map { Deadlines.time($0) } ?? item.note).font(.system(size: 10))
                    .foregroundColor(Deadlines.isOverdue(item) ? .red : .secondary)
            }
            Spacer()
            if !item.link.isEmpty, let url = URL(string: item.link) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Open")
            }
            Button { deadlines.remove(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundColor(.secondary).help("Delete")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(Deadlines.isOverdue(item) ? 0.1 : 0.05)))
        .opacity(item.done ? 0.55 : 1)
    }
}

/// Phone reminders through the free ntfy app.
struct PhoneSetup: View {
    @ObservedObject private var deadlines = Deadlines.shared
    @StateObject private var copied = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Phone reminders (Samsung / Android / iPhone)", isOn: $deadlines.phoneEnabled)
                .font(.system(size: 12, weight: .semibold))
            if deadlines.phoneEnabled {
                HStack(alignment: .top, spacing: 10) {
                    if let qr = deadlines.qrImage() {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 92, height: 92)
                            .background(Color.white).cornerRadius(6)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1. Install **ntfy** from the Play Store (free).").font(.system(size: 11))
                        Text("2. Tap **+** and subscribe to this topic:").font(.system(size: 11))
                        HStack(spacing: 4) {
                            Text(deadlines.topic).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                            Button(copied.value ? "Copied" : "Copy") {
                                ClipboardWatcher.shared.copy(deadlines.topic)
                                copied.value = true
                            }.controlSize(.mini)
                        }
                        Text("3. Press **Send test**.").font(.system(size: 11))
                    }
                }
                HStack {
                    Button("Send test") { deadlines.sendTest() }.controlSize(.small)
                    Spacer()
                    Text(deadlines.phoneStatus).font(.system(size: 9)).foregroundColor(.secondary)
                }
                Text("The topic name is your private key: keep it to yourself. Reminders go through ntfy.sh and only while Hangtime is running.")
                    .font(.system(size: 9)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The pop-up under the notch: "Due tomorrow" (amber) or "Due today" (red).
struct DueCard: View {
    let reminder: Deadlines.Reminder
    @ObservedObject private var deadlines = Deadlines.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        let today = reminder.kind == .today
        let items = reminder.itemIDs.compactMap { deadlines.item($0) }
        let red = Color(red: 1, green: 0.42, blue: 0.43)
        let amber = Color(red: 0.96, green: 0.71, blue: 0.0)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: today ? "alarm.fill" : "calendar.badge.clock").foregroundColor(today ? red : amber)
                Text(today ? "Due today" : "Due tomorrow").font(.system(size: 13, weight: .semibold))
                Spacer()
                if today, let due = items.compactMap({ $0.due }).min() {
                    TimelineView(.periodic(from: Date(), by: 30)) { context in
                        Text("\(Countdown.text(due, now: context.date)) left").font(.system(size: 12, weight: .semibold)).foregroundColor(red)
                    }
                } else {
                    Text("from your planner").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Button { deadlines.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(store.accentColor).frame(width: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text("\(item.course) · \(item.due.map { Deadlines.time($0) } ?? "")").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { deadlines.markDone(item.id) } label: {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24).background(Circle().fill(Color.green.opacity(0.85)))
                    }
                    .buttonStyle(Pressable()).help("Mark complete")
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 9).fill((today ? red : Color.white).opacity(today ? 0.14 : 0.07)))
            }
            if today {
                Text("Next reminder in 2 hours\(deadlines.phoneEnabled ? " · also on your phone" : "")")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Spacer()
                pill(today ? "Snooze 1h" : "Remind me later", Color.white.opacity(0.12)) { deadlines.snooze(reminder) }
                if let link = items.first?.link, let url = URL(string: link), !link.isEmpty {
                    pill(link.hasPrefix("mailto:") ? "Email TA" : "Open Brightspace", Color.white.opacity(0.12)) { NSWorkspace.shared.open(url) }
                }
                pill(items.count > 1 ? "Mark all done" : "Mark complete", today ? Color.green.opacity(0.85) : store.accentColor) {
                    items.forEach { deadlines.markDone($0.id) }
                }
            }
        }
        .padding(13)
        .background(GlassBackground(radius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(today ? red.opacity(0.5) : .clear, lineWidth: 1))
    }

    private func pill(_ title: String, _ color: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(color)).contentShape(Capsule())
        }
        .buttonStyle(Pressable())
    }
}
