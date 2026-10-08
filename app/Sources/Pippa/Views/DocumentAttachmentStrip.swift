import SwiftUI

/// Compact prompt documents. Historical references have no removal action.
struct DocumentAttachmentStrip: View {
    var files: [URL]
    var disabled: Bool
    var onRemove: ((URL) -> Void)? = nil

    var body: some View {
        AttachmentFlowLayout {
            ForEach(Array(files.prefix(3).enumerated()), id: \.offset) { _, file in
                chip(file)
            }
            if files.count > 3 {
                Menu {
                    ForEach(Array(files.dropFirst(3).enumerated()), id: \.offset) { _, file in
                        if let onRemove {
                            Button(T("Take %@ off Pippa", table: "Line", file.lastPathComponent)) { onRemove(file) }
                                .disabled(disabled)
                        } else {
                            Text(verbatim: file.lastPathComponent)
                        }
                    }
                } label: {
                    Text(verbatim: "+\(files.count - 3)")
                        .font(Fonts.hint)
                        .frame(minWidth: 24, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(T("More", table: "Line"))
                .accessibilityLabel(T("More", table: "Line"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func chip(_ file: URL) -> some View {
        HStack(spacing: 5) {
            Image(systemName: file.hasDirectoryPath ? "folder" : "doc.text")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(verbatim: file.lastPathComponent)
                .font(Fonts.hint)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(file.lastPathComponent)
            if let onRemove {
                Button { onRemove(file) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help(T("Take it off Pippa. The file stays where it is.", table: "Line"))
                .accessibilityLabel(T("Take %@ off Pippa", table: "Line", file.lastPathComponent))
            }
        }
        .foregroundStyle(Theme.ink2)
        .padding(.leading, 9)
        .padding(.trailing, 2)
        .frame(maxWidth: 170, minHeight: 28)
        .background(Theme.fill2, in: Capsule())
        .help(file.lastPathComponent)
        .accessibilityElement(children: .contain)
    }
}

/// Uses the proposed width during both shell measurement and rendering, without geometry state.
private struct AttachmentFlowLayout: Layout {
    private let spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 400, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = layout.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(1, width)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: min(170, width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
