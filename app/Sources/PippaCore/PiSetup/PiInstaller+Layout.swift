import Darwin
import Foundation

extension PiInstaller {
    /// Official layout next to the release: current-version, launcher, marker, ~/.local/bin/pi, Node for the terminal.
    /// Only what is missing; existing things stay as they are.
    func ensureOfficialLayout() throws {
        let root = roots.managedRoot
        let current = root.appendingPathComponent("current-version")
        if !fm.fileExists(atPath: current.path) {
            try "\(roots.pin)\n".write(to: current, atomically: true, encoding: .utf8)
            state.record(current)
        }
        if !fm.fileExists(atPath: roots.launcher.path) {
            try makeDirectory(roots.launcher.deletingLastPathComponent())
            try Self.launcherScript.write(to: roots.launcher, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roots.launcher.path)
            state.record(roots.launcher)
        }
        let marker = root.appendingPathComponent("managed-install.json")
        if !fm.fileExists(atPath: marker.path) {
            try Self.markerJSON(entrypoint: roots.entrypoint).write(to: marker, atomically: true, encoding: .utf8)
            state.record(marker)
        }
        save()
        // An existing ~/.local/bin/pi (even a broken symlink) belongs to someone else.
        if (try? fm.destinationOfSymbolicLink(atPath: roots.entrypoint.path)) == nil, !fm.fileExists(atPath: roots.entrypoint.path) {
            try makeDirectory(roots.entrypoint.deletingLastPathComponent())
            try fm.createSymbolicLink(atPath: roots.entrypoint.path, withDestinationPath: "../../.pi/agent/bin/pi")
            state.record(roots.entrypoint)
            save()
        }
        try ensurePiNode()
    }

    /// Node (and npm) under ~/.local/share/pi-node/<version>, `current` points to it. The launcher puts it before
    /// PATH; without it `pi` in the terminal would find no Node on a fresh Mac.
    /// If a new Pippa ships a different Node, a `current` created by Pippa follows (next to the old one,
    /// switched atomically via rename); a foreign `current` stays.
    func ensurePiNode() throws {
        let current = roots.piNode.appendingPathComponent("current")
        let existing = try? fm.destinationOfSymbolicLink(atPath: current.path)
        if existing == nil, fm.fileExists(atPath: current.path) { return }
        if existing != nil, !state.didCreate(current) { return }
        guard let nodeVersion = Self.run(roots.payload.node, ["--version"], environment: [:])?.output
            .trimmingCharacters(in: .whitespacesAndNewlines), nodeVersion.hasPrefix("v") else {
            throw PiInstallFailure.payloadMissing(roots.payload.node.path)
        }
        let target = roots.piNode.appendingPathComponent(nodeVersion, isDirectory: true)
        if !fm.fileExists(atPath: target.path) {
            try makeDirectory(roots.piNode)
            for leftover in (try? fm.contentsOfDirectory(at: roots.piNode, includingPropertiesForKeys: nil)) ?? []
            where leftover.lastPathComponent.hasPrefix(".pippa-") { try fm.removeItem(at: leftover) }
            let temporary = roots.piNode.appendingPathComponent(".pippa-\(nodeVersion)-\(UUID().uuidString)", isDirectory: true)
            let bin = temporary.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.copyItem(at: roots.payload.node, to: bin.appendingPathComponent("node"))
            if let npm = roots.payload.npm, fm.fileExists(atPath: npm.path) {
                let modules = temporary.appendingPathComponent("lib/node_modules", isDirectory: true)
                try fm.createDirectory(at: modules, withIntermediateDirectories: true)
                try fm.copyItem(at: npm, to: modules.appendingPathComponent("npm"))
                try fm.createSymbolicLink(atPath: bin.appendingPathComponent("npm").path, withDestinationPath: "../lib/node_modules/npm/bin/npm-cli.js")
                try fm.createSymbolicLink(atPath: bin.appendingPathComponent("npx").path, withDestinationPath: "../lib/node_modules/npm/bin/npx-cli.js")
            }
            try fm.moveItem(at: temporary, to: target)
            state.record(target)
        }
        if existing == nodeVersion { return }
        let link = roots.piNode.appendingPathComponent(".pippa-current-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: nodeVersion)
        guard rename(link.path, current.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: link)
            throw PiInstallFailure.notWritable(path: current.path, reason: SystemError.reason(errno: code))
        }
        state.record(current)
        save()
    }

