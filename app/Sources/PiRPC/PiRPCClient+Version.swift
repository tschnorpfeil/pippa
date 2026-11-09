import Foundation
import Synchronization

extension PiRPCClient {
    // MARK: Version

    /// Read `pi --version` and check it against the tested range.
    public static func checkVersion(executable: URL, launcherArguments: [String] = [], environment: [String: String] = [:]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PiRPCError.notInstalled(path: executable.path) }
        let child = Process(), out = Pipe()
        child.executableURL = executable
        child.arguments = launcherArguments + ["--version"]
        child.environment = processEnvironment(environment)
        child.standardOutput = out; child.standardError = out
        do { try child.run() } catch { throw PiRPCError.versionUnreadable(output: "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return try checkVersion(output: String(decoding: data, as: UTF8.self))
    }

    /// `checkVersion` once per installed Pi: Pi restarts with every conversation switch, and each `--version` is
    /// another Node cold start. A reinstall at the same path keeps the pinned version (PiInstaller).
    private static let checkedVersions = Mutex<[String: String]>([:])
    static func checkedVersion(_ configuration: PiRPCConfiguration) throws -> String {
        let key = ([configuration.executable.path] + configuration.launcherArguments).joined(separator: "\u{0}")
        if let known = checkedVersions.withLock({ $0[key] }), FileManager.default.isExecutableFile(atPath: configuration.executable.path) { return known }
        let found = try checkVersion(executable: configuration.executable, launcherArguments: configuration.launcherArguments,
                                     environment: configuration.environment)
        checkedVersions.withLock { $0[key] = found }
        return found
    }

    private static let versionPattern = try! NSRegularExpression(pattern: #"\b(\d+)\.(\d+)\.(\d+)\b"#)

    /// Only the check, for tests with made-up output.
    public static func checkVersion(output: String) throws -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = versionPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { throw PiRPCError.versionUnreadable(output: text) }
        let found = String(text[range])
        guard found.hasPrefix(supportedVersionPrefix) else { throw PiRPCError.versionMismatch(found: found, supported: supportedVersionPrefix + "x") }
        return found
    }

    static func processEnvironment(_ extra: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env = Dictionary(uniqueKeysWithValues: ["HOME", "TMPDIR", "LANG", "USER", "LOGNAME"].compactMap { key in inherited[key].map { (key, $0) } })
        let path = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.contains($0) } + [path]).joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        return env
    }
}
