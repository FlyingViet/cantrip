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
        preview = isLong ? String(prefix.prefix(Self.previewLimit)) : text
    }

    func page(from start: String.Index) -> (text: String, end: String.Index) {
        let end = text.index(start, offsetBy: Self.pageLimit, limitedBy: text.endIndex) ?? text.endIndex
        return (String(text[start..<end]), end)
    }
}

/// Bound text layout, not the stored or transmitted prompt.
struct PromptTextView: View {
    private let prompt: PromptText
    @State private var reading = false

    init(text: String) { prompt = PromptText(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: prompt.preview)
                .lineLimit(prompt.isLong ? 8 : nil)
            if prompt.isLong {
                Button("Read full prompt") { reading = true }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .underline()
                    .help("Only the preview is shortened. The complete prompt is sent.")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Full prompt").font(.headline)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.text, forType: .string)
                }
                Button("Done") { dismiss() }
            }
            ScrollView {
                Text(verbatim: page.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            .id(starts.count)
            HStack {
                Button("Previous") { starts.removeLast() }
                    .disabled(starts.isEmpty)
                Text("Page \(starts.count + 1)").font(.caption)
                Button("Next") { starts.append(page.end) }
                    .disabled(page.end == prompt.text.endIndex)
            }
        }
        .padding()
        .foregroundStyle(.primary)
        .frame(width: 560, height: 480)
    }
}
