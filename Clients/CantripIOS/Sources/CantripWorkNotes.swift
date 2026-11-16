import SwiftUI

/// A reply's progress notes vs. its answer, from the Mac (`work` on a message): text written
/// before the reply's last tool call is notes. Absent from older Macs and replies without notes.
struct CantripRemoteWork: Codable, Equatable, Hashable {
    /// Leading markdown blocks (`CantripReplyBlocks`) that are notes.
    let noteBlocks: Int
    /// Runs of notes between tool calls.
    let notes: Int
    /// Tool calls the reply made.
    let steps: Int
    /// Whether any answer text follows the last tool call yet.
    let hasAnswer: Bool
}

/// A reply cut into the notes folded above it and the answer shown in full.
struct CantripWorkFold: Equatable {
    let notes: String
    let answer: String
    let noteBlocks: Int
    let work: CantripRemoteWork
    /// The reply is still running: the row shows the latest note instead of a count.
    let working: Bool

    /// Nil when there's nothing to fold, or the run ended with no answer after its notes
    /// (then the notes are all there is, so they stay in full).
    static func make(text: String, work: CantripRemoteWork?, streaming: Bool) -> CantripWorkFold? {
        guard let work, work.noteBlocks > 0, streaming || work.hasAnswer else { return nil }
        let parts = CantripReplyBlocks.split(text, before: [work.noteBlocks])
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        if !streaming, parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return CantripWorkFold(notes: parts[0], answer: parts[1], noteBlocks: work.noteBlocks,
                               work: work, working: streaming)
    }

    /// The newest note, for the row while the reply runs.
    var latestNote: String {
        let blocks = CantripReplyBlocks.starts(in: notes).count
        return (CantripReplyBlocks.split(notes, before: [max(0, blocks - 1)]).last ?? notes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "3 notes · 12 steps".
    var summary: String {
        let notes = max(1, work.notes)
        return "\(notes) \(notes == 1 ? "note" : "notes") · \(CantripSubagentFormat.stepLabel(work.steps))"
    }

    /// Finished subagents split between the notes and the answer: a card placed within the notes
    /// stays there, and the answer's cards count blocks from the answer's start.
    func place(_ placed: [(block: Int, subagents: [CantripRemoteSubagent])])
        -> (notes: [(block: Int, subagents: [CantripRemoteSubagent])],
            answer: [(block: Int, subagents: [CantripRemoteSubagent])]) {
        (placed.filter { $0.block <= noteBlocks },
         placed.filter { $0.block > noteBlocks }.map { (block: $0.block - noteBlocks, subagents: $0.subagents) })
    }
}

/// The folded notes above a reply's answer: "Working" with the latest note while it runs,
/// "3 notes · 12 steps" when done; tap to read every note.
struct CantripWorkNotes<Content: View>: View {
    let fold: CantripWorkFold
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    @Environment(\.cantripWorkNotesExpanded) private var startsExpanded

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // A rule down the notes' edge keeps them apart from the answer below.
            content()
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if fold.working {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "checklist")
                            .foregroundStyle(CantripReasoningFormat.secondaryText)
                    }
                    Text(fold.working ? "Working" : fold.summary)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(.label))
                    Spacer(minLength: 8)
                    if fold.working {
                        Text(CantripSubagentFormat.stepLabel(fold.work.steps))
                            .foregroundStyle(CantripReasoningFormat.secondaryText)
                    }
                }
                if fold.working, !expanded, !fold.latestNote.isEmpty {
                    Text(CantripReasoningFormat.markdown(fold.latestNote))
                        .foregroundStyle(Color(.label))
                        .lineLimit(2)
                        .accessibilityLabel("Now: \(fold.latestNote)")
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
        .accessibilityHint(expanded ? "Hides the progress notes" : "Shows the progress notes written while working")
        .onAppear { if startsExpanded { expanded = true } }
    }
}

extension EnvironmentValues {
    /// Opens every progress-notes row as it appears (screenshot renders).
    @Entry var cantripWorkNotesExpanded = false
}
