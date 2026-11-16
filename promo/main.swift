// Renders the Hangtime Instagram reel (1080×1920, 30 fps) to an MP4.
// Build and run:  promo/make-video.command
import SwiftUI
import AppKit
import AVFoundation

let W: CGFloat = 1080, H: CGFloat = 1920, FPS = 30.0, LENGTH = 19.0

// MARK: - Helpers

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func ease(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
/// Springy ease-out with a little overshoot.
func spring(_ x: Double) -> Double {
    let t = clamp(x)
    return 1 - pow(1 - t, 3) * cos(t * 3.2)
}
/// 0 → 1 between a and b.
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
/// Fades in at a, out at b.
func window(_ t: Double, _ a: Double, _ b: Double, fade: Double = 0.35) -> Double {
    ease(ramp(t, a, a + fade)) * (1 - ease(ramp(t, b - fade, b)))
}

let accent = Color(red: 0.35, green: 0.61, blue: 1.0)
let amber = Color(red: 0.96, green: 0.71, blue: 0.0)
let green = Color(red: 0.19, green: 0.78, blue: 0.37)
let clay = Color(red: 0.85, green: 0.47, blue: 0.34)

// MARK: - Dangle (the Claude Code character, upside down)

struct DangleShape: Shape {
    static let data = "M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z"
    static let tokens: [String] = {
        let regex = try! NSRegularExpression(pattern: "[MmHhVvZz]|-?[0-9]*\\.?[0-9]+")
        return regex.matches(in: data, range: NSRange(data.startIndex..., in: data)).map { String(data[Range($0.range, in: data)!]) }
    }()
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * s, y: rect.minY + p.y * s) }
        var path = Path(); var p = CGPoint.zero; var start = CGPoint.zero; var cmd = "M"; var i = 0
        let list = DangleShape.tokens
        func num() -> CGFloat { let v = CGFloat(Double(list[i])!); i += 1; return v }
        while i < list.count {
            if Double(list[i]) == nil {
                cmd = list[i]; i += 1
                if cmd == "Z" || cmd == "z" { path.closeSubpath(); p = start; continue }
            }
            switch cmd {
            case "M": p = CGPoint(x: num(), y: num()); start = p; path.move(to: at(p))
            case "m": let dx = num(), dy = num(); p = CGPoint(x: p.x + dx, y: p.y + dy); start = p; path.move(to: at(p))
            case "H": p.x = num(); path.addLine(to: at(p))
            case "h": p.x += num(); path.addLine(to: at(p))
            case "V": p.y = num(); path.addLine(to: at(p))
            case "v": p.y += num(); path.addLine(to: at(p))
            default: i += 1
            }
        }
        return path
    }
}

struct Dangle: View {
    let size: CGFloat
    var swing: Double = 0
    var glow: Color = .clear
    var glowAmount: Double = 0
    var body: some View {
        DangleShape()
            .fill(accent, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(180))
            .shadow(color: glow.opacity(glowAmount), radius: size * 0.22)
            .shadow(color: glow.opacity(glowAmount * 0.7), radius: size * 0.08)
            .rotationEffect(.degrees(swing), anchor: .top)
    }
}

// MARK: - Glass pieces (drawn flat so they render without macOS's live blur)

struct Glass: View {
    var radius: CGFloat = 24
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.62))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
    }
}

struct Tile<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(width: width, height: 68)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct Chip: View {
    let symbol: String; let color: Color; var size: CGFloat = 26
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundColor(color)
            .frame(width: size, height: size + 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.22)))
    }
}

struct Label2: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 8, weight: .heavy)).foregroundColor(.white.opacity(0.55)) }
}

// MARK: - The three pages (sample data only)

