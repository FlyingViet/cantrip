import SwiftUI

struct RemoteInputView: View {
    @ObservedObject var session: ChatSession
    var secureOnly = false
    var openSecureInput: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(session.pendingInputs.filter { !secureOnly || $0.kind == .secret }) { request in
                NativeInputCard(session: session, request: request, secureEntry: secureOnly, openSecureInput: openSecureInput)
                    .id(request.id)
            }
        }
    }
}

private struct NativeInputCard: View {
    @ObservedObject var session: ChatSession
    let request: InputRequestSnapshot
    let secureEntry: Bool
    let openSecureInput: () -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "person.crop.circle.badge.questionmark").font(.headline)
            Text(request.source).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: request.detail).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            if request.kind == .secret {
                if secureEntry {
                    SecureField("Password or passphrase", text: $text)
                    Text("Sent only to the verified waiting program. Not added to chat or saved by Cantrip.")
                        .font(.caption)
                } else {
                    Button("Enter password securely", action: openSecureInput)
                }
            } else if request.kind == .question {
                ForEach(request.choices, id: \.self) { choice in
                    Button(choice) {
                        text = choice
                        respond(.submit)
                    }
                }
                if request.allowsFreeform {
                    Text("Reply in the chat below. You can include attachments; do not enter passwords.")
                        .font(.caption)
                    if session.chatInputRequest?.id != request.id {
                        Button("Reply to this question") { session.inputReplyID = request.id }
                    }
                }
            }
            if let raw = request.url, let url = URL(string: raw), url.scheme == "https" {
                if let code = request.code { Text("Device code: \(code)").monospaced().textSelection(.enabled) }
                Link("Open \(url.host ?? "sign-in page")", destination: url)
                Text("Finish sign-in in your browser, then return here. Never enter your account password in chat.").font(.caption)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancel", role: .cancel) { respond(.cancel) }
                Spacer()
                if request.kind == .approval {
                    Button("Deny", role: .destructive) { respond(.deny) }
                    Button("Approve once") { respond(.approve) }
                } else if request.kind == .secret, secureEntry {
                    Button("Submit") { respond(.submit) }.disabled(text.isEmpty)
                } else if request.kind != .secret && request.kind != .question {
                    Button(request.kind == .login ? "I've signed in" : "Done on Mac") { respond(.approve) }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .onDisappear { text = "" }
    }

    private func respond(_ decision: InputRequestAnswer.Decision) {
        let answer = InputRequestAnswer(decision: decision, text: decision == .submit ? text : nil)
        text = ""
        do { try session.respondToInput(id: request.id, answer: answer) }
        catch { self.error = error.localizedDescription }
    }
}
