import Foundation

/// Constants and wire types shared by the app and the background enforcer.
enum HF {
    static let label = "com.holdfast.enforcer"
    static let appBundleID = "com.holdfast.app"
    /// Bump when the wire protocol or enforcer behaviour changes.
    static let version = 1

    // HOLDFAST_ROOT / HOLDFAST_SOCKET redirect everything to a sandbox directory for testing.
    static var testRoot: String? { ProcessInfo.processInfo.environment["HOLDFAST_ROOT"] }
    static var isTest: Bool { testRoot != nil }
    static var stateDir: String { testRoot ?? "/Library/Application Support/Holdfast" }
    static var hostsPath: String { testRoot.map { $0 + "/hosts" } ?? "/etc/hosts" }
    static var socketPath: String {
        if let s = ProcessInfo.processInfo.environment["HOLDFAST_SOCKET"] { return s }
        return testRoot.map { $0 + "/holdfast.sock" } ?? "/var/run/holdfast.sock"
    }
}

struct BlockedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var path: String?
    var id: String { bundleID }
}

struct Request: Codable {
    /// status | passage | start | extend | unlock
    var command: String
    var apps: [BlockedApp]? = nil
    var sites: [String]? = nil
    var duration: Double? = nil
    var challengeWords: Int? = nil
    var passage: String? = nil
}

struct Response: Codable {
    var ok: Bool
    var error: String? = nil
    var version: Int = HF.version
    var active: Bool = false
    var remaining: Double = 0
    var total: Double = 0
    var apps: [BlockedApp] = []
    var sites: [String] = []
    var challengeWords: Int = 0
    var lockID: String? = nil
    var passage: String? = nil
}

enum Sites {
    /// Turns user input ("https://www.YouTube.com/watch?v=…") into a bare domain ("youtube.com").
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if let i = s.lastIndex(of: "@") { s = String(s[s.index(after: i)...]) }
        if let i = s.firstIndex(of: ":") { s = String(s[..<i]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix(".") { s.removeLast() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard s.count >= 3, s.count <= 253, s.contains("."), !s.hasPrefix("."), !s.contains(".."),
              s.allSatisfy({ allowed.contains($0) }) else { return nil }
        return s
    }

    /// Extra hostnames that serve the same site, so blocking the main domain is not trivially sidestepped.
    private static let extras: [String: [String]] = [
        "youtube.com": ["m.youtube.com", "music.youtube.com", "youtu.be", "youtube-nocookie.com", "youtubei.googleapis.com"],
        "reddit.com": ["old.reddit.com", "new.reddit.com", "i.reddit.com", "np.reddit.com", "redd.it"],
        "twitter.com": ["mobile.twitter.com", "x.com", "www.x.com", "t.co"],
        "x.com": ["twitter.com", "www.twitter.com", "mobile.twitter.com", "t.co"],
        "facebook.com": ["m.facebook.com", "web.facebook.com", "fb.com"],
        "instagram.com": ["i.instagram.com"],
        "tiktok.com": ["m.tiktok.com", "vm.tiktok.com"],
        "twitch.tv": ["m.twitch.tv"],
        "netflix.com": ["nflxvideo.net"],
        "linkedin.com": ["m.linkedin.com"],
        "discord.com": ["discordapp.com", "gateway.discord.gg"],
    ]

    static func hostnames(for domain: String) -> [String] {
        var out = [domain, "www." + domain]
        for e in extras[domain] ?? [] where !out.contains(e) { out.append(e) }
        return out
    }
}

// MARK: - Unix socket transport (one JSON request line, one JSON response)

enum Wire {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure(message: "socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads until newline, EOF, or `limit` bytes.
    static func readMessage(_ fd: Int32, limit: Int = 4 << 20) -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while data.count < limit {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
            if chunk[n - 1] == 0x0A { break }
        }
        return data
    }

    /// Client side: send one request to the enforcer and wait for the reply.
    static func send(_ request: Request) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket() failed") }
        defer { close(fd) }
        setTimeout(fd, seconds: 5)
        var addr = try address(HF.socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw Failure(message: "The Holdfast helper is not running.") }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        guard writeAll(fd, payload) else { throw Failure(message: "Could not reach the helper.") }
        let reply = readMessage(fd)
        guard let response = try? JSONDecoder().decode(Response.self, from: reply) else {
            throw Failure(message: "The helper sent an unreadable reply.")
        }
        return response
    }
}
