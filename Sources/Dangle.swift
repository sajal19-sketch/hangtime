import SwiftUI
import AppKit

/// Dangle: the Claude Code character, hanging upside down from the notch.
/// It is drawn in your accent colour; its mood shows through glow and movement.
enum DangleMood {
    case idle, working, waiting, done, error

    init(_ state: ClaudeCode.State?) {
        switch state {
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        case .error: self = .error
        case nil: self = .idle
        }
    }

    var glow: Color? {
        switch self {
        case .waiting: return Color(red: 0.96, green: 0.71, blue: 0.0)
        case .error: return Color.red
        default: return nil
        }
    }
}

/// The Claude Code pixel character from its 24×24 SVG (the eyes are holes).
struct DangleShape: Shape {
    private static let data = "M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z"

    /// The icon only uses M m H h V v Z z, so a tiny reader is enough.
    private static let tokens: [String] = {
        guard let regex = try? NSRegularExpression(pattern: "[MmHhVvZz]|-?[0-9]*\\.?[0-9]+") else { return [] }
        let range = NSRange(data.startIndex..., in: data)
        return regex.matches(in: data, range: range).compactMap { Range($0.range, in: data).map { String(data[$0]) } }
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale) }
        var path = Path()
        var point = CGPoint.zero
        var start = CGPoint.zero
        var command = "M"
        var index = 0
        let list = DangleShape.tokens
        func next() -> CGFloat? {
            guard index < list.count, let value = Double(list[index]) else { return nil }
            index += 1
            return CGFloat(value)
        }
        while index < list.count {
            if Double(list[index]) == nil {
                command = list[index]
                index += 1
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    point = start
                    continue
                }
            }
            switch command {
            case "M", "m":
                guard let x = next(), let y = next() else { return path }
                point = command == "M" ? CGPoint(x: x, y: y) : CGPoint(x: point.x + x, y: point.y + y)
                start = point
                path.move(to: at(point))
                command = command == "M" ? "L" : "l"     // extra pairs after a move are lines
            case "H": guard let x = next() else { return path }; point.x = x; path.addLine(to: at(point))
            case "h": guard let x = next() else { return path }; point.x += x; path.addLine(to: at(point))
            case "V": guard let y = next() else { return path }; point.y = y; path.addLine(to: at(point))
            case "v": guard let y = next() else { return path }; point.y += y; path.addLine(to: at(point))
            case "L":
                guard let x = next(), let y = next() else { return path }
                point = CGPoint(x: x, y: y); path.addLine(to: at(point))
            case "l":
                guard let x = next(), let y = next() else { return path }
                point = CGPoint(x: point.x + x, y: point.y + y); path.addLine(to: at(point))
            default:
                index += 1
            }
        }
        return path
    }
}

/// Dangle at any size. `hanging` adds the gentle swing (working) or a shake (error).
struct DangleView: View {
    let size: CGFloat
    let mood: DangleMood
    var animated = true
    @ObservedObject private var store = Store.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || !(mood == .working || mood == .error || mood == .waiting))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let swing: Double = {
                switch mood {
                case .working: return sin(t * 2.4) * 7
                case .error: return sin(t * 30) * 4 * max(0, 1 - (t.truncatingRemainder(dividingBy: 1.5)))
                case .waiting: return sin(t * 5) * 3
                default: return 0
                }
            }()
            let pulse = mood == .waiting ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 4)) : 1
            DangleShape()
                .fill(store.accentColor, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(180))
                .opacity(mood == .idle ? 0.45 : 1)
                .shadow(color: (mood.glow ?? .clear).opacity(pulse), radius: size * 0.18)
                .shadow(color: (mood.glow ?? .clear).opacity(pulse * 0.6), radius: size * 0.08)
                .rotationEffect(.degrees(swing), anchor: .top)
        }
        .frame(width: size, height: size)
    }
}
