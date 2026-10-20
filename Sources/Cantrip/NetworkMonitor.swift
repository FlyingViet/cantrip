import Foundation
import Network

/// Whether the Mac has a usable network path. Runs that fail while offline wait here and
/// continue once the network has been back for a moment, instead of failing their queue.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var isOnline = true
    /// How long the network must stay up before waiting work continues.
    static var settleDelay: TimeInterval = 3
    private let monitor = NWPathMonitor()
    private var waiters: [() -> Void] = []
    private var settle: DispatchWorkItem?
    private var overridden = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, !self.overridden else { return }
                self.update(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "cantrip.network-monitor", qos: .utility))
    }

    /// Runs `body` on the main actor once the network is up and has stayed up for
    /// `settleDelay` (right away when it already is).
    func whenOnline(_ body: @escaping () -> Void) {
        guard !isOnline else { return body() }
        waiters.append(body)
    }

    /// Tests drive connectivity directly; real path updates are ignored afterwards.
    func setOnlineForTesting(_ online: Bool) {
        overridden = true
        update(online)
    }

    private func update(_ online: Bool) {
        if online == isOnline, settle == nil || online { return }
        if !online {
            settle?.cancel()
            settle = nil
            if isOnline { Log.write("network: offline") }
            isOnline = false
            return
        }
        guard settle == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settle = nil
            self.isOnline = true
            Log.write("network: back online")
            let ready = self.waiters
            self.waiters.removeAll()
            for body in ready { body() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
