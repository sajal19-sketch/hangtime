import Foundation
import AppKit
import Combine

// MARK: - GitHub (contribution dots, streaks, recent repos)

final class GitHubActivity: ObservableObject {
    static let shared = GitHubActivity()
    static let weeks = 15

    struct Repo: Identifiable {
        let id: String
        let name: String
        let url: String
        let stars: Int
        let language: String?
        let pushed: Date?
    }

    private struct RepoJSON: Decodable {
        let name: String
        let html_url: String
        let stargazers_count: Int
        let language: String?
        let pushed_at: String?
        let fork: Bool
    }

    /// Contribution level per day (0-4), column by column, oldest week first; -1 = future.
    @Published var levels: [Int] = Array(repeating: 0, count: GitHubActivity.weeks * 7)
    @Published var total: Int? = nil
    @Published var streak = 0
    @Published var longest = 0
    @Published var activeDays = 0
    @Published var todayActive = false
    @Published var repos: [Repo] = []
    @Published var status = "Loading"

    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let user = Store.shared.githubUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            status = "Set a username"
            return
        }
        Task {
            await self.loadContributions(user: user)
            await self.loadRepos(user: user)
        }
    }

    private func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: whole).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    private func loadContributions(user: String) async {
        let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        guard let url = URL(string: "https://github.com/users/\(encoded)/contributions") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                await MainActor.run { self.status = "User not found" }
                return
            }
            let html = String(decoding: data, as: UTF8.self)
            var byDate: [String: Int] = [:]
            for tag in matches("<td[^>]*data-date=\"[^>]*>", in: html) {
                guard let cell = tag.first,
                      let date = matches("data-date=\"(\\d{4}-\\d{2}-\\d{2})\"", in: cell).first?.last,
                      let levelText = matches("data-level=\"(\\d)\"", in: cell).first?.last,
                      let level = Int(levelText) else { continue }
                byDate[date] = level
            }
            guard !byDate.isEmpty else {
                await MainActor.run { self.status = "No data" }
                return
            }
            var count: Int? = nil
            if let text = matches("([0-9,]+)\\s+contributions?\\s+in", in: html).first?.last {
                count = Int(text.replacingOccurrences(of: ",", with: ""))
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            let todayText = formatter.string(from: Date())
            formatter.timeZone = calendar.timeZone
            let today = formatter.date(from: todayText) ?? Date()
            func key(_ daysAgo: Int) -> String {
                let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
                return formatter.string(from: day)
            }

            let weekday = calendar.component(.weekday, from: today) - 1
            let cells = GitHubActivity.weeks * 7
            var grid = Array(repeating: -1, count: cells)
            for index in 0..<cells {
                let daysAgo = (cells - 7 + weekday) - index
                if daysAgo < 0 { continue }
                grid[index] = byDate[key(daysAgo)] ?? 0
            }

            // Streaks: today counts if active, otherwise the streak may still be alive from yesterday.
            let isTodayActive = (byDate[key(0)] ?? 0) > 0
            var current = 0
            var day = isTodayActive ? 0 : 1
            while (byDate[key(day)] ?? 0) > 0 {
                current += 1
                day += 1
            }
            var best = 0
            var run = 0
            for date in byDate.keys.sorted() {
                if (byDate[date] ?? 0) > 0 {
                    run += 1
                    best = max(best, run)
                } else {
                    run = 0
                }
            }
            let active = byDate.values.filter { $0 > 0 }.count

            let finalGrid = grid
            let finalCount = count
            await MainActor.run {
                self.levels = finalGrid
                self.total = finalCount
                self.streak = current
                self.longest = best
                self.activeDays = active
                self.todayActive = isTodayActive
                self.status = "@\(user)"
            }
        } catch {
            await MainActor.run {
                if self.total == nil { self.status = "Offline" }
            }
        }
    }

    private func loadRepos(user: String) async {
        let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        guard let url = URL(string: "https://api.github.com/users/\(encoded)/repos?sort=pushed&per_page=8") else { return }
        var request = URLRequest(url: url)
        request.setValue("Hangtime", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let list = try? JSONDecoder().decode([RepoJSON].self, from: data) else { return }
        let iso = ISO8601DateFormatter()
        let repos = list.filter { !$0.fork }.prefix(6).map { item in
            Repo(id: item.html_url, name: item.name, url: item.html_url, stars: item.stargazers_count,
                 language: item.language, pushed: item.pushed_at.flatMap { iso.date(from: $0) })
        }
        let recent = Array(repos)
        await MainActor.run {
            self.repos = recent
        }
    }
}
