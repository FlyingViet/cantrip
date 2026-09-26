import Foundation

extension ChatSession {
    func receiveInput(_ request: BackendInputRequest) {
        guard isStreaming, !isLocalPrivate, request.isPending, inputRequests.count < 8 else {
            request.cancel()
            if inputRequests.count >= 8 { deliveryStatusForInput("Additional input was declined: answer the existing pending requests first.") }
            return
        }
        let id = request.snapshot.id
        inputRequests[id] = request
        request.onResolved = { [weak self] in
            Task { @MainActor in self?.removeInput(id) }
        }
        guard request.isPending else { removeInput(id); return }
        pendingInputs = inputRequests.values.filter(\.isPending).map(\.snapshot).sorted { $0.expiresAt < $1.expiresAt }
        statusText = "Waiting for your input"
        onInputNeeded?(request.snapshot)
        let delay = max(0, request.snapshot.expiresAt - Date().timeIntervalSince1970)
        inputExpiryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch is CancellationError { return }
            catch { Log.write("input: expiry timer failed"); return }
            guard let self, let pending = self.inputRequests[id] else { return }
            pending.cancel()
            self.removeInput(id)
            self.deliveryStatusForInput("Input request expired. The waiting action was cancelled.")
        }
    }

    func respondToInput(id: UUID, answer: InputRequestAnswer) throws {
        guard isStreaming, !isLocalPrivate, let request = inputRequests[id] else { throw InputRequestError.unavailable }
        try request.respond(answer)
        removeInput(id)
    }

    func removeInput(_ id: UUID) {
        guard inputRequests.removeValue(forKey: id) != nil else { return }
        inputExpiryTasks.removeValue(forKey: id)?.cancel()
        pendingInputs.removeAll { $0.id == id }
        onInputResolved?(id)
        if pendingInputs.isEmpty, isStreaming { statusText = "Continuing..." }
    }

    func cancelInputs() {
        let requests = Array(inputRequests.values)
        for request in requests { request.cancel(); removeInput(request.snapshot.id) }
    }
}