    // MARK: Pi switch with a Pippa update

    /// The terminal Pi in the official layout that Pippa created follows the pin: only if `current-version`
    /// points to a release Pippa created itself and that is older than the pin. If the person switched
    /// themselves (`pi update`, even to a newer version), everything stays as it is. Switch is atomic (rename),
    /// then `pi --version` via the launcher as in the terminal; if that fails, the old version applies again.
    /// Pippa's own sessions do not depend on this: they always start `releases/<pin>` directly (`launchSpec`).
    @discardableResult
    func advanceTerminalPi() -> Bool {
        let file = roots.managedRoot.appendingPathComponent("current-version")
        guard state.didCreate(file),
              let current = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              current != roots.pin, Self.isOlder(current, than: roots.pin),
              state.didCreate(roots.managedRoot.appendingPathComponent("releases/\(current)", isDirectory: true)) else { return false }
        guard (try? writeCurrentVersion(roots.pin, to: file)) != nil else { return false }
        let found = Self.run(roots.launcher, ["--version"], environment: ["HOME": roots.home.path, "PATH": "/usr/bin:/bin"])?
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        if found == roots.pin { return true }
        try? writeCurrentVersion(current, to: file)
        return false
    }

    /// Like Pi's `activateManagedRelease`: temporary file next to it, then rename.
    func writeCurrentVersion(_ version: String, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent("current-version.pippa-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try "\(version)\n".write(to: temporary, atomically: false, encoding: .utf8)
        guard rename(temporary.path, file.path) == 0 else {
            throw PiInstallFailure.notWritable(path: file.path, reason: SystemError.reason(errno: errno))
        }
    }


    // MARK: Files in the official layout

    /// Pi's launcher (~/.pi/agent/bin/pi), content as from Pi's installer (layout releases-v1).
    public static let launcherScript = #"""
    #!/bin/sh
    case "$0" in
      */*) pi_launcher="$0" ;;
      *) pi_launcher=$(command -v "$0") || exit 127 ;;
    esac
    while [ -L "$pi_launcher" ]; do
      pi_link=$(readlink "$pi_launcher") || exit 1
      case "$pi_link" in
        /*) pi_launcher="$pi_link" ;;
        *) pi_launcher=${pi_launcher%/*}/$pi_link ;;
      esac
    done
    pi_bin_dir=${pi_launcher%/*}
    pi_agent_dir=${pi_bin_dir%/*}
    pi_current_file=$pi_agent_dir/install/current-version
    if ! IFS= read -r pi_current_version < "$pi_current_file"; then
      printf 'Could not read managed Pi version from %s.\n' "$pi_current_file" >&2
      exit 1
    fi
    case "$pi_current_version" in
      ""|.|..|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*)
        printf 'Managed Pi version file is invalid: %s\n' "$pi_current_file" >&2
        exit 1
        ;;
    esac
    pi_release_dir=$pi_agent_dir/install/releases/$pi_current_version
    pi_release_bin=$pi_release_dir/node_modules/.bin/pi
    if [ ! -x "$pi_release_bin" ]; then
      printf 'Managed Pi executable is missing: %s\n' "$pi_release_bin" >&2
      exit 1
    fi
    # Node.js installed by the Pi installer is not added to shell profiles, so put
    # it on PATH for pi's shebang and for child processes: npm in pi update and
    # commands run through pi's bash tool.
    pi_node_bin=${XDG_DATA_HOME:-$HOME/.local/share}/pi-node/current/bin
    if [ -x "$pi_node_bin/node" ]; then
      PATH=$pi_node_bin:$PATH
      export PATH
    fi
    PI_MANAGED_INSTALL_ROOT=$pi_agent_dir/install
    export PI_MANAGED_INSTALL_ROOT
    exec "$pi_release_bin" "$@"

    """#

    /// managed-install.json as from Pi's installer.
    static func markerJSON(entrypoint: URL) -> String {
        """
        {
          "kind": "pi-managed-install",
          "schemaVersion": 1,
          "layout": "releases-v1",
          "entrypoint": {
            "type": "symlink",
            "path": "\(entrypoint.path)"
          }
        }

        """
    }
}
