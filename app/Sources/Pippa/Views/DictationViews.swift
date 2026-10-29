import AppKit
import PippaCore
import SwiftUI

/// The mic between the input field and Send: the first click listens, the second inserts what was heard.
struct DictationButton: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        Button { dictation.toggle() } label: {
            Image(systemName: dictation.isActive ? "mic.fill" : "mic")
                .foregroundStyle(dictation.isActive ? Theme.accent : Theme.ink2)
                .frame(width: 28, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isActive ? T("Stop Dictating and Insert", table: "Views") : T("Dictate", table: "Views"))
        .help(T("Speak instead of typing. Everything stays on this Mac.", table: "Views"))
    }
}

/// Above the input field: what is heard while listening, or one sentence when dictation cannot listen.
struct DictationStrip: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        if dictation.isActive {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dictation.transcript.isEmpty ? T("Listening…", table: "Views") : dictation.transcript)
                        .font(Fonts.lead).foregroundStyle(Theme.ink2).lineLimit(3)
                    Text(T("⏎ inserts · esc discards", table: "Views")).font(Fonts.hint).foregroundStyle(Theme.ink3)
                }
            }
        } else if let problem = dictation.problem {
            HStack(spacing: 8) {
                Text(Self.sentence(problem)).font(Fonts.hint).foregroundStyle(Theme.ink2).lineLimit(3)
                if let url = problem.settingsURL {
                    Button(T("Open System Settings", table: "App")) { NSWorkspace.shared.open(url) }.pippa(.quiet)
                }
            }
        }
    }

    static func sentence(_ block: DictationBlock) -> String {
        switch block {
        case .microphoneDenied:
            T("Pippa may not use the microphone. You can allow it in System Settings → Privacy & Security → Microphone.", table: "Views")
        case .speechDenied:
            T("Pippa may not use speech recognition. You can allow it in System Settings → Privacy & Security → Speech Recognition.", table: "Views")
        case .notOnDevice:
            T("Your Mac can’t understand this language offline yet. Turn on Dictation in System Settings → Keyboard, then try again.", table: "Views")
        case .noMicrophone:
            T("No microphone found.", table: "Views")
        case .failed:
            T("Dictation stopped. Please try again.", table: "Views")
        }
    }
}
