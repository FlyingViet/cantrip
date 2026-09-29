import SwiftUI

/// The small line under a sent prompt: context size, with details on click.
struct PromptUsageLine: View {
    let usage: PromptUsage
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails.toggle() } label: {
            Label(usage.summary, systemImage: "gauge.with.dots.needle.33percent")
                .labelStyle(PromptUsageLabelStyle())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show what this prompt sent to the model")
        .accessibilityLabel("Prompt context")
        .accessibilityValue(usage.accessibilitySummary)
        .accessibilityHint("Shows the token breakdown")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            PromptUsageDetails(usage: usage)
                .padding(14)
                .frame(width: 300)
        }
    }
}

private struct PromptUsageLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct PromptUsageDetails: View {
    let usage: PromptUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(usage.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(section.rows, id: \.label) { row in
                            GridRow {
                                Text(row.label)
                                Text(row.value)
                                    .monospacedDigit()
                                    .gridColumnAlignment(.trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .font(.callout)
                }
            }
            Text(PromptUsage.footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }
}
