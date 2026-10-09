import PippaCore
import SwiftUI

/// "Bessere Dokumentensuche": the optional text-search model (EmbeddingGemma 2, DocumentSearch). Loaded only after the
/// person clicks; without it Pippa searches shown documents by their words. Nothing is computed outside this Mac.
@MainActor
final class DocumentSearchModel: ObservableObject {
    enum State: Equatable { case off, loading(Double), on, failed }
    @Published private(set) var state: State
    private var task: Task<Void, Never>?

    init() { state = EmbeddingServer.modelFile() == nil ? .off : .on }

    var size: String { ModelDownloadSize.gigabytes(EmbeddingServer.model.approxBytes ?? 0) }

    func load() {
        guard task == nil else { return }
        state = .loading(0)
        let downloader = ModelDownloader(directory: EmbeddingServer.modelsDirectory())
        task = Task { [weak self] in
            do {
                try await downloader.download(EmbeddingServer.model) { progress, _ in
                    Task { @MainActor in if case .loading = self?.state { self?.state = .loading(progress) } }
                }
                DiagnosticsLog.shared.event("dokumentsuche-modell-geladen")
                self?.finish(EmbeddingServer.modelFile() == nil ? .failed : .on)
            } catch is CancellationError {
                self?.finish(.off)
            } catch {
                UserMessage.record(error, context: "dokumentsuche-modell")
                self?.finish(.failed)
            }
        }
    }

    func cancel() { task?.cancel() }

    private func finish(_ new: State) { state = new; task = nil }
}

struct DocumentSearchRow: View {
    @ObservedObject var search: DocumentSearchModel

    var body: some View {
        SettingsRow(title: T("Better document search", table: "Settings"), detail: detail) {
            switch search.state {
            case .off: Button(T("Load Now", table: "Settings")) { search.load() }.pippa(.secondary)
            case .loading: Button(T("Cancel", table: "Settings")) { search.cancel() }.pippa(.quiet)
            case .failed: Button(T("Try Again", table: "Settings")) { search.load() }.pippa(.quiet)
            case .on: EmptyView()
            }
        }
    }

    private var detail: String {
        switch search.state {
        case .off:
            return T("Also finds passages that use other words, and German passages for English questions. Loads once (%@); after that everything stays on this Mac.", table: "Settings", search.size)
        case .loading(let progress):
            return T("Loading · %lld %%", table: "Settings", Int((progress * 100).rounded()))
        case .on:
            return T("On. Pippa searches the documents you show her with it, on this Mac.", table: "Settings")
        case .failed:
            return T("Loading didn’t work. Pippa still searches your documents by their words.", table: "Settings")
        }
    }
}