struct MacPage: View {
    let t: Double
    var body: some View {
        HStack(spacing: 6) {
            Tile(width: 228) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("⬇ Downloads ↗").font(.system(size: 10, weight: .semibold)).fixedSize()
                        HStack(spacing: 4) {
                            Chip(symbol: "doc.richtext.fill", color: Color(red: 1, green: 0.42, blue: 0.43))
                            Chip(symbol: "photo.fill", color: Color(red: 0.45, green: 0.68, blue: 1))
                            Chip(symbol: "doc.zipper", color: Color(red: 1, green: 0.8, blue: 0.3))
                        }
                    }
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 46)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("📥 Shelf · 2").font(.system(size: 10, weight: .semibold)).fixedSize()
                        HStack(spacing: 4) {
                            Chip(symbol: "doc.text.fill", color: Color(white: 0.92))
                            Chip(symbol: "tablecells.fill", color: Color(red: 0.45, green: 0.88, blue: 0.58))
                        }
                    }
                }
            }
            Tile {
                VStack(spacing: 8) {
                    HStack(spacing: 12) { icon("note.text"); icon("doc.on.clipboard"); icon("magnifyingglass") }
                    HStack(spacing: 12) { icon("bolt.fill"); icon("camera.viewfinder"); icon("eyedropper.halffull") }
                }
            }
            Tile(width: 104) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("CPU").font(.system(size: 10)).foregroundColor(.white.opacity(0.6)); Spacer(); Text("\(18 + Int(sin(t * 3) * 6))%").font(.system(size: 12, weight: .bold, design: .rounded)) }
                    Spark(t: t).frame(height: 12)
                    HStack { Text("RAM").font(.system(size: 10)).foregroundColor(.white.opacity(0.6)); Spacer(); Text("64%").font(.system(size: 12, weight: .bold, design: .rounded)) }
                    Bar(value: 0.64, color: Color(red: 0.66, green: 0.48, blue: 1))
                }
            }
            Tile(width: 262) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AngularGradient(colors: [Color(red: 1, green: 0.37, blue: 0.43), Color(red: 1, green: 0.76, blue: 0.44), Color(red: 0.28, green: 0.78, blue: 1), Color(red: 0.56, green: 0.36, blue: 1), Color(red: 1, green: 0.37, blue: 0.43)], center: .center, angle: .degrees(t * 40)))
                        .frame(width: 54, height: 54)
                        .overlay(Image(systemName: "music.note").font(.system(size: 20, weight: .bold)).foregroundColor(.white.opacity(0.9)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Midnight Drive").font(.system(size: 12, weight: .semibold))
                        Text("Lo-fi Beats").font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                        Bar(value: 0.25 + t * 0.012, color: .white, height: 3)
                        HStack(spacing: 10) {
                            Image(systemName: "backward.fill").font(.system(size: 10))
                            Image(systemName: "pause.fill").font(.system(size: 13))
                            Image(systemName: "forward.fill").font(.system(size: 10))
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                            Bar(value: 0.6, color: Color(white: 0.85)).frame(width: 48)
                        }
                    }
                }
            }
        }
    }
    func icon(_ s: String) -> some View { Image(systemName: s).font(.system(size: 14, weight: .medium)) }
}

struct ClaudePage: View {
    let t: Double
    var body: some View {
        HStack(spacing: 6) {
            Tile(width: 196) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.14), lineWidth: 5)
                        Circle().trim(from: 0, to: 0.34 + 0.02 * sin(t)).stroke(green, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: -1) { Text("34").font(.system(size: 14, weight: .bold, design: .rounded)); Text("SESSION").font(.system(size: 6, weight: .medium)).foregroundColor(.white.opacity(0.6)) }
                    }.frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) { Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundColor(clay); Text("Claude").font(.system(size: 12, weight: .semibold)) }
                        Text("resets 2h 7m").font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                        HStack(spacing: 4) { Text("Week").font(.system(size: 9)).foregroundColor(.white.opacity(0.6)); Bar(value: 0.45, color: green); Text("45%").font(.system(size: 9, weight: .bold)) }
                    }
                }
            }
            Tile(width: 116) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLAUDE CODE TODAY").font(.system(size: 7, weight: .heavy)).foregroundColor(clay)
                    Text(String(format: "%.1fM", 12.4 + t * 0.05)).font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("tokens · 3 sessions").font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                }
            }
            Tile(width: 318) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Label2(text: "ASK AI"); Spacer()
                        Text("Claude").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(clay))
                        Text("Gemini").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    HStack(spacing: 6) {
                        HStack(spacing: 6) { Image(systemName: "magnifyingglass").font(.system(size: 11)); Text("Ask Claude…").font(.system(size: 12)).foregroundColor(.white.opacity(0.55)); Spacer(); Text("⌘⇧Space").font(.system(size: 9)).foregroundColor(.white.opacity(0.5)) }
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                        round("mic.fill"); round("viewfinder")
                    }
                }
            }
        }
    }
    func round(_ s: String) -> some View { Image(systemName: s).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1))) }
}

