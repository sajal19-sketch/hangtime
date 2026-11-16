import SwiftUI
import AppKit

// MARK: - Claude Code today (tokens and sessions)

struct TokensWidget: View {
    @ObservedObject private var code = ClaudeCode.shared

    var body: some View {
        PopTile {
            VStack(alignment: .leading, spacing: 2) {
                Text("CLAUDE CODE TODAY")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(ClaudeWidget.claudeOrange)
                Text(ClaudeCode.format(code.tokens))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("tokens · \(code.sessionCount) session\(code.sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(width: 98, alignment: .leading)
        } content: {
            TokensPane()
        }
    }
}

struct TokensPane: View {
    @ObservedObject private var code = ClaudeCode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneTitle(text: "Claude Code today", symbol: "terminal.fill")
            HStack(spacing: 8) {
                stat(ClaudeCode.format(code.tokens), "total tokens")
                stat("\(code.sessionCount)", "sessions")
                stat("\(code.messageCount)", "replies")
            }
            VStack(spacing: 5) {
                row("Input", code.inputTokens)
                row("Output", code.outputTokens)
                row("Cache written", code.cacheWrite)
                row("Cache read", code.cacheRead)
            }
            Text("Counted from Claude Code's own logs on this Mac, since midnight. Cache reads are cheap, so most of your limit goes on input and output.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh") { code.scanUsage() }
                Spacer()
                if let updated = code.usageUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 290, alignment: .leading)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
            Text(caption).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(ClaudeCode.format(value)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

// MARK: - Ask AI

struct AskAIWidget: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        let service = store.service
        Tile {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("ASK AI").font(.system(size: 8, weight: .heavy)).foregroundColor(.secondary)
                    Spacer()
                    ForEach(AIService.allCases) { option in
                        Button { store.askService = option.rawValue } label: {
                            Text(option.title)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(option == service ? option.color : Color.white.opacity(0.10)))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(Pressable())
                    }
                }
                HStack(spacing: 6) {
                    Button { MiniAI.shared.show(service) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11))
                            Text("Ask \(service.title)…").font(.system(size: 12)).foregroundColor(.secondary)
                            Spacer()
                            Text("⌘⇧Space").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .help("Open \(service.title) in a small window in the top-left corner")
                    round("mic.fill", "Speak your question (macOS dictation)") { MiniAI.shared.dictate(service) }
                    round("viewfinder", "Search your screen: drag over anything to ask about it") { MiniAI.shared.screenSearch(service) }
                }
                HStack(spacing: 4) {
                    chip("doc.on.clipboard", "Explain") { withClipboard("Explain this simply:", service) }
                    chip("ladybug", "Fix error") { withClipboard("Fix this error and tell me what caused it:", service) }
                    chip("character.bubble", "Translate") { withClipboard("Translate this to English:", service) }
                    PromptsChip(service: service)
                }
            }
            .frame(width: 310)
        }
    }

    /// Sends what you last copied, with an instruction in front of it.
    private func withClipboard(_ instruction: String, _ service: AIService) {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        MiniAI.shared.ask(text.isEmpty ? instruction + " " : instruction + "\n\n" + text, service: service)
    }

    private func round(_ symbol: String, _ hint: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .help(hint)
    }

    private func chip(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { ChipFace(symbol: symbol, title: title) }
            .buttonStyle(Pressable())
            .help("\(title) what you last copied")
    }
}

struct ChipFace: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(title).font(.system(size: 10))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
        .contentShape(Rectangle())
    }
}

struct PromptsChip: View {
    let service: AIService
    @ObservedObject private var store = Store.shared
    @StateObject private var showing = Box(false)

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            showing.value.toggle()
        } label: {
            ChipFace(symbol: "bookmark", title: "Prompts")
        }
        .buttonStyle(Pressable())
        .help("Saved prompts")
        .popover(isPresented: $showing.value, arrowEdge: store.atTop ? .bottom : .top) {
            SavedPromptsPane(service: service) { showing.value = false }.padding(14)
        }
    }
}

struct SavedPromptsPane: View {
    let service: AIService
    let close: () -> Void
    @ObservedObject private var store = Store.shared
    @StateObject private var draft = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneTitle(text: "Saved prompts", symbol: "bookmark.fill")
            ForEach(Array(store.savedPrompts.enumerated()), id: \.offset) { index, prompt in
                HStack(spacing: 6) {
                    Button {
                        close()
                        MiniAI.shared.ask(prompt + " ", service: service)
                    } label: {
                        Text(prompt)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { store.savedPrompts.remove(at: index) } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            Divider()
            HStack {
                TextField("New prompt", text: $draft.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add") { add() }
            }
        }
        .frame(width: 300, alignment: .leading)
    }

    private func add() {
        let text = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.savedPrompts.append(text)
        draft.value = ""
    }
}
