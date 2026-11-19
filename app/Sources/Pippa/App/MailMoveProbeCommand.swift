import Foundation
import PippaCore

/// `Pippa --mail-move-probe [--account <name>]`: the mail-move spike on two test folders, one JSON report on stdout
/// (see `MailMoveProbe`). Runs before any app setup: no window, model or Pi. Mail is asked only after the arguments parsed.
enum MailMoveProbeCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let result = await MailMoveProbe.execute(arguments, mail: { SystemIntegrations().mailMoveProbe })
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
        return result.exitCode
    }
}
