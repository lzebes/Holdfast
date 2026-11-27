import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Helper { case checking, missing, outdated, ready }

    @Published var helper: Helper = .checking
    @Published var status: Response?
    @Published var apps: [BlockedApp] = [] { didSet { persist() } }
    @Published var sites: [String] = [] { didSet { persist() } }
    @Published var hours = 1 { didSet { persist() } }
    @Published var minutes = 0 { didSet { persist() } }
    @Published var challengeWords = 10_000 { didSet { persist() } }
    @Published var errorMessage: String?
    @Published var busy = false
    @Published var showChallenge = false
    @Published var justUnlocked = false

    private var timer: Timer?
    private var loading = true

    var isLocked: Bool { status?.active == true }
    var duration: Double { Double(hours * 3600 + minutes * 60) }
    var canStart: Bool { helper == .ready && duration >= 60 && !(apps.isEmpty && sites.isEmpty) && !busy }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "apps"), let saved = try? JSONDecoder().decode([BlockedApp].self, from: data) {
            apps = saved
        }
        sites = d.stringArray(forKey: "sites") ?? []
        if d.object(forKey: "hours") != nil {
            hours = d.integer(forKey: "hours")
            minutes = d.integer(forKey: "minutes")
        }
        if d.object(forKey: "challengeWords") != nil { challengeWords = max(10, d.integer(forKey: "challengeWords")) }
        loading = false

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func persist() {
        guard !loading else { return }
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(apps), forKey: "apps")
        d.set(sites, forKey: "sites")
        d.set(hours, forKey: "hours")
        d.set(minutes, forKey: "minutes")
        d.set(challengeWords, forKey: "challengeWords")
    }

    // MARK: Helper communication

    func refresh() {
        Task.detached {
            let result = try? Wire.send(Request(command: "status"))
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ response: Response?) {
        guard let response else {
            helper = .missing
            status = nil
            return
        }
        helper = response.version == HF.version ? .ready : .outdated
        status = response
        if !response.active { showChallenge = false }
    }

    private func perform(_ request: Request, onSuccess: (@MainActor () -> Void)? = nil) {
        busy = true
        Task.detached {
            let result = Result { try Wire.send(request) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let r):
                    self.apply(r)
                    if r.ok { onSuccess?() } else { self.errorMessage = r.error ?? "Something went wrong." }
                case .failure(let e):
                    self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    func startLock() {
        justUnlocked = false
        // Ask running apps to quit normally first so they can save their work.
        let ids = Set(apps.map(\.bundleID))
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, ids.contains(id) { app.terminate() }
        }
        perform(Request(command: "start", apps: apps, sites: sites, duration: duration, challengeWords: challengeWords))
    }

    func addTime(minutes: Int) {
        perform(Request(command: "extend", duration: Double(minutes * 60)))
    }

    func submitChallenge(passage: String) {
        perform(Request(command: "unlock", passage: passage)) {
            self.showChallenge = false
            self.justUnlocked = true
        }
    }

    // MARK: Selection editing

    func addSite(_ raw: String) -> Bool {
        guard let site = Sites.normalize(raw) else { return false }
        if !sites.contains(site) { sites.append(site) }
        return true
    }

    func toggle(_ app: BlockedApp) {
        if let i = apps.firstIndex(where: { $0.bundleID == app.bundleID }) {
            apps.remove(at: i)
        } else {
            apps.append(app)
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: Helper install

    func installHelper() { runPrivileged(script: "install-helper.sh") }
    func uninstallHelper() { runPrivileged(script: "uninstall-helper.sh") }

    private func runPrivileged(script: String) {
        guard let resources = Bundle.main.resourcePath else { return }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // macOS shows its own administrator prompt; Holdfast never sees the password.
        let source = "do shell script \"/bin/sh \" & quoted form of \(quoted(resources + "/" + script)) & \" \" & "
            + "quoted form of \(quoted(resources)) with prompt \"Holdfast needs to set up its background helper.\" "
            + "with administrator privileges"
        busy = true
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            var message: String?
            do {
                try p.run()
                let data = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if !text.contains("-128") { message = text.isEmpty ? "The helper could not be set up." : text }
                }
            } catch {
                message = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let failure = message
            await MainActor.run {
                self.busy = false
                self.errorMessage = failure
                self.refresh()
            }
        }
    }
}

// MARK: - Installed apps

struct InstalledApp: Identifiable {
    let app: BlockedApp
    let icon: NSImage
    var id: String { app.bundleID }
}

enum AppCatalog {
    static func icon(for app: BlockedApp) -> NSImage {
        if let path = app.path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var found: [String: InstalledApp] = [:]

        func visit(_ dir: String, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries where !entry.hasPrefix(".") {
                let path = dir + "/" + entry
                if entry.hasSuffix(".app") {
                    guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier,
                          id != HF.appBundleID, found[id] == nil else { continue }
                    let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                    found[id] = InstalledApp(app: BlockedApp(bundleID: id, name: name, path: path),
                                             icon: NSWorkspace.shared.icon(forFile: path))
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { visit(path, depth: depth + 1) }
                }
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return found.values.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }
}

// MARK: - Formatting

enum Fmt {
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func span(_ seconds: Double) -> String {
        let m = max(0, Int((seconds / 60).rounded()))
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        if h >= 48 && r == 0 && h % 24 == 0 { return "\(h / 24) days" }
        return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        return f.string(from: date)
    }
}