struct CodePage: View {
    let t: Double
    var body: some View {
        HStack(spacing: 6) {
            Tile(width: 232) {
                VStack(alignment: .leading, spacing: 5) {
                    Label2(text: "PROJECTS")
                    row("hangtime"); row("portfolio")
                }
            }
            Tile {
                HStack(spacing: 5) {
                    link("building.columns.fill", Color(red: 0.45, green: 0.68, blue: 1), "School")
                    link("graduationcap.fill", Color(red: 1, green: 0.58, blue: 0.24), "Classes")
                    link("envelope.fill", Color(red: 1, green: 0.38, blue: 0.36), "Mail")
                    link("tablecells.fill", Color(red: 0.3, green: 0.8, blue: 0.48), "Sheets")
                }
            }
            Tile(width: 136) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        ForEach(0..<14, id: \.self) { w in
                            VStack(spacing: 2) {
                                ForEach(0..<7, id: \.self) { d in
                                    let level = (w * 7 + d * 3 + w / 2) % 5
                                    RoundedRectangle(cornerRadius: 1.5).fill(level == 0 ? Color.white.opacity(0.12) : green.opacity(0.25 + Double(level) * 0.19)).frame(width: 6, height: 6)
                                }
                            }
                        }
                    }
                    HStack { Image(systemName: "flame.fill").font(.system(size: 9)).foregroundColor(.orange); Text("12 day streak").font(.system(size: 9, weight: .semibold)) }
                }
            }
        }
    }
    func row(_ name: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 12, weight: .semibold)); Spacer()
            ForEach(["chevron.left.forwardslash.chevron.right", "terminal", "folder"], id: \.self) { s in
                Image(systemName: s).font(.system(size: 10, weight: .medium)).frame(width: 22, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }
        }
    }
    func link(_ s: String, _ c: Color, _ name: String) -> some View {
        VStack(spacing: 3) { Chip(symbol: s, color: c, size: 30); Text(name).font(.system(size: 8, weight: .medium)).foregroundColor(.white.opacity(0.6)) }
    }
}

struct Spark: View {
    let t: Double
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 0..<30 {
                    let x = g.size.width * CGFloat(i) / 29
                    let v = 0.5 + 0.35 * sin(Double(i) * 0.7 + t * 4) * cos(Double(i) * 0.23)
                    let pt = CGPoint(x: x, y: g.size.height * CGFloat(1 - v))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }.stroke(accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

struct Bar: View {
    let value: Double; let color: Color; var height: CGFloat = 4
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(1, value)))
            }
        }.frame(height: height)
    }
}

struct SideColumn: View {
    let page: Int; let t: Double; var waiting = false
    var body: some View {
        VStack(spacing: 7) {
            Dangle(size: 15, swing: sin(t * 2.4) * 6, glow: amber, glowAmount: waiting ? 1 : 0)
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(i == page ? accent : Color.white.opacity(0.28)).frame(width: 5, height: i == page ? 12 : 5)
                }
            }
            Image(systemName: "gearshape.fill").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
        }.frame(width: 18, height: 68)
    }
}

// MARK: - One frame of the reel

struct Frame: View {
    let t: Double

