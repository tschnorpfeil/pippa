import Foundation
import PippaCore

func runDictationChecks() {
    // Microphone first, then speech recognition, then on-device listening; a refusal names what was refused.
    let accesses: [DictationAccess] = [.notAsked, .granted, .denied]
    for microphone in accesses {
        for speech in accesses {
            for onDevice in [true, false] {
                let expected: DictationStep = switch (microphone, speech) {
                case (.denied, _): .blocked(.microphoneDenied)
                case (.notAsked, _): .askMicrophone
                case (.granted, .denied): .blocked(.speechDenied)
                case (.granted, .notAsked): .askSpeech
                case (.granted, .granted): onDevice ? .start : .blocked(.notOnDevice)
                }
                check("dictation: microphone \(microphone), speech \(speech), on device \(onDevice)") {
                    DictationGate.next(microphone: microphone, speech: speech, onDevice: onDevice) == expected
                }
            }
        }
    }
    check("dictation: the denied microphone wins over a denied speech recognition") {
        DictationGate.next(microphone: .denied, speech: .denied, onDevice: false) == .blocked(.microphoneDenied)
    }
    check("dictation: never listens without on-device recognition") {
        DictationGate.next(microphone: .granted, speech: .granted, onDevice: false) == .blocked(.notOnDevice)
    }

    check("dictation: German app language listens for German, everything else for English") {
        DictationGate.localeIdentifier(appLanguage: "de") == "de-DE"
            && DictationGate.localeIdentifier(appLanguage: "de-DE") == "de-DE"
            && DictationGate.localeIdentifier(appLanguage: "en") == "en-US"
            && DictationGate.localeIdentifier(appLanguage: "fr") == "en-US"
    }

    check("dictation: nothing heard leaves the typed text alone") {
        DictationGate.inserting("", into: "Hallo") == "Hallo"
            && DictationGate.inserting("  \n ", into: "Hallo") == "Hallo"
            && DictationGate.inserting(" ", into: "") == ""
    }
    check("dictation: into an empty field the heard text stands alone, trimmed") {
        DictationGate.inserting("  Wann ist die Frist?\n", into: "") == "Wann ist die Frist?"
    }
    check("dictation: one space between typed and heard text") {
        DictationGate.inserting("bitte bis Freitag", into: "Schreib Anna") == "Schreib Anna bitte bis Freitag"
    }
    check("dictation: no second space after typed whitespace or a newline") {
        DictationGate.inserting("bis Freitag", into: "Schreib Anna ") == "Schreib Anna bis Freitag"
            && DictationGate.inserting("Zweite Zeile", into: "Erste Zeile\n") == "Erste Zeile\nZweite Zeile"
    }
    check("dictation: heard text is trimmed before it is appended") {
        DictationGate.inserting("  danke  \n", into: "Hallo") == "Hallo danke"
    }

    check("dictation: System Settings is offered where it can fix the block") {
        [DictationBlock.microphoneDenied, .speechDenied, .notOnDevice].allSatisfy { $0.settingsURL?.scheme == "x-apple.systempreferences" }
    }
    check("dictation: no System Settings without a microphone or after a failure") {
        DictationBlock.noMicrophone.settingsURL == nil && DictationBlock.failed.settingsURL == nil
    }
    check("dictation: a long dictation ends after two minutes") { DictationGate.maxSeconds == 120 }
}
