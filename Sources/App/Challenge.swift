import AppKit
import SwiftUI

/// State for the early-unlock typing challenge. Only real key presses advance it,
/// so there is nothing to paste into.
@MainActor
final class ChallengeSession: ObservableObject {
    @Published var loaded = false
    @Published var index = 0
    @Published var mistakes = 0
    @Published var wrongFlash = false
    @Published var loadError: String?

    private(set) var chars: [Character] = []
    private(set) var pages: [Range<Int>] = []
    private(set) var totalWords = 0
    private(set) var wordsDone = 0
    private var lockID = ""
    private var sessionStart: Date?
    private var sessionChars = 0

    var passage: String { String(chars) }
    var finished: Bool { loaded && index >= chars.count }
    var fraction: Double { chars.isEmpty ? 0 : Double(index) / Double(chars.count) }
    var nextKey: String {
        guard index < chars.count else { return "" }
        return chars[index] == " " ? "space" : String(chars[index])
    }

    var wpm: Int? {
        guard let start = sessionStart, sessionChars >= 25 else { return nil }
        let minutes = Date().timeIntervalSince(start) / 60
        return minutes > 0 ? Int(Double(sessionChars) / 5 / minutes) : nil
    }

    var etaSeconds: Double? {
        guard let wpm, wpm > 0 else { return nil }
        return Double(chars.count - index) / 5 / Double(wpm) * 60
    }

    func load() {
        guard !loaded else { return }
        Task.detached {
            let result = try? Wire.send(Request(command: "passage"))
            await MainActor.run {
                guard let r = result, r.ok, let text = r.passage, let id = r.lockID else {
                    self.loadError = result?.error ?? "Could not load the challenge."
                    return
                }
                self.prepare(text: text, lockID: id)
            }
        }
    }

    private func prepare(text: String, lockID: String) {
        chars = Array(text)
        self.lockID = lockID
        totalWords = text.split(separator: " ").count

        // Pages of about 45 words, each ending just after a space.
        var start = 0, spaces = 0
        pages = []
        for (i, c) in chars.enumerated() where c == " " {
            spaces += 1
            if spaces % 45 == 0 {
                pages.append(start..<(i + 1))
                start = i + 1
            }
        }
        if start < chars.count { pages.append(start..<chars.count) }

        index = min(UserDefaults.standard.integer(forKey: progressKey), chars.count)
        wordsDone = chars[..<index].reduce(0) { $0 + ($1 == " " ? 1 : 0) }
        loaded = true
    }

    private var progressKey: String { "challenge.progress." + lockID }

    func saveProgress() {
        guard loaded else { return }
        UserDefaults.standard.set(index, forKey: progressKey)
    }

    func clearProgress() {
        UserDefaults.standard.removeObject(forKey: progressKey)
    }

    func type(_ c: Character) {
        guard loaded, index < chars.count else { return }
        if sessionStart == nil { sessionStart = Date() }
        if c == chars[index] {
            if c == " " { wordsDone += 1 }
            index += 1
            sessionChars += 1
            if index == chars.count { wordsDone = totalWords }
            if index % 25 == 0 || index == chars.count { saveProgress() }
        } else {
            mistakes += 1
            wrongFlash = true
            Task {
                try? await Task.sleep(nanoseconds: 160_000_000)
                self.wrongFlash = false
            }
        }
    }

    var pageNumber: Int { pages.firstIndex { $0.contains(index) } ?? max(0, pages.count - 1) }

    func pageText() -> AttributedString {
        guard loaded, !pages.isEmpty else { return AttributedString("") }
        let range = pages[pageNumber]
        let cursor = min(index, range.upperBound)
        var typed = AttributedString(String(chars[range.lowerBound..<cursor]))
        typed.foregroundColor = Color.green.opacity(0.75)
        var out = typed
        if cursor < range.upperBound {
            var current = AttributedString(String(chars[cursor]))
            current.backgroundColor = wrongFlash ? Color.red : Color.accentColor
            current.foregroundColor = .white
            var rest = AttributedString(String(chars[(cursor + 1)..<range.upperBound]))
            rest.foregroundColor = Color.primary
            out += current + rest
        }
        return out
    }
}

/// Invisible view that owns keyboard focus and reports typed characters.
struct KeyCatcher: NSViewRepresentable {
    var onCharacter: (Character) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onCharacter = onCharacter
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onCharacter = onCharacter
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    final class CatcherView: NSView {
        var onCharacter: ((Character) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return }
            guard let text = event.characters, text.count == 1, let c = text.first else { return }
            guard c.isLetter || c.isNumber || c.isPunctuation || c == " " else { return }
            onCharacter?(c)
        }
    }
}

struct ChallengeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var session = ChallengeSession()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    session.saveProgress()
                    model.showChallenge = false
                } label: {
                    Label("Back to lock", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                if let s = model.status {
                    Label(Fmt.clock(s.remaining) + " left on the lock", systemImage: "lock.fill")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)

            if let error = session.loadError {
                Spacer()
                Text(error).foregroundStyle(.secondary)
                Spacer()
            } else if !session.loaded {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                content
            }
        }
        .background(KeyCatcher { session.type($0) })
        .onAppear { session.load() }
        .onDisappear { session.saveProgress() }
        .onChange(of: session.finished) { done in
            if done {
                session.clearProgress()
                model.submitChallenge(passage: session.passage)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Type to unlock early")
                    .font(.system(size: 26, weight: .semibold))
                Text("Type the text below exactly, including capitals and punctuation. A wrong key does not move you forward. Pasting is not possible, and your progress is saved if you leave.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: session.fraction)
                    .tint(.accentColor)
                HStack(spacing: 18) {
                    stat("\(Fmt.number(session.wordsDone)) / \(Fmt.number(session.totalWords))", "words")
                    stat(String(format: "%.1f%%", session.fraction * 100), "done")
                    stat(session.wpm.map { "\($0)" } ?? "–", "wpm")
                    stat(session.etaSeconds.map(Fmt.span) ?? "–", "to go")
                    stat("\(Fmt.number(session.mistakes))", "mistakes")
                    Spacer()
                    if !session.finished {
                        HStack(spacing: 6) {
                            Text("Next key").foregroundStyle(.secondary)
                            Text(session.nextKey)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                        }
                        .font(.callout)
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(session.wrongFlash ? Color.red.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: 1)
                if session.finished {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Checking with the helper…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(session.pageText())
                        .font(.system(size: 19, design: .monospaced))
                        .lineSpacing(9)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity)

            Text("Section \(session.pageNumber + 1) of \(session.pages.count)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.callout.monospacedDigit().weight(.medium))
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
