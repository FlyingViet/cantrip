import SwiftUI

struct PromptText {
    static let previewLimit = 1_200
    static let pageLimit = 4_000
    let text: String
    let preview: String
    let isLong: Bool

    init(_ text: String) {
        self.text = text
        let prefix = text.prefix(Self.previewLimit + 1)
        isLong = prefix.count > Self.previewLimit
        guard isLong else {
            preview = text
            return
        }
        var cut = text.index(text.startIndex, offsetBy: Self.previewLimit)
        // Never through the middle of a tab mention's token: the preview would show its raw text.
        if let token = CantripTabMentions.parse(text).first(where: { $0.range.contains(cut) && $0.range.lowerBound != cut }) {
            cut = token.range.lowerBound
        }
        preview = String(text[..<cut])
    }

    func page(from start: String.Index) -> (text: String, end: String.Index) {
        let end = text.index(start, offsetBy: Self.pageLimit, limitedBy: text.endIndex) ?? text.endIndex
        return (String(text[start..<end]), end)
    }
}

/// Bound text layout, not the stored or transmitted prompt.
struct PromptTextView: View {
    private let prompt: PromptText
    private let mentionStyle: CantripMentionStyle
    @State private var reading = false

    init(text: String, mentionStyle: CantripMentionStyle = .standard) {
        prompt = PromptText(text)
        self.mentionStyle = mentionStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CantripMentionText(text: prompt.preview, style: mentionStyle)
                .lineLimit(prompt.isLong ? 8 : nil)
            if prompt.isLong {
                Button("Read full prompt") { reading = true }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .underline()
                    .accessibilityHint("Only the preview is shortened. The complete prompt is sent.")
            }
        }
        .sheet(isPresented: $reading) { PromptReader(prompt: prompt) }
    }
}

private struct PromptReader: View {
    let prompt: PromptText
    @Environment(\.dismiss) private var dismiss
    @State private var starts: [String.Index] = []

    var body: some View {
        let page = prompt.page(from: starts.last ?? prompt.text.startIndex)
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(verbatim: CantripTabMentions.plain(page.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .id(starts.count)
                HStack {
                    Button("Previous") { starts.removeLast() }
                        .disabled(starts.isEmpty)
                    Spacer()
                    Text("Page \(starts.count + 1)").font(.caption)
                    Spacer()
                    Button("Next") { starts.append(page.end) }
                        .disabled(page.end == prompt.text.endIndex)
                }
                .padding()
            }
            .foregroundStyle(.primary)
            .navigationTitle("Full prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy all") { UIPasteboard.general.string = CantripTabMentions.plain(prompt.text) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
