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
    /// `detail` with Mac images rewritten to previews; absent from older Macs and without images.
    var displayText: String? = nil
    var images: [ChatMessageImage]? = nil

    /// A question's Markdown with its standalone previews pulled out for a thumbnail row.
    func presentation(sessionID: String) -> (text: String, images: [ChatMessageImage], previews: [ChatPreviewTile]) {
        let images = (images ?? []).map { $0.inSession(sessionID) }
        let text = images.isEmpty ? detail : (displayText ?? detail)
        let split = ChatMarkdownImages.extractingPreviews(text, images: images)
        return (split.text, images, split.previews)
    }
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
                    sessionID: session.id, remote: model,
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

    static func placeholder(
        for question: CantripInputRequest?, mode: CantripDeliveryMode, recipient: String = "Cantrip"
    ) -> String {
        guard mode == .auto, let question else { return "Message \(recipient)…" }
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
    /// Loads the question's Mac images; without them the text shows verbatim.
    var sessionID: String? = nil
    var remote: CantripRemoteModel? = nil
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
            CantripInputDetail(request: request, sessionID: sessionID, remote: remote)
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

/// A question reads like a reply, with its Mac images in one compact row so the answers stay
/// in reach. Approvals, sign-ins and passwords keep their exact text.
struct CantripInputDetail: View {
    let request: CantripInputRequest
    var sessionID: String?
    var remote: CantripRemoteModel?
    var verbatimFont: Font = .callout

    var body: some View {
        if request.kind == "question", let remote, let sessionID {
            let parts = request.presentation(sessionID: sessionID)
            VStack(alignment: .leading, spacing: 10) {
                if !parts.text.isEmpty {
                    ChatAssistantText(text: parts.text, images: parts.images, remote: remote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !parts.previews.isEmpty {
                    CantripInputImageRow(tiles: parts.previews, remote: remote)
                }
            }
        } else {
            Text(verbatim: request.detail)
                .font(verbatimFont)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Fixed-size thumbnails that scroll sideways; each opens the full-screen viewer.
struct CantripInputImageRow: View {
    let tiles: [ChatPreviewTile]
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(tiles) { tile in
                    CantripInputImageThumbnail(source: tile.image, caption: tile.caption, remote: remote)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tiles.count == 1 ? "Image" : "\(tiles.count) images")
        .accessibilityIdentifier("cantrip.input.images")
        .id(remote.usageIdentity)
    }
}

struct CantripInputImageThumbnail: View {
    static let size = CGSize(width: 96, height: 120)
    let source: ChatMessageImage
    let caption: String
    @ObservedObject var remote: CantripRemoteModel
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var retry = 0
    @State private var viewerSource = CantripViewerSource()

    /// The caption, plus the image's own description when the caption came from a label.
    private var label: String {
        guard let alt = source.altText?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty,
              alt != caption else { return caption }
        return "\(caption), \(alt)"
    }

    var body: some View {
        Button {
            if let image {
                ChatImageViewer.present(source, remote: remote, index: 0,
                                        placeholder: image, sourceFrame: viewerSource.frame)
            } else if errorMessage != nil { retry += 1 }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .cantripViewerSource(viewerSource)
                    } else if errorMessage != nil {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                            Text("Retry").font(.caption)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: Self.size.width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(errorMessage ?? (image == nil ? "Loading" : ""))
        .accessibilityHint(errorMessage == nil ? "View full image. Pinch to zoom." : "Double-tap to retry loading")
        .accessibilityIdentifier("cantrip.input.image")
        .task(id: "\(remote.usageIdentity)/\(source.sessionID ?? "")/\(source.id)/\(retry)") {
            image = nil
            errorMessage = nil
            do {
                image = try await ChatImageDecoder.load(source, remote: remote, thumbnail: true)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
                        CantripInputCard(request: request, busy: model.isMutating,
                                         sessionID: session.id, remote: model) { answer in
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

/// One pending approval, question, password or sign-in, with its answers. Chat answers
/// questions in the composer; elsewhere (Home's Background list) the card answers them itself.
struct CantripInputCard: View {
    let request: CantripInputRequest
    let busy: Bool
    /// Loads a question's Mac images; without them the text shows verbatim.
    var sessionID: String? = nil
    var remote: CantripRemoteModel? = nil
    let send: (CantripInputAnswer) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Text(request.source).font(.caption).foregroundStyle(.secondary)
            CantripInputDetail(request: request, sessionID: sessionID, remote: remote, verbatimFont: .body)
            if request.kind == "secret" {
                SecureField("Password or passphrase", text: $text)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("cantrip.input.secret")
                Text("Sent only to the verified waiting program on the Mac. Not added to chat or saved by Cantrip.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if request.kind == "question" {
                ForEach(request.choices, id: \.self) { choice in
                    Button(choice) { send(CantripInputAnswer(decision: "submit", text: choice)) }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
                if request.allowsFreeform {
                    TextField("Your answer", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .accessibilityLabel("Answer: \(request.title)")
                        .accessibilityIdentifier("cantrip.input.answer")
                }
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
        } else if request.kind == "question" {
            if request.allowsFreeform {
                Button("Send") { answer("submit") }.buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).frame(minHeight: 44)
            }
        } else {
            Button(request.kind == "login" ? "I've signed in" : "Done on Mac") { answer("approve") }.frame(minHeight: 44)
        }
    }

    private func answer(_ decision: String) {
        let reply = request.kind == "question" ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        let value = CantripInputAnswer(decision: decision, text: decision == "submit" ? reply : nil)
        text = ""
        send(value)
    }
}
