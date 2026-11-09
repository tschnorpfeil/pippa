import Darwin
import Foundation

extension PiInstaller {
    // MARK: Start

    /// Environment for every Pi start: no network at start, no telemetry, Pippa's Node first in PATH.
    public static func baseEnvironment(_ roots: PiInstallRoots) -> [String: String] {
        ["HOME": roots.home.path,
         "PATH": roots.payload.node.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
         "PI_TELEMETRY": "0", "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1"]
    }

    /// Start of the pinned release for PiRPCClient. `nil` until the "Pi" step has run. Pi reads the local server's
    /// key itself from the key file (`apiKey: "!/bin/cat ..."` in models.json), as in the terminal.
    public func launchSpec(modelID: String) -> PiLaunchSpec? {
        guard let layout = state.layout else { return nil }
        let release = roots.release(layout)
        guard fm.fileExists(atPath: PiPayload.cliEntry(release: release).path) else { return nil }
        var environment = Self.baseEnvironment(roots)
        if layout != .pippaRoot { environment["PI_MANAGED_INSTALL_ROOT"] = roots.managedRoot.path }
        return PiLaunchSpec(executable: roots.payload.node, launcherArguments: [PiPayload.cliEntry(release: release).path],
                            piArguments: ["--provider", Self.providerKey, "--model", modelID], environment: environment)
    }

    /// Fixed port for the local server and models.json: chosen freely once, then remembered in Pippa's settings.json.
    public static func stablePort(support: URL) -> Int {
        var settings = PippaSettings.load(from: support)
        if let port = settings.serverPort { return port }
        let port = freePort()
        settings.serverPort = port
        try? settings.save(to: support)
        return port
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 8190 + Int.random(in: 0..<500) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : 8190 + Int.random(in: 0..<500)
    }

    /// Fixed key for the local server and `pippa-local`: generated randomly once, then stored in the key file
    /// (mode 0600, only the person themselves). Pi in the terminal reads it via `apiKey: "!/bin/cat ..."`; so the
    /// key is never in models.json and needs no environment variable. Too-wide permissions are reset to 0600.
    public static func stableKey(support: URL) throws -> String {
        let fm = FileManager.default
        let url = keyFile(support: support)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.count >= 32 {
                let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                if mode & 0o077 != 0 { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                return key
            }
        }
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let key = bytes.hexString
        let temporary = support.appendingPathComponent(".server-key-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: Data((key + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: errno))
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
        return key
    }

    public static func keyFile(support: URL) -> URL { support.appendingPathComponent("local-server-key") }
}
