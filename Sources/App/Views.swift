import AppKit
import SwiftUI

@main
struct HoldfastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Holdfast", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 660)
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.isLocked {
                if model.showChallenge { ChallengeView() } else { LockedView() }
            } else {
                SetupView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Holdfast", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Shared pieces

struct Card<Content: View>: View {
    var title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct RemoveButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

struct Chip: View {
    var label: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPicker = false
    @State private var showConfirm = false
    @State private var newSite = ""
    @State private var siteInvalid = false

    private let durationPresets: [(String, Int)] = [("25 min", 25), ("1 hr", 60), ("2 hr", 120), ("4 hr", 240), ("8 hr", 480), ("24 hr", 1440)]
    private let wordPresets = [500, 2_000, 10_000]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if model.justUnlocked { banner(icon: "lock.open.fill", tint: .green, text: "Lock lifted. Everything is available again.") }
                    helperBanner
                    HStack(alignment: .top, spacing: 16) { appsCard; sitesCard }
                        .frame(height: 250)
                    HStack(alignment: .top, spacing: 16) { durationCard; challengeCard }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            Divider()
            startBar
        }
        .sheet(isPresented: $showPicker) { AppPicker().environmentObject(model) }
        .alert("Start this lock?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Lock for \(Fmt.span(model.duration))") { model.startLock() }
        } message: {
            Text("\(summary) will be unavailable for \(Fmt.span(model.duration)). Locked apps that are open will be closed, so save your work first. Quitting Holdfast or restarting your Mac will not lift the lock. The only way out early is typing \(Fmt.number(model.challengeWords)) words.")
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !model.apps.isEmpty { parts.append("\(model.apps.count) app\(model.apps.count == 1 ? "" : "s")") }
        if !model.sites.isEmpty { parts.append("\(model.sites.count) website\(model.sites.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " and ")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Holdfast").font(.system(size: 24, weight: .semibold))
                Text("Lock distracting apps and websites until the timer runs out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.helper == .ready {
                Menu {
                    Button("Remove background helper…") { model.uninstallHelper() }
                } label: {
                    Label("Helper running", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder private var helperBanner: some View {
        switch model.helper {
        case .missing, .outdated:
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.helper == .missing ? "One-time setup needed" : "Helper update needed").font(.headline)
                    Text("Holdfast uses a small background helper to keep locks in force when the app is closed. Installing it needs your Mac administrator password once.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(model.helper == .missing ? "Install Helper" : "Update Helper") { model.installHelper() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        case .checking, .ready:
            EmptyView()
        }
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12)))
    }

    private var appsCard: some View {
        Card(title: "Apps", trailing: model.apps.isEmpty ? nil : "\(model.apps.count)") {
            if model.apps.isEmpty {
                Text("No apps chosen yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.apps) { app in
                            HStack(spacing: 8) {
                                Image(nsImage: AppCatalog.icon(for: app)).resizable().frame(width: 22, height: 22)
                                Text(app.name).lineLimit(1)
                                Spacer()
                                RemoveButton { model.toggle(app) }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            Button {
                showPicker = true
            } label: {
                Label("Choose Apps…", systemImage: "plus")
            }
        }
    }

    private var sitesCard: some View {
        Card(title: "Websites", trailing: model.sites.isEmpty ? nil : "\(model.sites.count)") {
            if model.sites.isEmpty {
                Text("No websites added yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.sites, id: \.self) { site in
                            HStack(spacing: 8) {
                                Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 22)
                                Text(site).lineLimit(1)
                                Spacer()
                                RemoveButton { model.sites.removeAll { $0 == site } }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            HStack {
                TextField("youtube.com", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSite)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(siteInvalid ? Color.red : Color.clear))
                Button("Add", action: addSite)
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addSite() {
        guard !newSite.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if model.addSite(newSite) {
            newSite = ""
            siteInvalid = false
        } else {
            siteInvalid = true
        }
    }

    private var durationCard: some View {
        Card(title: "Lock for") {
            HStack(spacing: 6) {
                ForEach(durationPresets, id: \.1) { preset in
                    Chip(label: preset.0, selected: model.hours * 60 + model.minutes == preset.1) {
                        model.hours = preset.1 / 60
                        model.minutes = preset.1 % 60
                    }
                }
            }
            HStack(spacing: 14) {
                Stepper(value: $model.hours, in: 0...168) {
                    Text("\(model.hours) hr").monospacedDigit().frame(width: 52, alignment: .leading)
                }
                Stepper(value: $model.minutes, in: 0...59, step: 5) {
                    Text("\(model.minutes) min").monospacedDigit().frame(width: 52, alignment: .leading)
                }
            }
            Text(model.duration >= 60 ? "Unlocks \(Fmt.time(Date().addingTimeInterval(model.duration)))" : "Choose at least one minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var challengeCard: some View {
        Card(title: "To unlock early, type") {
            HStack(spacing: 6) {
                ForEach(wordPresets, id: \.self) { n in
                    Chip(label: "\(Fmt.number(n)) words", selected: model.challengeWords == n) { model.challengeWords = n }
                }
            }
            HStack(spacing: 8) {
                TextField("", value: $model.challengeWords, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onChange(of: model.challengeWords) { v in
                        if v < 10 { model.challengeWords = 10 } else if v > 100_000 { model.challengeWords = 100_000 }
                    }
                Stepper("words", value: $model.challengeWords, in: 10...100_000, step: 500)
            }
            Text("About \(Fmt.span(Double(model.challengeWords) / 40 * 60)) of typing at 40 words per minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var startBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.apps.isEmpty && model.sites.isEmpty ? "Choose something to lock" : "\(summary) for \(Fmt.span(model.duration))")
                    .font(.headline)
                Text("The lock stays on if you quit Holdfast or restart your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showConfirm = true
            } label: {
                Label("Start Lock", systemImage: "lock.fill").padding(.horizontal, 10)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canStart)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

// MARK: - App picker

struct AppPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var installed: [InstalledApp] = []
    @State private var search = ""
    @State private var loading = true

    private var filtered: [InstalledApp] {
        search.isEmpty ? installed : installed.filter { $0.app.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose apps to lock").font(.headline)
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(16)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { item in
                    let selected = model.apps.contains { $0.bundleID == item.app.bundleID }
                    Button {
                        model.toggle(item.app)
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: item.icon).resizable().frame(width: 26, height: 26)
                            Text(item.app.name)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                                .font(.title3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(model.apps.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: 540)
        .task {
            let apps = await Task.detached { AppCatalog.scan() }.value
            installed = apps
            loading = false
        }
    }
}

// MARK: - Locked

struct LockedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.status ?? Response(ok: true)
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: s.total > 0 ? max(0, min(1, s.remaining / s.total)) : 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: s.remaining)
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.title2).foregroundStyle(Color.accentColor)
                    Text(Fmt.clock(s.remaining))
                        .font(.system(size: 46, weight: .semibold).monospacedDigit())
                    Text("Unlocks \(Fmt.time(Date().addingTimeInterval(s.remaining)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 270, height: 270)

            VStack(spacing: 10) {
                Text("Locked now").font(.headline)
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(s.apps) { app in
                            HStack(spacing: 6) {
                                Image(nsImage: AppCatalog.icon(for: app)).resizable().frame(width: 18, height: 18)
                                Text(app.name)
                            }
                            .modifier(Pill())
                        }
                        ForEach(s.sites, id: \.self) { site in
                            HStack(spacing: 6) {
                                Image(systemName: "globe").foregroundStyle(.secondary)
                                Text(site)
                            }
                            .modifier(Pill())
                        }
                    }
                    .frame(maxWidth: 620)
                }
                .frame(maxHeight: 130)
            }

            Spacer(minLength: 8)

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Menu {
                        Button("Add 15 minutes") { model.addTime(minutes: 15) }
                        Button("Add 30 minutes") { model.addTime(minutes: 30) }
                        Button("Add 1 hour") { model.addTime(minutes: 60) }
                    } label: {
                        Label("Add Time", systemImage: "plus")
                    }
                    .fixedSize()
                    Button {
                        model.showChallenge = true
                    } label: {
                        Label("Unlock Early…", systemImage: "keyboard")
                    }
                }
                .controlSize(.large)
                Text("You can quit Holdfast. The lock stays on until the timer ends.\nUnlocking early means typing \(Fmt.number(s.challengeWords)) words.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 26)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Pill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// Wraps children onto as many centred rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let all = rows(subviews, width: width)
        let height = all.reduce(CGFloat(0)) { $0 + ($1.map(\.1.height).max() ?? 0) } + spacing * CGFloat(max(0, all.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            let rowHeight = row.map(\.1.height).max() ?? 0
            var x = bounds.minX + (bounds.width - rowWidth) / 2
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
