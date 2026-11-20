import Foundation
import PippaCore

#if DEBUG || PIPPA_PROBES
/// `Pippa --mail-sort-probe [--account <name>]`: the read-only measurement of the sender-history rule, one JSON report on
/// stdout (see `MailSortProbe`). Runs before any app setup: no window, model or Pi. Mail is asked only after the
/// arguments parsed.
enum MailSortProbeCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let result = await MailSortProbe.execute(arguments, mail: { SystemIntegrations().mailSortProbe })
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
        return result.exitCode
    }
}
#endif
