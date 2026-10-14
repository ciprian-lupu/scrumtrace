#if os(macOS)
import SwiftUI

/// The processing panel inside the main window: above every section, under the live banner. It is a view, never a
/// window, so it cannot open or front anything. Compact on purpose: a header line, a strip of the seven stages and
/// one detail line, so Settings plus the banner plus this still fit the window's minimum size.
struct ProcessingPanelView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        if let status = controller.processing, controller.processingPanelShouldShow {
            let state = ProcessingPanelState.make(status, modelStillLoading: controller.transcriber.isPreparing)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    header(state)
                    ProcessingStageFlow(spacing: 14, rowSpacing: 4) {
                        ForEach(state.rows) { row in
                            ProcessingStageChip(row: row)
                        }
                    }
                    if let detail = Self.detailLine(state) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(detail)
                            .accessibilityIdentifier("main.processing.detail")
                    }
                    if let fraction = state.rows.first(where: { $0.state == .active })?.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .accessibilityIdentifier("main.processing.progress")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("main.processingPanel")
        }
    }

    /// The line under the strip: the active row's expectation or progress, the failed row's reason, or the footer.
    static func detailLine(_ state: ProcessingPanelState) -> String? {
        if state.isRunning {
            return state.rows.first { $0.state == .active }?.detail
        }
        return state.footer ?? state.rows.first { $0.state == .failed }?.detail
    }

    private func header(_ state: ProcessingPanelState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state.isRunning ? "gearshape.2" : (state.showsRetry ? "exclamationmark.triangle.fill" : "checkmark.circle"))
                .foregroundStyle(state.showsRetry ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("main.processing.title")
                if let subtitle = state.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(state.totalElapsed)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Time spent on this recording so far")
                .accessibilityLabel("Elapsed \(state.totalElapsed)")
            if state.showsFinishLater {
                Button(ProcessingPanelState.finishLaterTitle) { finishLater() }
                    .help(ProcessingPanelState.finishLaterHelp)
                    .accessibilityIdentifier("main.processing.finishLater")
            }
            if state.showsRetry {
                Button(ProcessingPanelState.retryTitle) { retry() }
                    .help("Run the analysis of this recording again.")
                    .accessibilityIdentifier("main.processing.retry")
            }
            if state.showsClose {
                Button(ProcessingPanelState.closeTitle) { close() }
                    .accessibilityIdentifier("main.processing.close")
            }
        }
    }

    func finishLater() {
        controller.finishLater()
    }

    func retry() {
        controller.retryFromProcessingPanel()
    }

    func close() {
        controller.dismissProcessing()
    }
}

/// One stage in the strip: a mark, the title and the elapsed time. The active mark pulses.
struct ProcessingStageChip: View {
    let row: ProcessingPanelRow
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            mark
                .frame(width: 11, height: 11)
            Text(row.title)
                .font(.caption)
                .fontWeight(row.state == .active ? .semibold : .regular)
            if let elapsed = row.elapsed {
                Text(elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(row.state == .pending ? Color.secondary : Color.primary)
        .opacity(row.state == .pending ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("main.processing.stage.\(row.stage.rawValue)")
        .accessibilityValue(Self.spoken(row.state))
    }

    @ViewBuilder
    private var mark: some View {
        switch row.state {
        case .pending:
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
        case .active:
            Circle()
                .fill(Color.accentColor)
                .opacity(pulse ? 0.35 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    static func spoken(_ state: ProcessingPanelRow.State) -> String {
        switch state {
        case .pending: return "pending"
        case .active: return "in progress"
        case .done: return "done"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
}

/// Lays the stage chips out left to right and wraps to the next line when the window is narrow, so the strip never
/// pushes the section below it off the window at the minimum width.
struct ProcessingStageFlow: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * rowSpacing
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, next > width {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width = current.indices.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
#endif
