import Foundation

// Holdfast enforcer: a small background service that owns the lock.
// It keeps blocked apps closed and blocked sites unreachable until the timer
// runs out, whether or not the Holdfast app is open.

signal(SIGPIPE, SIG_IGN)

func log(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

struct LockState: Codable {
    var lockID: String
    var apps: [BlockedApp]
    var sites: [String]
    var total: Double
    var remaining: Double
    var challengeWords: Int
    var passage: String
}

final class Enforcer {
    private var state: LockState?
    private var lastTick: UInt64 = 0
    private var tickCount = 0
    private var termSent: [pid_t: UInt64] = [:]
    private var bundleIDCache: [String: String] = [:]
    private let statePath = HF.stateDir + "/state.json"

    private static let beginMarker = "# >>> HOLDFAST BEGIN (managed automatically, do not edit)"
    private static let endMarker = "# <<< HOLDFAST END"
    private static let maxDuration: Double = 30 * 24 * 3600

    /// Monotonic nanoseconds that keep counting during sleep and ignore clock changes,
    /// so moving the system clock forward does not end a lock early.
    private func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

    init() {
        try? FileManager.default.createDirectory(atPath: HF.stateDir, withIntermediateDirectories: true)
        if let data = FileManager.default.contents(atPath: statePath) {
            if let s = try? JSONDecoder().decode(LockState.self, from: data), s.remaining > 0 {
                state = s
                log("resumed lock \(s.lockID), \(Int(s.remaining))s remaining")
            } else {
                try? FileManager.default.removeItem(atPath: statePath)
            }
        }
        lastTick = now()
        syncHosts()
    }

    // MARK: State

    private func save() {
        guard let state, let data = try? JSONEncoder().encode(state) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        } catch {
            log("could not save state: \(error.localizedDescription)")
        }
    }

    private func endLock(reason: String) {
        log("lock ended: \(reason)")
        state = nil
        termSent.removeAll()
        try? FileManager.default.removeItem(atPath: statePath)
        syncHosts()
    }

    func tick() {
        let t = now()
        let elapsed = Double(t &- lastTick) / 1_000_000_000
        lastTick = t
        tickCount += 1
        guard state != nil else { return }
        state!.remaining -= elapsed
        if state!.remaining <= 0 {
            endLock(reason: "time elapsed")
            return
        }
        if tickCount % 10 == 0 { save() }
        if tickCount % 120 == 0 { bundleIDCache.removeAll() }
        enforceApps()
        syncHosts()
    }

    // MARK: Requests

    private func snapshot(ok: Bool = true, error: String? = nil, includePassage: Bool = false) -> Response {
        var r = Response(ok: ok, error: error)
        if let s = state {
            r.active = true
            r.remaining = s.remaining
            r.total = s.total
            r.apps = s.apps
            r.sites = s.sites
            r.challengeWords = s.challengeWords
            r.lockID = s.lockID
            if includePassage { r.passage = s.passage }
        }
        return r
    }

    private func cleanApps(_ apps: [BlockedApp]?) -> [BlockedApp] {
        var seen = Set<String>()
        return (apps ?? []).filter {
            !$0.bundleID.isEmpty && $0.bundleID != HF.appBundleID && seen.insert($0.bundleID).inserted
        }
    }

    private func cleanSites(_ sites: [String]?) -> [String] {
        var seen = Set<String>()
        return (sites ?? []).compactMap(Sites.normalize).filter { seen.insert($0).inserted }
    }

    func handle(_ req: Request) -> Response {
        switch req.command {
        case "status":
            return snapshot()

        case "passage":
            guard state != nil else { return snapshot(ok: false, error: "No lock is active.") }
            return snapshot(includePassage: true)

        case "start":
            guard state == nil else { return snapshot(ok: false, error: "A lock is already active.") }
            let apps = cleanApps(req.apps), sites = cleanSites(req.sites)
            guard !apps.isEmpty || !sites.isEmpty else {
                return snapshot(ok: false, error: "Choose at least one app or website to lock.")
            }
            guard let d = req.duration, d >= 1 else {
                return snapshot(ok: false, error: "Choose how long the lock should last.")
            }
            let duration = min(d, Self.maxDuration)
            let words = min(max(req.challengeWords ?? 10_000, 1), 100_000)
            state = LockState(lockID: UUID().uuidString, apps: apps, sites: sites, total: duration,
                              remaining: duration, challengeWords: words,
                              passage: Passage.generate(wordCount: words))
            lastTick = now()
            save()
            log("lock started: \(apps.count) apps, \(sites.count) sites, \(Int(duration))s, \(words)-word challenge")
            enforceApps()
            syncHosts()
            return snapshot()

        case "extend":
            // A running lock can only be made stricter: more time, more items.
            guard state != nil else { return snapshot(ok: false, error: "No lock is active.") }
            let extra = max(0, req.duration ?? 0)
            state!.remaining = min(state!.remaining + extra, Self.maxDuration)
            state!.total += extra
            for app in cleanApps(req.apps) where !state!.apps.contains(where: { $0.bundleID == app.bundleID }) {
                state!.apps.append(app)
            }
            for site in cleanSites(req.sites) where !state!.sites.contains(site) {
                state!.sites.append(site)
            }
            save()
            syncHosts()
            log("lock extended by \(Int(extra))s")
            return snapshot()

        case "unlock":
            guard let s = state else { return snapshot(ok: false, error: "No lock is active.") }
            let typed = (req.passage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed == s.passage else {
                return snapshot(ok: false, error: "The typed text does not match the challenge.")
            }
            endLock(reason: "challenge completed")
            return snapshot()

        default:
            return snapshot(ok: false, error: "Unknown command.")
        }
    }

    // MARK: Apps

    /// Bundle identifier of the outermost .app that contains an executable path.
    /// Matching on the identifier (not the path) means moving or renaming the app does not help.
    private func bundleID(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<r.lowerBound]) + ".app"
        if let cached = bundleIDCache[bundlePath] { return cached.isEmpty ? nil : cached }
        let info = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist")
        let id = info?["CFBundleIdentifier"] as? String ?? ""
        bundleIDCache[bundlePath] = id
        return id.isEmpty ? nil : id
    }

    private func enforceApps() {
        guard let s = state, !s.apps.isEmpty else { return }
        let blocked = Set(s.apps.map(\.bundleID))
        let capacity = Int(proc_listallpids(nil, 0)) + 128
        guard capacity > 128 else { return }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return }

        let me = getpid()
        let t = now()
        var stillBlocked = Set<pid_t>()
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) where pid > 1 && pid != me {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard let id = bundleID(forExecutable: path), blocked.contains(id) else { continue }
            stillBlocked.insert(pid)
            if let first = termSent[pid] {
                // Asked politely two seconds ago and it is still here.
                if t &- first > 2_000_000_000 { kill(pid, SIGKILL) }
            } else {
                termSent[pid] = t
                kill(pid, SIGTERM)
                log("closing blocked app \(id) (pid \(pid))")
            }
        }
        termSent = termSent.filter { stillBlocked.contains($0.key) }
    }

    // MARK: Websites

    private func syncHosts() {
        let path = HF.hostsPath
        guard let current = try? String(contentsOfFile: path, encoding: .utf8) else {
            if state != nil, !(state!.sites.isEmpty) { log("cannot read \(path)") }
            return
        }

        // Strip any existing managed block.
        var kept: [Substring] = []
        var inside = false
        for line in current.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# >>> HOLDFAST BEGIN") { inside = true; continue }
            if line.hasPrefix("# <<< HOLDFAST END") { inside = false; continue }
            if !inside { kept.append(line) }
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        var desired = kept.joined(separator: "\n") + "\n"

        if let s = state, !s.sites.isEmpty {
            var block = ["", Self.beginMarker]
            for site in s.sites {
                for host in Sites.hostnames(for: site) {
                    block.append("0.0.0.0 \(host)")
                    block.append(":: \(host)")
                }
            }
            block.append(Self.endMarker)
            desired += block.joined(separator: "\n") + "\n"
        }

        guard desired != current else { return }
        do {
            // Non-atomic on purpose: keeps the original file's owner, mode and symlink.
            try desired.write(toFile: path, atomically: false, encoding: .utf8)
            log("updated \(path)")
            flushDNS()
        } catch {
            log("could not write \(path): \(error.localizedDescription)")
        }
    }

    private func flushDNS() {
        guard !HF.isTest else { return }
        for (tool, args) in [("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"])] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }
}

