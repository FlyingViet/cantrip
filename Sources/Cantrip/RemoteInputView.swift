import SwiftUI

struct RemoteInputView: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(session.pendingInputs) { request in
                NativeInputCard(session: session, request: request)
                    .id(request.id)
            }
        }
    }
}

private struct NativeInputCard: View {
    @ObservedObject var session: ChatSession
    let request: InputRequestSnapshot
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
                SecureField("Password or passphrase", text: $text)
                Text("Sent only to the verified waiting program. Not added to chat or saved by Cantrip.")
                    .font(.caption)
            } else if request.kind == .question {
                if !request.choices.isEmpty {
                    Picker("Response", selection: $text) {
                        Text("Choose a response").tag("")
                        ForEach(request.choices, id: \.self) { Text($0).tag($0) }
                    }
                }
                if request.allowsFreeform { TextField("Answer (shared with the agent; not for passwords)", text: $text, axis: .vertical) }
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
                } else if request.kind == .secret || request.kind == .question {
                    Button("Submit") { respond(.submit) }.disabled(text.isEmpty)
                } else {
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
