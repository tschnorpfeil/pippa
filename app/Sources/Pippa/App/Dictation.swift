import AVFoundation
import AppKit
import PippaCore
import Speech

/// Speaking instead of typing in the conversation composer: on-device speech recognition only, no server fallback.
/// Hidden until `dictation.enabled` is set (`defaults write io.github.tschnorpfeil.pippa dictation.enabled -bool YES`).
/// The decisions are in PippaCore (DictationGate); this class only drives the microphone and the recognizer.
@MainActor
final class Dictation: ObservableObject {
    static let enabledKey = "dictation.enabled"

    enum Phase: Equatable { case idle, starting, listening, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var problem: DictationBlock?
    /// Set once by AppModel: where finished text goes.
    var onInsert: ((String) -> Void)?
    var isActive: Bool { phase != .idle }

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Late callbacks of an earlier attempt are dropped.
    private var generation = 0
    private var limit: Task<Void, Never>?

    /// The mic button: the first click listens, the second inserts what was heard.
    func toggle() { isActive ? finish() : start() }

    func start() {
        guard phase == .idle else { return }
        problem = nil
        transcript = ""
        phase = .starting
        generation += 1
        let attempt = generation
        Task { await self.begin(attempt) }
    }

    /// Return, the second click and the time limit: insert what was heard, without sending.
    func finish() {
        switch phase {
        case .idle, .finishing:
            return
        case .starting:
            cancel()
        case .listening:
            phase = .finishing
            // The tap goes first, so no buffer reaches the request after its end.
            stopAudio()
            request?.endAudio()
            let attempt = generation
            // The final result usually arrives sooner; otherwise the last partial text is inserted.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, self.generation == attempt, self.phase == .finishing else { return }
                self.deliver()
            }
        }
    }

    /// Esc and closing the window: what was heard is discarded.
    func cancel(keepingProblem: Bool = false) {
        if !keepingProblem { problem = nil }
        reset()
    }

    private func begin(_ attempt: Int) async {
        // Without the usage texts TCC ends the process on asking (a `swift run` binary has no Info.plist).
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            block(.failed, attempt)
            return
        }
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: DictationGate.localeIdentifier(appLanguage: language)))
        // Microphone, speech recognition, then listening: three rounds are enough when both are asked once.
        for _ in 0..<3 {
            guard attempt == generation else { return }
            let onDevice = recognizer?.supportsOnDeviceRecognition == true && recognizer?.isAvailable == true
            switch DictationGate.next(microphone: Self.microphoneAccess(), speech: Self.speechAccess(), onDevice: onDevice) {
            case .askMicrophone:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .askSpeech:
                _ = await Self.requestSpeechAccess()
            case .blocked(let reason):
                block(reason, attempt)
                return
            case .start:
                guard let recognizer else { block(.failed, attempt); return }
                listen(with: recognizer, attempt)
                return
            }
        }
        block(.failed, attempt)
    }

    private func listen(with recognizer: SFSpeechRecognizer, _ attempt: Int) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let engine = AVAudioEngine()
        self.recognizer = recognizer
        self.request = request
        self.engine = engine
        task = Self.recognize(recognizer, request,
            update: { @Sendable [weak self] text, isFinal in
                Task { @MainActor in self?.received(text, isFinal: isFinal, attempt: attempt) }
            },
            ended: { @Sendable [weak self] in
                Task { @MainActor in self?.ended(attempt: attempt) }
            })
        do {
            try Self.listen(engine, into: request)
        } catch {
            block((error as? DictationFailure) == .noMicrophone ? .noMicrophone : .failed, attempt)
            return
        }
        phase = .listening
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DictationGate.maxSeconds))
            guard let self, !Task.isCancelled, self.generation == attempt else { return }
            self.finish()
        }
    }

    private func received(_ text: String, isFinal: Bool, attempt: Int) {
        guard attempt == generation else { return }
        transcript = text
        if isFinal && phase == .finishing { deliver() }
    }

    /// Errors, silence and a permission taken away while listening.
    private func ended(attempt: Int) {
        guard attempt == generation else { return }
        if phase == .finishing {
            deliver()
        } else if transcript.isEmpty {
            cancel()
        } else {
            problem = .failed
            cancel(keepingProblem: true)
        }
    }

    private func deliver() {
        let text = transcript
        reset()
        onInsert?(text)
    }

    private func block(_ reason: DictationBlock, _ attempt: Int) {
        guard attempt == generation else { return }
        reset()
        problem = reason
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    private func reset() {
        generation += 1
        stopAudio()
        task?.cancel()
        limit?.cancel()
        engine = nil
        request = nil
        task = nil
        recognizer = nil
        limit = nil
        phase = .idle
        transcript = ""
    }

    private static func microphoneAccess() -> DictationAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notAsked
        case .authorized: .granted
        default: .denied
        }
    }

    private static func speechAccess() -> DictationAccess {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: .notAsked
        case .authorized: .granted
        default: .denied
        }
    }

    // AVFoundation and Speech call these closures on their own queues. Built outside the main actor: a closure
    // written inside a `@MainActor` method is main-actor isolated, and Swift 6 traps when it runs elsewhere
    // (the same reason as DropReader.promiseReader).

    private nonisolated static func listen(_ engine: AVAudioEngine, into request: SFSpeechAudioBufferRecognitionRequest) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationFailure.noMicrophone }
        let sink = AudioSink(request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        engine.prepare()
        try engine.start()
    }

    private nonisolated static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String, Bool) -> Void,
                                              ended: @escaping @Sendable () -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result { update(result.bestTranscription.formattedString, result.isFinal) } else if error != nil { ended() }
        }
    }

    private nonisolated static func requestSpeechAccess() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

/// Hands the microphone's buffers to the request on the audio thread.
private final class AudioSink: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}

private enum DictationFailure: Error { case noMicrophone }
