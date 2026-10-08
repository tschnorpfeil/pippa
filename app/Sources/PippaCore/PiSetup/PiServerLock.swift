import Darwin
import Foundation

/// The one lock/PID file for the llama-server of `pippa-local` (`<Support>/llama-server-pi.lock`). The app
/// (`LlamaServer` with `lockFile`) and Pippa's terminal extension (runtime/pippa-local-server/common.mjs) read and
/// write the same format, so two servers never run:
///
///     {"owner":"app"|"pi","holder":<pid of the app or the watcher>,"pid":<pid of the server or null>,"port":…,"startedAt":"…"}
///
/// Created only exclusively (O_EXCL). Alive: with `pid` as long as the server lives, before that (start) as long as `holder` lives.
/// Whoever ends the server removes the file, but only while it is still theirs.
public struct PiServerLock: Sendable, Equatable {
    public var owner: String
    public var holder: Int32
    public var pid: Int32?
    public var port: Int
    public var startedAt: String

    public init(owner: String, holder: Int32, pid: Int32?, port: Int, startedAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.owner = owner; self.holder = holder; self.pid = pid; self.port = port; self.startedAt = startedAt
    }

    public static let fileName = "llama-server-pi.lock"
    public static func url(support: URL) -> URL { support.appendingPathComponent(fileName) }

    public var isLive: Bool { pid.map(Self.isAlive) ?? Self.isAlive(holder) }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    var json: Data {
        var object: [String: Any] = ["owner": owner, "holder": Int(holder), "port": port, "startedAt": startedAt]
        object["pid"] = pid.map { Int($0) } ?? NSNull()
        return ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()) + Data("\n".utf8)
    }

    /// `nil`: no file or not readable.
    public static func read(_ url: URL) -> PiServerLock? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = object["owner"] as? String, let holder = object["holder"] as? Int, let port = object["port"] as? Int else { return nil }
        return PiServerLock(owner: owner, holder: Int32(holder), pid: (object["pid"] as? Int).map(Int32.init), port: port,
                            startedAt: object["startedAt"] as? String ?? "")
    }

    /// Create exclusively; `false` if a lock already exists.
    public static func create(_ url: URL, _ lock: PiServerLock) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let data = lock.json
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        close(fd)
        return true
    }

    /// Replace the content of an own lock (temp file + rename).
    public static func write(_ url: URL, _ lock: PiServerLock) {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(fileName).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: lock.json, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }

    /// Remove if `matches` still recognizes the current lock as the expected one (never a foreign, newer one).
    @discardableResult
    public static func remove(_ url: URL, if matches: (PiServerLock) -> Bool) -> Bool {
        if let lock = read(url), !matches(lock) { return false }
        return unlink(url.path) == 0
    }

    /// Mark as "in use": the terminal extension's watcher counts the modification time as a request.
    public static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