    var body: some View {
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            bar
            closeUp
            dangleScenes
            captions
            endCard
        }
        .frame(width: W, height: H)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
    }

    var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.20, blue: 0.42), Color(red: 0.34, green: 0.18, blue: 0.55), Color(red: 0.72, green: 0.30, blue: 0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.35, green: 0.61, blue: 1).opacity(0.45)).frame(width: 900).blur(radius: 160)
                .offset(x: -300 + sin(t * 0.4) * 60, y: -500)
            Circle().fill(Color(red: 1, green: 0.45, blue: 0.35).opacity(0.35)).frame(width: 800).blur(radius: 170)
                .offset(x: 320, y: 520 + cos(t * 0.35) * 60)
        }
        .frame(width: W, height: H)
    }

    var menuBar: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.30)).frame(height: 64)
            HStack(spacing: 26) {
                Image(systemName: "apple.logo").font(.system(size: 26))
                Text("Finder").font(.system(size: 24, weight: .bold))
                Text("File").font(.system(size: 24))
                Spacer()
                Image(systemName: "wifi").font(.system(size: 24))
                Text("9:41").font(.system(size: 24, weight: .medium))
            }
            .padding(.horizontal, 34).frame(height: 64)
            UnevenNotch().fill(Color.black).frame(width: 300, height: 70)
        }
    }

    /// Bar drops at 2.6 s, swipes pages at 6.2 s and 9.6 s, slides away at 12.8 s.
    var bar: some View {
        let down = spring(ramp(t, 2.6, 3.4)) * (1 - ease(ramp(t, 12.6, 13.1)))
        let page = t < 6.2 ? 0 : (t < 9.6 ? 1 : 2)
        let swipeA = ramp(t, 6.0, 6.45), swipeB = ramp(t, 9.4, 9.85)
        let contentOpacity: Double = {
            if t > 5.95 && t < 6.45 { return abs(swipeA - 0.5) * 2 }
            if t > 9.35 && t < 9.85 { return abs(swipeB - 0.5) * 2 }
            return 1
        }()
        return HStack(spacing: 6) {
            Group {
                switch page {
                case 0: MacPage(t: t)
                case 1: ClaudePage(t: t)
                default: CodePage(t: t)
                }
            }
            .opacity(contentOpacity)
            .offset(x: CGFloat((1 - contentOpacity) * 24))
            SideColumn(page: page, t: t)
        }
        .padding(8)
        .background(Glass())
        .fixedSize()
        .scaleEffect(1.36)
        .offset(y: CGFloat(-260 + down * 380))
        .opacity(down > 0.01 ? 1 : 0)
    }

    /// A big, slowly panning close-up of the current page, so it reads on a phone.
    var closeUp: some View {
        let scenes: [(Double, Double, Int, CGFloat)] = [(3.3, 6.05, 0, 800), (6.5, 9.45, 1, 700), (9.9, 12.7, 2, 640)]
        let scale: CGFloat = 2.5
        return ZStack {
            ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                let o = window(t, scene.0, scene.1, fade: 0.3)
                let travel = max(0, (scene.3 * scale - 980) / 2)
                let pan = CGFloat(ease(ramp(t, scene.0 + 0.3, scene.1 - 0.3)))
                HStack(spacing: 6) {
                    switch scene.2 {
                    case 0: MacPage(t: t)
                    case 1: ClaudePage(t: t)
                    default: CodePage(t: t)
                    }
                    SideColumn(page: scene.2, t: t)
                }
                .padding(8)
                .fixedSize()
                .scaleEffect(scale)
                .offset(x: travel - pan * travel * 2)
                .frame(width: 1000, height: 250)
                .background(Glass(radius: 46))
                .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
                .opacity(o)
                .scaleEffect(0.94 + 0.06 * o)
            }
        }
        .position(x: W / 2, y: 720)
    }

    var dangleScenes: some View {
        let show = ramp(t, 13.0, 13.6) * (1 - ease(ramp(t, 17.0, 17.4)))
        let waiting = t > 15.0 && t < 16.4
        let done = t >= 16.4
        let drop = spring(ramp(t, 13.0, 13.7))
        let thread = waiting ? CGFloat(ease(ramp(t, 15.0, 15.3))) * 40 : 0
        let bounce = done ? CGFloat(sin(ramp(t, 16.4, 16.9) * .pi) * 18) : 0
        let glow = waiting ? 0.6 + 0.4 * sin(t * 8) : 0
        return VStack(spacing: 18) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 4, height: thread)
                Dangle(size: 120, swing: waiting ? sin(t * 5) * 3 : (done ? 0 : sin(t * 2.4) * 8), glow: amber, glowAmount: glow)
                    .overlay(alignment: .topTrailing) {
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 26, weight: .heavy))
                                .frame(width: 46, height: 46).background(Circle().fill(green)).offset(x: 30, y: 26)
                        }
                    }
                    .offset(y: bounce)
            }
            .offset(y: CGFloat(-200 + drop * 200))
            if t < 15.0 {
                activityPill
            } else if waiting {
                permissionCard
            } else {
                donePill
            }
        }
        .padding(.top, 58)
        .opacity(show)
    }

    var activityPill: some View {
        let seconds = 131 + Int(t - 13)
        let label = t < 14.0 ? ("pencil", "Editing Views.swift") : ("terminal", "Running swift build")
        return HStack(spacing: 16) {
            Circle().fill(green).frame(width: 16, height: 16)
            Text("hangtime").font(.system(size: 34, weight: .bold))
            Image(systemName: label.0).font(.system(size: 30, weight: .bold)).foregroundColor(accent)
            Text(label.1).font(.system(size: 34))
            Spacer()
            Text("\(seconds / 60)m \(seconds % 60)s").font(.system(size: 30, design: .rounded)).monospacedDigit().foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 30).frame(width: 880, height: 92)
        .background(Glass(radius: 40))
    }

    var permissionCard: some View {
        let press = ramp(t, 15.8, 16.0)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Circle().fill(amber).frame(width: 18, height: 18)
                Text("Claude Code needs permission").font(.system(size: 34, weight: .bold))
                Spacer()
                Text("hangtime").font(.system(size: 26)).foregroundColor(.white.opacity(0.6))
            }
            Text("npm install swift-format")
                .font(.system(size: 30, design: .monospaced))
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.09)))
            HStack(spacing: 16) {
                Spacer()
                pill("Deny", Color.white.opacity(0.14))
                pill("Always", Color.white.opacity(0.14))
                pill("Allow", accent)
                    .scaleEffect(1 - 0.08 * sin(press * .pi))
                    .overlay(Circle().stroke(Color.white.opacity(0.7 * (1 - press)), lineWidth: 4).frame(width: 40 + 120 * press, height: 40 + 120 * press).opacity(press > 0 ? 1 : 0))
            }
        }
        .padding(30).frame(width: 900)
        .background(Glass(radius: 40))
    }

    func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 30, weight: .semibold)).padding(.horizontal, 34).padding(.vertical, 14).background(Capsule().fill(color))
    }

    var donePill: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundColor(green)
            Text("Done").font(.system(size: 34, weight: .bold))
            Text("· 4 files changed").font(.system(size: 34)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 34).frame(height: 88)
        .background(Glass(radius: 40))
    }

    /// Big text in the lower half, one line per scene.
    var captions: some View {
        let scenes: [(Double, Double, String, String)] = [
            (0.3, 2.6, "Your notch,", "upgraded."),
            (3.2, 6.1, "Files, tools, music", "one swipe away"),
            (6.4, 9.5, "Claude usage +", "Ask AI from the notch"),
            (9.8, 12.8, "Projects, links", "and your GitHub streak"),
            (13.3, 15.0, "Meet Dangle 👋", "it watches Claude Code for you"),
            (15.1, 16.4, "Approve from the notch", "no terminal needed"),
            (16.45, 17.4, "Done.", "4 files changed")
        ]
        return ZStack {
            ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                let o = window(t, scene.0, scene.1)
                VStack(spacing: 18) {
                    Text(scene.2).font(.system(size: 92, weight: .heavy, design: .rounded))
                    Text(scene.3).font(.system(size: 52, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.85))
                }
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
                .opacity(o)
                .offset(y: CGFloat((1 - o) * 30))
            }
        }
        .frame(width: W - 120)
        .position(x: W / 2, y: H * 0.66)
    }

    var endCard: some View {
        let o = ease(ramp(t, 17.3, 17.9))
        return ZStack {
            Color.black.opacity(0.55 * o)
            VStack(spacing: 34) {
                Dangle(size: 170, swing: sin(t * 2.4) * 7)
                Text("Hangtime").font(.system(size: 130, weight: .heavy, design: .rounded))
                Text("a notch app for your Mac").font(.system(size: 48, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.85))
                Text("built with Claude Code").font(.system(size: 38, weight: .medium, design: .rounded)).foregroundColor(clay)
            }
            .scaleEffect(0.92 + 0.08 * o)
            .opacity(o)
        }
        .frame(width: W, height: H)
    }
}

