import SwiftUI

enum CantripReasoningFormat {
    /// Secondary text that keeps 4.5:1 contrast on light backgrounds (`.secondary` is about 3.5:1).
    static let secondaryText = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return .secondaryLabel }
        return traits.accessibilityContrast == .high ? .label : UIColor(white: 0.38, alpha: 1)
    })

    /// Inline markdown (code spans, bold) from reasoning; plain text while a token is incomplete.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Host steps, or the whole reasoning as one step from Mac hosts that don't split it.
    static func steps(for message: CantripRemoteMessage?, thinking: String?) -> [CantripRemoteReasoningStep] {
        let steps = (message?.reasoning ?? []).filter { !$0.title.isEmpty || !$0.text.isEmpty }
        if !steps.isEmpty { return steps }
        let text = (thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [CantripRemoteReasoningStep(title: "Reasoning", text: text)]
    }
}

/// A Cantrip reply's reasoning as titled steps. Tool calls stay on the Mac.
struct CantripReasoningSteps: View {
    let steps: [CantripRemoteReasoningStep]
    let streaming: Bool
    @State private var expanded: Bool

    init(steps: [CantripRemoteReasoningStep], streaming: Bool, initiallyExpanded: Bool = false) {
        self.steps = steps
        self.streaming = streaming
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            CantripReasoningStepList(steps: steps, streaming: streaming)
                .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if streaming {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "brain")
                            .foregroundStyle(CantripReasoningFormat.secondaryText)
                    }
                    Text("Reasoning")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(.label))
                    Spacer(minLength: 8)
                    Text(CantripSubagentFormat.stepLabel(steps.count))
                        .foregroundStyle(CantripReasoningFormat.secondaryText)
                }
                if streaming, !expanded, let latest = steps.last, !latest.title.isEmpty {
                    Text(CantripReasoningFormat.markdown(latest.title))
                        .foregroundStyle(Color(.label))
                        .lineLimit(2)
                        .accessibilityLabel("Now: \(latest.title)")
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
        .accessibilityHint(expanded ? "Hides the reasoning steps" : "Shows each reasoning step")
    }
}

/// Numbered reasoning steps; tapping a step shows the rest of its text.
struct CantripReasoningStepList: View {
    let steps: [CantripRemoteReasoningStep]
    var streaming = false

    /// Rows keep their identity by step number as older subagent steps scroll out.
    private var numbered: [(number: Int, step: CantripRemoteReasoningStep)] {
        steps.enumerated().map { ($1.number ?? $0 + 1, $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(numbered, id: \.number) { item in
                CantripReasoningStepRow(
                    step: item.step,
                    number: item.number,
                    isCurrent: streaming && item.number == numbered.last?.number
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CantripReasoningStepRow: View {
    let step: CantripRemoteReasoningStep
    let number: Int
    let isCurrent: Bool
    @State private var expanded = false

    private var title: String {
        step.title.isEmpty ? "Step \(number)" : step.title
    }

    private var hasDetails: Bool {
        !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if hasDetails {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(expanded ? "Hides this step's details" : "Shows this step's details")
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? Color(.label) : CantripReasoningFormat.secondaryText)
                .frame(minWidth: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(CantripReasoningFormat.markdown(title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                if expanded {
                    Text(CantripReasoningFormat.markdown(step.text))
                        .font(.caption)
                        .foregroundStyle(CantripReasoningFormat.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if hasDetails {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(CantripReasoningFormat.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var accessibilityLabel: String {
        var parts = ["Step \(number)", title]
        if isCurrent { parts.append("in progress") }
        if expanded, hasDetails { parts.append(step.text) }
        return parts.joined(separator: ", ")
    }
}
