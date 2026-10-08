import Foundation

// Installer texts for the person (table "Setup", en/de). The installer asks no technical
// questions: everyday language, no "Pi", no "Terminal", no paths. Errors are one
// simple sentence; technical detail goes only in `details` (behind "Details", not translated).
extension PiInstaller {
    static func message(_ outcome: PiStepResult.Outcome) -> String {
        switch outcome {
        case .detected, .modelsFolder, .providerWritten:
            L("Pippa is setting herself up.", table: "Setup")
        case .piInstalled:
            L("Pippa is set up.", table: "Setup")
        case .modelReady(_, nil, _):
            L("Pippa’s AI is ready.", table: "Setup")
        case .modelReady(_, .clone?, let source), .modelReady(_, .hardlink?, let source):
            L("Pippa uses the AI that’s already in %@, without taking extra space. Nothing there changes.", table: "Setup", source ?? "")
        case .modelReady(_, .copy?, let source):
            L("Pippa copied her AI from %@. The original stays where it is.", table: "Setup", source ?? "")
        case .needsDownload(let bytes):
            downloadQuestion(bytes: bytes)
        case .ready:
            L("Everything is ready.", table: "Setup")
        case .failed(let failure):
            message(failure)
        }
    }

    /// The installer's only question, with size and approximate duration: "Pippa lädt jetzt ihre KI: 6,7 GB, etwa
    /// 10 Minuten. Danach läuft sie ohne Internet." Answers: "Laden" · "Später".
    public static func downloadQuestion(bytes: Int64) -> String {
        L("May I load my AI now? %1$@, %2$@. After that I run without the internet.", table: "Setup",
          ModelDownloadSize.gigabytes(bytes), ModelDownloadSize.durationText(bytes))
    }

    /// One sentence for the person.
    public static func message(_ failure: PiInstallFailure) -> String {
        switch failure {
        case .payloadMissing:
            L("Part of Pippa is missing. Please download Pippa again.", table: "Setup")
        case .versionMismatch, .missingStep:
            L("Pippa couldn’t finish setting herself up.", table: "Setup")
        case .releaseBroken:
            L("An earlier installation on this Mac is in the way. Pippa leaves it untouched; the details say what helps.", table: "Setup")
        case .notWritable:
            L("Pippa couldn’t save her files on this Mac.", table: "Setup")
        case .modelsJSONUnreadable:
            L("A settings file Pippa shares with other tools can’t be read. Pippa changed nothing; the details say which one.", table: "Setup")
        case .checksumMismatch:
            L("A file of Pippa’s AI isn’t the one she expects. Pippa leaves it untouched.", table: "Setup")
        case .notEnoughSpace(let bytes):
            L("There isn’t enough free space on this Mac. About %@ more is needed.", table: "Setup", ModelDownloadSize.gigabytes(bytes))
        case .downloadFailed:
            L("Loading stopped because the connection dropped. It picks up where it left off.", table: "Setup")
        }
    }

    /// Technical detail for "Details" (paths, versions, cause). Not translated, so it can be copied into a request.
    public static func details(_ failure: PiInstallFailure) -> String {
        switch failure {
        case .payloadMissing(let path): "Pi payload missing or incomplete: \(path)"
        case .versionMismatch(let found, let expected) where found.isEmpty: "pi --version did not answer (expected \(expected))"
        case .versionMismatch(let found, let expected): "pi --version reports \(found), expected \(expected). Try again repairs Pippa’s own copy."
        case .releaseBroken(let path): "\(path) does not start and was not created by Pippa. Run “pi update” in Terminal or remove the folder, then try again."
        case .notWritable(let path, let reason): "Cannot write \(path): \(reason)"
        case .modelsJSONUnreadable(let path): "\(path) is not plain JSON (comments?). Tidy it up or remove it, then try again."
        case .checksumMismatch(let path): "SHA-256 mismatch: \(path)"
        case .notEnoughSpace(let bytes): "Not enough free space: \(bytes) more bytes needed"
        case .missingStep(let step): "Step “\(step.rawValue)” is not finished"
        case .downloadFailed(let reason): "Download interrupted: \(reason)"
        }
    }

    /// Does "Try again" help? Not if a part of the app is missing.
    public static func canRetry(_ failure: PiInstallFailure) -> Bool {
        if case .payloadMissing = failure { return false }
        return true
    }
}