// MARK: - Server

let queue = DispatchQueue(label: "com.holdfast.enforcer")
let enforcer = Enforcer()

func serve(_ fd: Int32) {
    defer { close(fd) }
    Wire.setTimeout(fd, seconds: 5)
    let data = Wire.readMessage(fd)
    let response: Response
    if let request = try? JSONDecoder().decode(Request.self, from: data) {
        response = queue.sync { enforcer.handle(request) }
    } else {
        response = Response(ok: false, error: "Malformed request.")
    }
    if var out = try? JSONEncoder().encode(response) {
        out.append(0x0A)
        _ = Wire.writeAll(fd, out)
    }
}

let socketPath = HF.socketPath
unlink(socketPath)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0, var address = try? Wire.address(socketPath) else {
    log("cannot create socket")
    exit(1)
}
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bound == 0, listen(listener, 16) == 0 else {
    log("cannot listen on \(socketPath): \(String(cString: strerror(errno)))")
    exit(1)
}
chmod(socketPath, 0o666)

Thread.detachNewThread {
    while true {
        let client = accept(listener, nil, nil)
        if client < 0 { usleep(100_000); continue }
        DispatchQueue.global().async { serve(client) }
    }
}

let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
timer.setEventHandler { enforcer.tick() }
timer.resume()

log("holdfast enforcer v\(HF.version) listening on \(socketPath)")
dispatchMain()