/// The camera notch: flat top, rounded bottom corners.
struct UnevenNotch: Shape {
    func path(in r: CGRect) -> Path {
        let c: CGFloat = 30
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Showcase images (LinkedIn carousel 1080×1350 and a README banner)

struct Card<Content: View>: View {
    var width: CGFloat = 1080
    var height: CGFloat = 1350
    let title: String
    let subtitle: String
    var number: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.08, green: 0.20, blue: 0.42), Color(red: 0.34, green: 0.18, blue: 0.55), Color(red: 0.72, green: 0.30, blue: 0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(accent.opacity(0.45)).frame(width: 800).blur(radius: 150).offset(x: -280, y: -300)
            Circle().fill(Color(red: 1, green: 0.45, blue: 0.35).opacity(0.35)).frame(width: 700).blur(radius: 160).offset(x: 300, y: height * 0.55)
            UnevenNotch().fill(Color.black).frame(width: 300, height: 64)
            content
            VStack(spacing: 14) {
                if let number = number {
                    Text(number).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.55))
                }
                Text(title).font(.system(size: 78, weight: .heavy, design: .rounded))
                Text(subtitle).font(.system(size: 38, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.82))
            }
            .multilineTextAlignment(.center)
            .frame(width: width - 140)
            .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
            .position(x: width / 2, y: height - 250)
            HStack(spacing: 10) {
                Dangle(size: 30)
                Text("Hangtime").font(.system(size: 28, weight: .bold, design: .rounded))
            }
            .position(x: width / 2, y: height - 56)
            .opacity(0.8)
        }
        .frame(width: width, height: height)
        .clipped()
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
    }
}

