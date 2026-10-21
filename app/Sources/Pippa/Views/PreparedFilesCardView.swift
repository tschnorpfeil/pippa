import PippaCore
import SwiftUI

enum PreparedFileAction { case open, save, finder }

enum PreparedFileAccess: Equatable {
    case checking, available(UUID, DurableFileIdentity), retired, unavailable, changed, unverified, busy
    var canUse: Bool { if case .available = self { return true }; return false }
    var message: String? {
        switch self {
        case .checking: T("Checking the saved file…", table: "FilePreparationUI")
        case .available: nil
        case .retired: T("This result was saved or removed from Pippa. If you saved a copy, use that file.", table: "FilePreparationUI")
        case .unavailable: T("This prepared file is no longer available. Your originals are unchanged.", table: "FilePreparationUI")
        case .changed: T("This prepared file has changed. I can’t verify it as the original result. Your source files are unchanged.", table: "FilePreparationUI")
        case .unverified: T("I couldn’t verify this saved result. Please try again.", table: "FilePreparationUI")
        case .busy: T("Let the current file task finish, then try again.", table: "FilePreparationUI")
        }
    }
}

/// Historical native result facts stay in the conversation. Actions always revalidate the retained
/// artifact and never promote a model-supplied path into an Open or Save operation.
struct PreparedFilesCardView: View {
    var card: PreparedFilesCard
    @ObservedObject var tray: TrayController
    private let accessState = State<[URL: PreparedFileAccess]>(initialValue: [:])
    private let messageState = State<String?>(initialValue: nil)
    private let busyState = State(initialValue: false)

    init(card: PreparedFilesCard, tray: TrayController = AppModel.shared.tray) {
        self.card = card; self.tray = tray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(T("Your PDF is ready", table: "FilePreparationUI"), systemImage: "doc.richtext")
                .font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(card.pageCount == 1
                 ? T("%lld page · %@", table: "FilePreparationUI", card.pageCount, Self.size(card.totalBytes))
                 : T("%lld pages · %@", table: "FilePreparationUI", card.pageCount, Self.size(card.totalBytes)))
                .font(.scaled(size: 12)).foregroundStyle(Theme.ink2)
            if let limit = card.sizeLimitBytes {
                Text(card.withinLimit == true
                     ? T("Within the %@ size target", table: "FilePreparationUI", Self.size(limit))
                     : card.withinLimit == false
                        ? T("Above the %@ size target", table: "FilePreparationUI", Self.size(limit))
                        : T("Size target: %@", table: "FilePreparationUI", Self.size(limit)))
                    .font(.scaled(size: 12)).foregroundStyle(card.withinLimit == false ? Theme.need : Theme.ink2)
            }
            ForEach(Array(card.files.enumerated()), id: \.offset) { _, file in
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: file.lastPathComponent).font(.scaled(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink).lineLimit(2).truncationMode(.middle)
                    let access = accessState.wrappedValue[file] ?? .checking
                    HStack(spacing: 12) {
                        Button(T("Open PDF", table: "FilePreparationUI")) { act(.open, file: file) }
                        Button(T("Save a copy…", table: "FilePreparationUI")) { act(.save, file: file) }
                        Button(T("Show in Finder", table: "FilePreparationUI")) { act(.finder, file: file) }
                    }
                    .font(.scaled(size: 12)).disabled(!access.canUse || busyState.wrappedValue || tray.isWorking)
                    if let message = access.message {
                        Text(message).font(.scaled(size: 12)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !card.note.isEmpty {
                DisclosureGroup {
                    Text(verbatim: card.note).font(.scaled(size: 12)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text(T("Details", table: "FilePreparationUI")).font(.scaled(size: 12)).foregroundStyle(Theme.ink2)
                }
                .accessibilityIdentifier("prepared-files-details")
            }
            Text(T("Your originals are unchanged. Nothing has been sent.", table: "FilePreparationUI"))
                .font(.scaled(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            if let message = messageState.wrappedValue {
                Text(message).font(.scaled(size: 12)).foregroundStyle(Theme.need)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if accessState.wrappedValue.values.contains(where: { !$0.canUse && $0 != .checking }) {
                Button(T("Check again", table: "FilePreparationUI")) { Task { await refresh() } }
                    .font(.scaled(size: 12)).disabled(busyState.wrappedValue || tray.isWorking)
            }
        }
        .padding(14).resultCard()
        .buttonStyle(.borderless).tint(Theme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("prepared-files-card")
        .task(id: card) { await refresh() }
        .onChange(of: tray.items) { _, _ in Task { await refresh() } }
        .onChange(of: tray.isWorking) { _, working in if !working { Task { await refresh() } } }
    }

    private func refresh() async {
        var values: [URL: PreparedFileAccess] = [:]
        for file in card.files {
            guard !Task.isCancelled else { return }
            values[file] = await tray.preparedFileAccess(card, file: file)
        }
        guard !Task.isCancelled else { return }
        accessState.wrappedValue = values
    }

    private func act(_ action: PreparedFileAction, file: URL) {
        busyState.wrappedValue = true; messageState.wrappedValue = nil
        tray.actOnPreparedFile(action, card: card, file: file) { message in
            busyState.wrappedValue = false; messageState.wrappedValue = message
            Task { await refresh() }
        }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
