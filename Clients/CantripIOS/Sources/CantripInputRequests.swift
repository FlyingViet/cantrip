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

struct CantripInputContext {
    let identity: UUID
    let sessionID: String
    let requests: [CantripInputRequest]
}

extension CantripRemoteModel {
    var pendingInputRequests: [CantripInputRequest] {
        if let requests = selectedSession?.pendingInputs { return requests }
        guard let inputContext, inputContext.identity == usageIdentity,
              inputContext.sessionID == selectedSessionID else { return [] }
        return inputContext.requests
    }

    var chatInputRequest: CantripInputRequest? {
        pendingInputRequests.first { $0.kind == "question" && $0.id == inputReplyID }
            ?? pendingInputRequests.first { $0.kind == "question" }
    }
}

struct CantripInputComposer: View {
    @ObservedObject var model: CantripRemoteModel
    var deliveryMode: CantripDeliveryMode = .auto
    var maxHeight: CGFloat = 300
    var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(12)
            }
            if let session = model.selectedSession, let question = model.chatInputRequest {
                CantripQuestionPanel(
                    request: question,
                    questions: model.pendingInputRequests.filter { $0.kind == "question" },
                    deliveryMode: deliveryMode, maxHeight: maxHeight,
                    busy: busy || model.isMutating,
                    select: { model.inputReplyID = $0 }
                ) { answer in
                    let identity = model.usageIdentity
                    Task {
                        if await model.respondToInput(sessionID: session.id, id: question.id,
                            answer: answer, identity: identity, questionOnly: true) {
                            await model.refreshNow()
                        }
                    }
                }
                Divider().padding(.horizontal, 12)
            }
        }
        .task(id: "\(model.usageIdentity)/\(model.selectedSession?.id ?? "")/\(model.selectedSession?.supportsInputRequests == true)") {
            error = nil
            guard let session = model.selectedSession, session.supportsInputRequests == true,
                  session.pendingInputs == nil else { return }
            let identity = model.usageIdentity
            while !Task.isCancelled {
                do {
                    let requests = try await model.inputRequests(sessionID: session.id)
                    guard identity == model.usageIdentity, session.id == model.selectedSessionID else { return }
                    model.inputContext = .init(identity: identity, sessionID: session.id, requests: requests)
                    error = nil
                } catch is CancellationError { return }
                catch { self.error = error.localizedDescription }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    static func placeholder(for question: CantripInputRequest?, mode: CantripDeliveryMode) -> String {
        guard mode == .auto, let question else { return "Message Cantrip…" }
        return question.allowsFreeform ? "Your reply…" : "Choose an answer above…"
    }

    static func acceptsText(for question: CantripInputRequest?, mode: CantripDeliveryMode) -> Bool {
        mode != .auto || question?.allowsFreeform != false
    }
}

struct CantripQuestionPanel: View {
    let request: CantripInputRequest
    var questions: [CantripInputRequest] = []
    var deliveryMode: CantripDeliveryMode = .auto
    var maxHeight: CGFloat = 300
    var busy = false
    var select: (UUID) -> Void = { _ in }
    let send: (CantripInputAnswer) -> Void
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    contentHeight = $0
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(maxHeight, contentHeight ?? maxHeight))
        .id(request.id)
        .disabled(busy || Date().timeIntervalSince1970 >= request.expiresAt)
        .accessibilityIdentifier("cantrip.input.composer")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Reply to \(request.source)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if questions.count > 1 {
                    Menu {
                        ForEach(questions) { question in
                            Button {
                                select(question.id)
                            } label: {
                                if question.id == request.id {
                                    Label(question.detail, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: question.detail)
                                }
                            }
                        }
                    } label: {
                        Text("\((questions.firstIndex { $0.id == request.id } ?? 0) + 1)/\(questions.count)")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Choose pending question")
                }
                Button {
                    send(.init(decision: "cancel"))
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel question")
            }
            Text(verbatim: request.detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(Array(request.choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    send(.init(decision: "submit", text: choice))
                } label: {
                    Text(verbatim: choice)
                }
                .buttonStyle(CantripInputChoiceStyle())
                .accessibilityIdentifier("cantrip.input.choice.\(index)")
            }
            if deliveryMode != .auto {
                Text("Switch delivery to Auto to send a typed reply to this question.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

struct CantripInputChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CantripInputTranscript: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = model.selectedSession {
                ForEach(model.pendingInputRequests.filter { $0.kind != "question" }) { request in
                    if request.kind == "secret" {
                        Button {
                            model.inputRequestsSession = session
                        } label: {
                            Label("Enter password or passphrase securely", systemImage: "lock.shield")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 8))
                    } else {
                        CantripInputCard(request: request, busy: model.isMutating) { answer in
                            let identity = model.usageIdentity
                            Task {
                                if await model.respondToInput(sessionID: session.id, id: request.id, answer: answer,
                                    identity: identity, questionOnly: request.kind == "question") {
                                    await model.refreshNow()
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("cantrip.input.inline")
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
                    Text("Use this secure form only for passwords and passphrases. Questions and approvals appear in chat.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Mac Permissions & View Mac") { CantripMacAccessView(remote: model) }
                    if loading { ProgressView("Loading pending requests...") }
                    if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("cantrip.input.error") }
                    if !loading, requests.isEmpty {
                        Text("No password is pending. Return to chat for questions and other actions.")
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
            .navigationTitle("Secure Input").navigationBarTitleDisplayMode(.inline)
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
            requests = value.filter { $0.kind == "secret" }
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
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .disabled(busy || Date().timeIntervalSince1970 >= request.expiresAt)
        .onDisappear { text = "" }
    }

    @ViewBuilder private var buttons: some View {
        Button("Cancel", role: .cancel) { answer("cancel") }.frame(minHeight: 44)
        if request.kind == "approval" {
            Button("Deny", role: .destructive) { answer("deny") }.frame(minHeight: 44)
            Button("Approve once") { answer("approve") }.buttonStyle(.borderedProminent).frame(minHeight: 44)
        } else if request.kind == "secret" {
            Button("Submit") { answer("submit") }.buttonStyle(.borderedProminent).disabled(text.isEmpty).frame(minHeight: 44)
        } else if request.kind != "question" {
            Button(request.kind == "login" ? "I've signed in" : "Done on Mac") { answer("approve") }.frame(minHeight: 44)
        }
    }

    private func answer(_ decision: String) {
        let value = CantripInputAnswer(decision: decision, text: decision == "submit" ? text : nil)
        text = ""
        send(value)
    }
}