func barView<P: View>(_ page: P, index: Int) -> some View {
    HStack(spacing: 6) { page; SideColumn(page: index, t: 1) }
        .padding(8).background(Glass()).fixedSize()
}

@MainActor func renderImages(to folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func save<V: View>(_ name: String, _ view: V) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let image = renderer.cgImage,
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent(name))
            print("saved \(name)")
        }
    }
    let f = Frame(t: 13.4)
    save("01-hangtime.png", Card(title: "Hangtime", subtitle: "A notch app for my Mac, built with Claude Code") {
        VStack(spacing: 60) {
            Dangle(size: 150, swing: -6).padding(.top, 60)
            barView(MacPage(t: 1), index: 0).scaleEffect(1.25)
            HStack(spacing: 14) {
                ForEach(["Swift", "SwiftUI", "macOS", "Claude Code"], id: \.self) { tag in
                    Text(tag).font(.system(size: 26, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }
        }
    })
    save("02-mac.png", Card(title: "Your Mac, one swipe away", subtitle: "Downloads + drop shelf, tools, CPU and RAM, live music", number: "1 / 5") {
        VStack(spacing: 40) {
            barView(MacPage(t: 2), index: 0).scaleEffect(1.3).padding(.top, 230)
            barView(MacPage(t: 2), index: 0).scaleEffect(2.4).offset(x: 330).frame(width: 1080, height: 230).clipped()
                .background(Glass(radius: 0))
        }
    })
    save("03-claude.png", Card(title: "Claude, right in the notch", subtitle: "Usage limits, Claude Code tokens, and Ask AI with a mini window", number: "2 / 5") {
        VStack(spacing: 40) {
            barView(ClaudePage(t: 2), index: 1).scaleEffect(1.45).padding(.top, 230)
            barView(ClaudePage(t: 2), index: 1).scaleEffect(2.4).offset(x: 230).frame(width: 1080, height: 230).clipped()
                .background(Glass(radius: 0))
        }
    })
    save("04-code.png", Card(title: "Code and college in one place", subtitle: "Open projects in VS Code or Terminal, quick links, GitHub streak", number: "3 / 5") {
        VStack(spacing: 40) {
            barView(CodePage(t: 2), index: 2).scaleEffect(1.55).padding(.top, 230)
            barView(CodePage(t: 2), index: 2).scaleEffect(2.4).offset(x: 160).frame(width: 1080, height: 230).clipped()
                .background(Glass(radius: 0))
        }
    })
    save("05-dangle.png", Card(title: "Meet Dangle", subtitle: "It hangs from the notch and shows what Claude Code is doing, live", number: "4 / 5") {
        VStack(spacing: 22) {
            Dangle(size: 150, swing: 5)
            f.activityPill.scaleEffect(1.08)
            HStack(spacing: 30) {
                VStack(spacing: 10) { Dangle(size: 70); Text("working").font(.system(size: 24)) }
                VStack(spacing: 10) { Dangle(size: 70, glow: amber, glowAmount: 1); Text("waiting").font(.system(size: 24)) }
                VStack(spacing: 10) { Dangle(size: 70).overlay(alignment: .topTrailing) { Image(systemName: "checkmark").font(.system(size: 16, weight: .heavy)).frame(width: 30, height: 30).background(Circle().fill(green)).offset(x: 16, y: 14) }; Text("done").font(.system(size: 24)) }
                VStack(spacing: 10) { Dangle(size: 70, glow: .red, glowAmount: 1); Text("error").font(.system(size: 24)) }
            }
            .padding(.top, 40)
        }
        .padding(.top, 58)
    })
    let g = Frame(t: 15.5)
    save("06-approve.png", Card(title: "Approve from the notch", subtitle: "Allow or deny Claude Code's requests without touching the terminal", number: "5 / 5") {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.5)).frame(width: 4, height: 40)
            Dangle(size: 150, glow: amber, glowAmount: 1)
            g.permissionCard.padding(.top, 24)
        }
        .padding(.top, 58)
    })
    save("banner.png", Card(width: 1600, height: 800, title: "Hangtime", subtitle: "A glassy notch bar for macOS · with Dangle, a Claude Code companion") {
        HStack(alignment: .top, spacing: 60) {
            barView(MacPage(t: 1), index: 0).scaleEffect(1.15).frame(width: 980)
        }
        .padding(.top, 120)
        .overlay(alignment: .topTrailing) { Dangle(size: 90, swing: -6).offset(x: -40, y: 60) }
    })
}

