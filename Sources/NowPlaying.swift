import Foundation
import AppKit
import Combine

// MARK: - Now playing (Spotify, Apple Music, YouTube Music in Chrome)

final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()
    static let youTubeMusic = "YouTube Music"

    @Published var title = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var player: String? = nil
    @Published var artwork: URL? = nil
    @Published var duration: Double = 0
    @Published var position: Double = 0          // seconds, measured at positionDate
    @Published var positionDate = Date()
    /// YouTube Music was found but Chrome will not let us read or control the page.
    @Published var needsChromeSetting = false

    private struct Track {
        var app: String
        var state: String
        var title: String
        var artist: String
        var art: String
        var position: Double
        var duration: Double
        var limited = false
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "hangtime.nowplaying")
    private var busy = false
    private let players: [(name: String, bundle: String)] = [
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music")
    ]

    func start() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    /// Where the song is right now (moves smoothly between updates).
    func currentPosition(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        let value = playing ? position + date.timeIntervalSince(positionDate) : position
        return min(max(0, value), duration)
    }

    private func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    private func run(_ source: String) -> String? {
        AppleScript.run(source)
    }

    private func number(_ text: String) -> Double {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func appScript(_ name: String) -> String {
        let art = name == "Spotify" ? "(artwork url of t)" : "\"\""
        let length = name == "Spotify" ? "(((duration of t) / 1000) as string)" : "((duration of t) as string)"
        return """
        tell application "\(name)"
            set s to (player state as string)
            if s is "stopped" then return "stopped"
            set t to current track
            return s & "|||" & (name of t) & "|||" & (artist of t) & "|||" & \(art) & "|||" & (player position as string) & "|||" & \(length)
        end tell
        """
    }

    /// Runs JavaScript in the first music.youtube.com tab in Chrome (no double quotes allowed in it).
    private func youTubeScript(_ javascript: String) -> String {
        return """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then
                        try
                            set r to (execute t javascript "\(javascript)")
                            return "js|||" & (r as string) & "|||" & (URL of t)
                        on error
                            return "title|||" & (title of t) & "|||" & (URL of t)
                        end try
                    end if
                end repeat
            end repeat
        end tell
        return "none"
        """
    }

    private func readYouTubeMusic() -> Track? {
        let javascript = "(function(){var m=navigator.mediaSession?navigator.mediaSession.metadata:null;var v=document.querySelector('video');var s=(v&&!v.paused)?'playing':'paused';var a='';if(m&&m.artwork&&m.artwork.length){a=m.artwork[m.artwork.length-1].src;}var p=v?v.currentTime:0;var d=(v&&isFinite(v.duration))?v.duration:0;return [s,(m?m.title:''),(m?m.artist:''),a,p,d].join('|||');})()"
        guard let output = run(youTubeScript(javascript)), output != "none" else { return nil }
        let parts = output.components(separatedBy: "|||")
        if parts.count >= 7, parts[0] == "js" {
            if parts[2].isEmpty {
                return Track(app: NowPlaying.youTubeMusic, state: "paused", title: "YouTube Music", artist: "Pick a song to start", art: "", position: 0, duration: 0)
            }
            let art = parts[4].isEmpty ? NowPlaying.thumbnail(parts.count > 7 ? parts[7] : "") : parts[4]
            return Track(app: NowPlaying.youTubeMusic, state: parts[1], title: parts[2], artist: parts[3], art: art, position: number(parts[5]), duration: number(parts[6]))
        }
        if parts.count >= 2, parts[0] == "title" {
            // Chrome won't let us read the page, but the tab title and address still give
            // the song name and its YouTube ID, which is enough for the cover picture.
            var name = parts[1]
            for suffix in [" - YouTube Music", " | YouTube Music"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            var artist = "YouTube Music"
            for separator in [" • ", " - "] {
                let pieces = name.components(separatedBy: separator)
                if pieces.count >= 2 {
                    name = pieces[0]
                    artist = pieces[1]
                    break
                }
            }
            let address = parts.count > 2 ? parts[2] : ""
            let playing = address.contains("watch?") ? "playing" : "paused"
            return Track(app: NowPlaying.youTubeMusic, state: playing, title: name, artist: artist,
                         art: NowPlaying.thumbnail(address), position: 0, duration: 0, limited: true)
        }
        return nil
    }

    /// music.youtube.com/watch?v=ID -> YouTube's picture for that song. The 16:9 "mq" picture
    /// has the square cover art in its middle, so cropping it to a square shows just the cover.
    static func thumbnail(_ address: String) -> String {
        guard let parts = URLComponents(string: address),
              let id = parts.queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty else { return "" }
        return "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"
    }

    func update() {
        if busy { return }
        busy = true
        let candidates = players.filter { isRunning($0.bundle) }
        let chromeRunning = isRunning("com.google.Chrome")
        queue.async { [weak self] in
            guard let self = self else { return }
            var best: Track? = nil
            for candidate in candidates {
                guard let output = self.run(self.appScript(candidate.name)) else { continue }
                let parts = output.components(separatedBy: "|||")
                guard parts.count == 6 else { continue }
                let found = Track(app: candidate.name, state: parts[0], title: parts[1], artist: parts[2], art: parts[3], position: self.number(parts[4]), duration: self.number(parts[5]))
                if found.state == "playing" {
                    best = found
                    break
                }
                if best == nil { best = found }
            }
            if chromeRunning, best?.state != "playing", let tube = self.readYouTubeMusic() {
                if best == nil || tube.state != "paused" {
                    best = tube
                }
            }
            let outcome = best
            DispatchQueue.main.async {
                self.busy = false
                self.positionDate = Date()
                if let track = outcome {
                    if track.title != self.title || (track.art.isEmpty == (self.artwork != nil)) {
                        debugLog("now playing: \(track.app) limited=\(track.limited) art=\(track.art.isEmpty ? "none" : String(track.art.prefix(60)))")
                    }
                    self.player = track.app
                    self.title = track.title
                    self.artist = track.artist
                    self.playing = track.state == "playing"
                    self.position = track.position
                    self.duration = track.duration
                    self.needsChromeSetting = track.limited
                    let art = URL(string: track.art)
                    if self.artwork != art { self.artwork = track.art.isEmpty ? nil : art }
                } else {
                    self.player = nil
                    self.title = ""
                    self.artist = ""
                    self.playing = false
                    self.position = 0
                    self.duration = 0
                    self.artwork = nil
                    self.needsChromeSetting = false
                }
            }
        }
    }

    func command(_ verb: String) {
        guard let name = player else { return }
        if verb == "playpause" {
            // Feels instant: flip the button straight away, the next update confirms it.
            position = currentPosition(at: Date())
            positionDate = Date()
            playing.toggle()
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            if name == NowPlaying.youTubeMusic {
                let javascript: String
                switch verb {
                case "next track":
                    javascript = "(function(){var b=document.querySelector('ytmusic-player-bar .next-button');if(b){b.click();}return 'ok';})()"
                case "previous track":
                    javascript = "(function(){var b=document.querySelector('ytmusic-player-bar .previous-button');if(b){b.click();}return 'ok';})()"
                default:
                    javascript = "(function(){var v=document.querySelector('video');if(v){if(v.paused){v.play();}else{v.pause();}}return 'ok';})()"
                }
                _ = self.run(self.youTubeScript(javascript))
            } else {
                _ = self.run("tell application \"\(name)\" to \(verb)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.busy = false
                self.update()
            }
        }
    }

    /// Brings the player forward (or opens YouTube Music when nothing is playing).
    func openPlayer() {
        switch player {
        case "Spotify":
            QuickActions.openApp("com.spotify.client")
        case "Music":
            QuickActions.openApp("com.apple.Music")
        case NowPlaying.youTubeMusic:
            QuickActions.openApp("com.google.Chrome")
        default:
            if let url = URL(string: "https://music.youtube.com") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
