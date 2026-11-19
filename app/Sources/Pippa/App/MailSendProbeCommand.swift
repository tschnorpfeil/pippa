import Foundation
import PippaCore

// A developer probe: compiled only into debug builds and builds with `PIPPA_PROBES` (scripts/build-app.sh), never shipped.
#if DEBUG || PIPPA_PROBES

/// `Pippa --mail-send-probe [--account <name> (--read-only | --send)]`: the developer check of `mail_send` against the
/// real Mail, one JSON report on stdout (see `MailSendProbe`). Runs before any app setup: no window, model, Pi or MCP
/// server. Mail is asked only after the arguments parsed.
enum MailSendProbeCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let result = await MailSendProbe.execute(arguments, mail: { SystemIntegrations().mailSendProbe }, host: {
            let system = SystemIntegrations()
            return PippaMCPHost(integrations: system, sheets: system, hostData: system)
        })
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
        return result.exitCode
    }
}

#endif
