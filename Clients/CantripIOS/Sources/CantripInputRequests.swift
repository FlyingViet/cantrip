import SwiftUI

struct CantripInputRequest: Decodable, Equatable, Identifiable {
    let id: UUID
    let kind: String
    let source: String
    let title: String
    let detail: String
    let choices: [String]
    let allowsFreeform: Bool
    let url: String?
    let code: String?
    let expiresAt: Double
}

struct CantripInputAnswer: Encodable {
    let decision: String
    var text: String? = nil
}

struct CantripInputBanner: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        if let session = model.sessions.first(where: { $0.id == model.selectedSessionID }),
           (session.pendingInputCount ?? 0) > 0 {
            Button {
                model.inputRequestsSession = session
            } label: {
                Label("Your input is needed (\(session.pendingInputCount ?? 0))", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.callout.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .accessibilityIdentifier("cantrip.input.banner")
        }
    }
}

struct CantripInputRequestsView: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    @State private var identity: UUID
    @State private var requests: [CantripInputRequest] = []
    @State private var error: String?
    @State private var loading = true
    @State private var submitting = false
    @Environment(\.dismiss) private var dismiss

    init(model: CantripRemoteModel, session: CantripRemoteSession) {
        self.model = model
        self.session = session
        _identity = State(initialValue: model.usageIdentity)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.title).font(.headline)
                    Text("Face ID or Touch ID confirms affirmative responses. It does not authorize protected macOS dialogs.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Mac Permissions & View Mac") { CantripMacAccessView(remote: model) }
                    if loading { ProgressView("Loading pending requests...") }
                    if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("cantrip.input.error") }
                    if !loading, requests.isEmpty {
                        Text("No pending input. The request may have been answered, cancelled or expired.")
                    }
                    ForEach(requests) { request in
                        CantripInputCard(request: request, busy: submitting) { answer in
                            submitting = true
                            Task {
                                let success = await model.respondToInput(sessionID: session.id, id: request.id,
                                                                         answer: answer, identity: identity)
                                submitting = false
                                if success { requests.removeAll { $0.id == request.id }; error = nil }
                                else { error = model.errorMessage ?? "Response could not be delivered. Reload before retrying." }
                                await load()
                            }
                        }
                        .id(request.id)
                    }
                }.padding()
            }
            .navigationTitle("Input Needed").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(submitting) }
                ToolbarItem(placement: .primaryAction) { Button("Reload") { Task { await load() } }.disabled(submitting) }
            }
        }
        .interactiveDismissDisabled(submitting)
        .onChange(of: model.usageIdentity) { _, _ in dismiss() }
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                if !submitting { await load() }
            }
        }
    }

    private func load() async {
        do {
            let value = try await model.inputRequests(sessionID: session.id)
            guard identity == model.usageIdentity else { return }
            requests = value
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct CantripInputCard: View {
    let request: CantripInputRequest
    let busy: Bool
    let send: (CantripInputAnswer) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Text(request.source).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: request.detail).textSelection(.enabled)
            if request.kind == "secret" {
                SecureField("Password or passphrase", text: $text)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("cantrip.input.secret")
                Text("Sent only to the verified waiting program on the Mac. Not added to chat or saved by Cantrip.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if request.kind == "question" {
                if !request.choices.isEmpty {
                    Picker("Response", selection: $text) {
                        Text("Choose a response").tag("")
                        ForEach(request.choices, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if request.allowsFreeform {
                    TextField("Answer", text: $text, axis: .vertical).lineLimit(2...8)
                }
                Text("This answer is shared with the agent. Do not enter passwords here.").font(.footnote)
            }
            if let raw = request.url, let url = URL(string: raw), url.scheme == "https" {
                if let code = request.code { Text("Device code: \(code)").monospaced().textSelection(.enabled) }
                Link("Open \(url.host ?? "sign-in page")", destination: url)
                Text("Finish sign-in in your browser and return here. Account passwords stay on the provider's site.").font(.footnote)
            }
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .disabled(busy || Date().timeIntervalSince1970 >= request.expiresAt)
        .onDisappear { text = "" }
    }

    @ViewBuilder private var buttons: some View {
        Button("Cancel", role: .cancel) { answer("cancel") }.frame(minHeight: 44)
        if request.kind == "approval" {
            Button("Deny", role: .destructive) { answer("deny") }.frame(minHeight: 44)
            Button("Approve once") { answer("approve") }.buttonStyle(.borderedProminent).frame(minHeight: 44)
        } else if ["question", "secret"].contains(request.kind) {
            Button("Submit") { answer("submit") }.buttonStyle(.borderedProminent).disabled(text.isEmpty).frame(minHeight: 44)
        } else {
            Button(request.kind == "login" ? "I've signed in" : "Done on Mac") { answer("approve") }.frame(minHeight: 44)
        }
    }

    private func answer(_ decision: String) {
        let value = CantripInputAnswer(decision: decision, text: decision == "submit" ? text : nil)
        text = ""
        send(value)
    }
}
