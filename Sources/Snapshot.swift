import AppKit
import SwiftUI

/// Saves a PNG of each page of the bar (used to check the layout without a screen recording).
/// The real bar uses macOS glass; here a dark stand-in is drawn behind it.
@MainActor
enum Snapshot {
    static func pages(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for page in DockPage.all {
            Store.shared.page = page.id
            let view = HStack(spacing: 6) {
                PageView(page: page)
                SideColumn()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(red: 0.13, green: 0.12, blue: 0.20)))
            .padding(12)
            .background(LinearGradient(colors: [Color(red: 0.12, green: 0.31, blue: 0.54), Color(red: 0.42, green: 0.23, blue: 0.61)],
                                       startPoint: .leading, endPoint: .trailing))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("page\(page.id + 1)-\(page.name).png"))
            }
        }
        // Dangle moods and the notch pills, with a made-up session.
        let sample = ClaudeCode.Session(id: "demo", project: "hangtime", cwd: "/tmp/hangtime", state: .working,
                                        detail: "Editing Views.swift", symbol: "pencil", updated: Date(),
                                        started: Date().addingTimeInterval(-134),
                                        files: [ClaudeCode.ChangedFile(path: "/tmp/hangtime/Sources/Views.swift", added: 42, removed: 8)])
        let moods = VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 26) {
                VStack { HangingDangle(mood: .working); Text("working").font(.caption) }
                VStack { HangingDangle(mood: .waiting); Text("waiting").font(.caption) }
                VStack { HangingDangle(mood: .done); Text("done").font(.caption) }
                VStack { HangingDangle(mood: .error); Text("error").font(.caption) }
                VStack { HangingDangle(mood: .idle); Text("idle").font(.caption) }
            }
            ActivityPill(session: sample).frame(width: 360)
            DonePill(done: ClaudeCode.Finished(project: "hangtime", files: 4, date: Date()))
            SessionBlock(session: sample).frame(width: 320)
        }
        .padding(18)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.31, blue: 0.54), Color(red: 0.42, green: 0.23, blue: 0.61)],
                                   startPoint: .leading, endPoint: .trailing))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: moods)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("dangle.png"))
        }
        NSApp.terminate(nil)
    }
}