// MARK: - Render to MP4

extension MainActor {
    /// Top-level code runs on the main thread; this tells the compiler so.
    static func assumeIsolatedIfAvailable(_ body: @MainActor () -> Void) {
        if #available(macOS 14.0, *) {
            MainActor.assumeIsolated { body() }
        } else {
            withoutActuallyEscaping(body) { fn in
                unsafeBitCast(fn, to: (() -> Void).self)()
            }
        }
    }
}

let arguments = CommandLine.arguments
if arguments.count > 2 && arguments[1] == "--images" {
    MainActor.assumeIsolatedIfAvailable { renderImages(to: URL(fileURLWithPath: arguments[2])) }
    exit(0)
}
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Hangtime-reel.mp4")
let stillsFolder: URL? = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil
try? FileManager.default.removeItem(at: output)

let writer = try! AVAssetWriter(outputURL: output, fileType: .mp4)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H)
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let total = Int(LENGTH * FPS)
let stillAt: Set<Int> = [45, 120, 230, 330, 420, 480, 510, 555]
@MainActor func renderAll() {
for index in 0..<total {
    autoreleasepool {
        let t = Double(index) / FPS
        let renderer = ImageRenderer(content: Frame(t: t))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return }
        if let folder = stillsFolder, stillAt.contains(index) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
        }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let pixel = buffer else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: Int(W), height: Int(H), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(FPS)))
        if index % 60 == 0 { print("frame \(index)/\(total)") }
    }
}
}
MainActor.assumeIsolatedIfAvailable { renderAll() }
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "Saved \(output.path)" : "Failed: \(String(describing: writer.error))")
