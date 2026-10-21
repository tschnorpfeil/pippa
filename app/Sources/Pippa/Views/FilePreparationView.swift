import AppKit
import PippaCore
import SwiftUI

struct FilePreparationView: View {
    @ObservedObject var tray: TrayController
    var draft: FilePreparationDraft
    var measuring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(T("Ready to send", table: "FilePreparationUI")).font(Fonts.head)
                Spacer()
                if tray.preparationBusy { ProgressView().controlSize(.small) }
            }
            Text(T("One PDF, in this order. Your originals stay where they are.", table: "FilePreparationUI"))
                .font(Fonts.hint).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text(verbatim: "\(index + 1)").font(Fonts.hint).foregroundStyle(Theme.ink3).frame(width: 20)
                            if !measuring { FileThumbnail(url: item.url, width: 24) }
                            VStack(alignment: .leading, spacing: 2) {
                                Button { NSWorkspace.shared.open(item.url) } label: {
                                    Text(verbatim: item.name).font(Fonts.body).lineLimit(1).truncationMode(.middle)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(T("Open original %@", table: "FilePreparationUI", item.name))
                                Text(verbatim: item.url.deletingLastPathComponent().lastPathComponent)
                                    .font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(1)
                            }
                            .help(item.url.path)
                            Spacer(minLength: 0)
                            moveButton(item, offset: -1, disabled: index == 0)
                            moveButton(item, offset: 1, disabled: index == draft.items.count - 1)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(T("File %lld of %lld", table: "FilePreparationUI", index + 1, draft.items.count))
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: min(CGFloat(draft.items.count) * 52 + 20, 220))
            .paper()
            VStack(alignment: .leading, spacing: 7) {
                Text(T("Quality", table: "FilePreparationUI")).font(Fonts.hint).foregroundStyle(Theme.ink2)
                Picker(T("Quality", table: "FilePreparationUI"), selection: Binding(
                    get: { draft.plan.quality }, set: { tray.setPreparationQuality($0) })) {
                    Text(T("Keep quality", table: "FilePreparationUI")).tag(FilePreparationPlan.Quality.original)
                    Text(T("Balanced", table: "FilePreparationUI")).tag(FilePreparationPlan.Quality.balanced)
                    Text(T("Compact", table: "FilePreparationUI")).tag(FilePreparationPlan.Quality.compact)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.large)
                .accessibilityIdentifier("prepare-files-quality")
            }
            .disabled(tray.isWorking)
            HStack {
                Text(T("File size", table: "FilePreparationUI")).font(Fonts.body).foregroundStyle(Theme.ink2)
                Spacer(minLength: 12)
                Menu {
                    Picker(T("Size limit", table: "FilePreparationUI"), selection: Binding(
                        get: { draft.plan.sizeGoal }, set: { tray.setPreparationSizeGoal($0) })) {
                        Text(T("No limit", table: "FilePreparationUI")).tag(FilePreparationPlan.SizeGoal?.none)
                        Text(verbatim: "5 MB").tag(FilePreparationPlan.SizeGoal?.some(.fiveMB))
                        Text(verbatim: "10 MB").tag(FilePreparationPlan.SizeGoal?.some(.tenMB))
                        Text(verbatim: "20 MB").tag(FilePreparationPlan.SizeGoal?.some(.twentyMB))
                    }
                } label: {
                    Text(verbatim: sizeLabel).font(Fonts.body)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(T("Size limit", table: "FilePreparationUI"))
                .accessibilityValue(sizeLabel)
                .accessibilityIdentifier("prepare-files-size")
            }
            .padding(.vertical, 3)
            .disabled(tray.isWorking)
            Text(T("Photos are optimized for sharing. Smaller PDFs may lose image detail. I’ll show the actual size if your limit can’t be reached.", table: "FilePreparationUI"))
                .font(Fonts.hint).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            AdaptiveActions {
                Button(T("Prepare PDF", table: "FilePreparationUI")) { tray.runPreparation() }.pippa(.primary)
                    .accessibilityIdentifier("prepare-files-run")
                    .disabled(!tray.canRunPreparation)
                Button(T("Later", table: "FilePreparationUI")) { tray.closePreparation() }.pippa(.quiet)
            }
            .disabled(tray.isWorking)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-preparation-preview")
    }

    private var sizeLabel: String {
        draft.plan.sizeGoal.map { "\($0.rawValue / 1_000_000) MB" } ?? T("No limit", table: "FilePreparationUI")
    }

    private func moveButton(_ item: TrayItem, offset: Int, disabled: Bool) -> some View {
        Button { tray.movePreparationInput(item.id, by: offset) } label: {
            Image(systemName: offset < 0 ? "arrow.up" : "arrow.down").frame(width: 26, height: 28)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink2)
        .disabled(disabled || tray.isWorking)
        .accessibilityLabel(offset < 0
            ? T("Move %@ earlier", table: "FilePreparationUI", item.name)
            : T("Move %@ later", table: "FilePreparationUI", item.name))
    }
}

struct PendingFilePreparationsView: View {
    @ObservedObject var tray: TrayController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tray.preparationJobs) { job in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(T("Your files are waiting", table: "FilePreparationUI")).font(Fonts.body)
                        Text(verbatim: job.inputs.map { $0.url.lastPathComponent }.joined(separator: ", "))
                            .font(Fonts.hint).foregroundStyle(Theme.ink2).lineLimit(2)
                        Text(T("Review and continue when you’re ready.", table: "FilePreparationUI"))
                            .font(Fonts.hint).foregroundStyle(Theme.ink3)
                    }
                    Spacer(minLength: 4)
                    Button(T("Continue", table: "Line")) { tray.resumePreparation(job) }.pippa(.quiet)
                    Button { tray.dismissPreparation(job) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(T("Dismiss this request", table: "FilePreparationUI"))
                }
                .disabled(tray.isWorking)
            }
        }
    }
}
