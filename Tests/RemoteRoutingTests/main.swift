import Foundation
import JavaScriptCore
import Network

private var failures = 0
private func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private final class Clock {
    var value = Date()
}

private actor ProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var started: Bool { continuation != nil }
    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor Stub {
    var calls: [(RemoteRoute, String)] = []
    var failLAN = false
    var failFallback = false
    var status = 200
    func setLANFailure(_ value: Bool) { failLAN = value }
    func setFallbackFailure(_ value: Bool) { failFallback = value }
    func setStatus(_ value: Int) { status = value }
    func clear() { calls = [] }
    func send(_ route: RemoteRoute, _ request: HTTPRequest) throws -> RemoteHTTPResponse {
        calls.append((route, request.method))
        if route.isLAN && failLAN { throw RemoteRouteError.transport("Offline") }
        if !route.isLAN && failFallback { throw RemoteRouteError.transport("Offline") }
        return RemoteHTTPResponse(
            status: status, contentType: "application/json", body: Data(#"{"sessions":[]}"#.utf8)
        )
    }
}

private final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cantrip-routing-test-server")
    private var connections: [NWConnection] = []
    private let respond: Bool

    init(tls: Bool, respond: Bool = true) throws {
        listener = try NWListener(using: tls ? RemoteLANProtocol.parameters(token: "test-token") : .tcp)
        self.respond = respond
    }

    func start() async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: .hostPort(host: "127.0.0.1", port: self.listener.port!))
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.stateUpdateHandler = { state in
                    if case .ready = state, self.respond { self.receive(connection, buffer: Data()) }
                }
                connection.start(queue: self.queue)
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let request = HTTPRequest.parse(buffer) {
                let authorized = request.headers["authorization"] == "Bearer test-token"
                let response = RemoteHTTPResponse(
                    status: authorized ? 200 : 401, contentType: "application/json",
                    body: Data((authorized ? #"{"sessions":[]}"# : #"{"error":"Unauthorized"}"#).utf8)
                )
                connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
            } else if !complete && error == nil {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }
}

private func runTests() async throws {
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 8765)
    let lan = RemoteRoute.lan(endpoint)
    let url = URL(string: "http://127.0.0.1:9876")!
    let fallback = RemoteRoute.fallback(url)
    let read = HTTPRequest(method: "GET", path: "/api/v1/sessions",
                           headers: ["authorization": "Bearer test-token"], body: Data())
    let write = HTTPRequest(method: "POST", path: "/api/v1/sessions",
                            headers: read.headers, body: Data())
    let stub = Stub()
    let clock = Clock()
    let client = RemoteRouteClient(token: "test-token", now: { clock.value }, send: { route, request in
        try await stub.send(route, request)
    })
    await client.update(endpoints: [endpoint], fallback: url)
    _ = try await client.request(read)
    expect(await stub.calls.map(\.0) == [fallback], "Tailscale is preferred even when LAN is healthy")
    expect(await client.probeTask == nil, "healthy Tailscale never probes LAN")
    await stub.clear()
    await client.update(endpoints: [], fallback: url)
    await client.update(endpoints: [endpoint], fallback: url)
    _ = try await client.request(read)
    expect(await stub.calls.map(\.0) == [fallback], "Bonjour churn cannot displace healthy Tailscale")
    clock.value = clock.value.addingTimeInterval(31)
    _ = try await client.request(read)
    expect(await stub.calls.map(\.0) == [fallback, fallback], "cooldown expiry never promotes LAN")
    expect(await client.probeTask == nil, "no LAN recovery probe after cooldown expiry")
    await stub.clear()
    _ = try await client.request(write)
    expect(await stub.calls.map(\.0) == [fallback], "Tailscale handles mutations")
    await client.update(endpoints: [], fallback: url)
    await stub.clear()
    _ = try await client.request(read)
    expect(await stub.calls.map(\.0) == [fallback], "Tailscale only bypasses LAN")
    await client.update(endpoints: [endpoint], fallback: nil)
    await stub.clear()
    _ = try await client.request(read)
    expect(await stub.calls.map(\.0) == [lan], "LAN-only connections still work without a URL")
    expect(await client.probeTask == nil, "LAN-only connections have no Tailscale probes")
    await client.stop()

    let recoveryStub = Stub()
    await recoveryStub.setFallbackFailure(true)
    let recoveryClient = RemoteRouteClient(token: "test-token", now: { clock.value }, send: { route, request in
        try await recoveryStub.send(route, request)
    })
    await recoveryClient.update(endpoints: [endpoint], fallback: url)
    _ = try await recoveryClient.request(read)
    expect(await recoveryStub.calls.map(\.0) == [fallback, lan], "failed Tailscale falls back to LAN")
    expect(await recoveryClient.probeTask == nil, "failed Tailscale backs off before probing")
    await recoveryStub.clear()
    await recoveryClient.update(endpoints: [], fallback: url)
    await recoveryClient.update(endpoints: [endpoint], fallback: url)
    _ = try await recoveryClient.request(read)
    expect(await recoveryStub.calls.map(\.0) == [lan], "Bonjour churn cannot reset Tailscale cooldown")
    clock.value = clock.value.addingTimeInterval(16)
    _ = try await recoveryClient.request(read)
    let failedProbe = await recoveryClient.probeTask
    await failedProbe?.value
    expect(await recoveryClient.preferred == lan, "failed Tailscale probe leaves LAN healthy")
    expect(await recoveryStub.calls.map(\.0) == [lan, lan, fallback], "recovery is a separate Tailscale read")
    await recoveryStub.clear()
    _ = try await recoveryClient.request(read)
    expect(await recoveryStub.calls.map(\.0) == [lan], "failed probe backs off without disrupting LAN")
    clock.value = clock.value.addingTimeInterval(16)
    await recoveryStub.setFallbackFailure(false)
    _ = try await recoveryClient.request(read)
    let probe = await recoveryClient.probeTask
    await probe?.value
    expect(await recoveryClient.preferred == lan, "one probe cannot promote intermittent Tailscale")
    _ = try await recoveryClient.request(read)
    expect(await recoveryClient.probeTask == nil, "recovery confirmations must be spaced apart")
    clock.value = clock.value.addingTimeInterval(4)
    _ = try await recoveryClient.request(read)
    let confirmation = await recoveryClient.probeTask
    await confirmation?.value
    expect(await recoveryClient.preferred == fallback, "two authenticated probes restore Tailscale")
    expect(await recoveryStub.calls.map(\.1).allSatisfy { $0 == "GET" } == true, "recovery only performs reads")
    await recoveryStub.clear()
    _ = try await recoveryClient.request(write)
    expect(await recoveryStub.calls.map(\.0) == [fallback], "recovered Tailscale handles the next mutation")
    await recoveryClient.stop()

    for outcome in ["recover", "remove", "stop"] {
        let gate = ProbeGate()
        let probeStub = Stub()
        let probeClient = RemoteRouteClient(token: "test-token", now: { clock.value }, send: { route, request in
            if !route.isLAN, await probeStub.calls.filter({ !$0.0.isLAN }).isEmpty { await gate.wait() }
            return try await probeStub.send(route, request)
        })
        await probeClient.update(endpoints: [endpoint], fallback: nil)
        _ = try await probeClient.request(read)
        await probeClient.update(endpoints: [endpoint], fallback: url)
        _ = try await probeClient.request(read)
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(await gate.started, "Tailscale recovery starts independently")
        let pendingProbe = await probeClient.probeTask
        _ = try await probeClient.request(write)
        expect(await probeStub.calls.map(\.0) == [lan, lan, lan],
               "reads and mutations continue on LAN while Tailscale probe waits")
        if outcome == "remove" { await probeClient.update(endpoints: [endpoint], fallback: nil) }
        if outcome == "stop" { await probeClient.stop() }
        await gate.resume()
        await pendingProbe?.value
        expect(await probeClient.preferred == lan, "first probe leaves LAN preferred")
        if outcome == "recover" {
            clock.value = clock.value.addingTimeInterval(4)
            _ = try await probeClient.request(read)
            let confirmation = await probeClient.probeTask
            await confirmation?.value
        }
        expect(await probeClient.preferred == (outcome == "recover" ? fallback : lan),
               "only a current, successful probe can promote Tailscale (\(outcome))")
        await probeClient.stop()
    }

    let failedLANStub = Stub()
    await failedLANStub.setLANFailure(true)
    let failedLANClient = RemoteRouteClient(token: "test-token", send: { route, request in
        try await failedLANStub.send(route, request)
    })
    await failedLANClient.update(endpoints: [endpoint], fallback: nil)
    do {
        _ = try await failedLANClient.request(read)
        expect(false, "failed LAN must surface without a Tailscale URL")
    } catch is RemoteRouteError {}
    await failedLANClient.update(endpoints: [endpoint], fallback: url)
    _ = try await failedLANClient.request(read)
    expect(await failedLANStub.calls.map(\.0) == [lan, fallback], "saved Tailscale bypasses failed LAN")
    await failedLANClient.stop()

    let mutationStub = Stub()
    await mutationStub.setFallbackFailure(true)
    let mutationClient = RemoteRouteClient(token: "test-token", send: { route, request in
        try await mutationStub.send(route, request)
    })
    await mutationClient.update(endpoints: [endpoint], fallback: url)
    do {
        _ = try await mutationClient.request(write)
        expect(false, "failed mutation must surface")
    } catch is RemoteRouteError {}
    expect(await mutationStub.calls.count == 1, "uncertain POST is never replayed")
    _ = try await mutationClient.request(read)
    expect(await mutationStub.calls.map(\.0) == [fallback, lan], "later read uses LAN after failed Tailscale send")
    await mutationClient.stop()

    for mode in ["lan", "fallback", "both"] {
        let retryStub = Stub()
        await retryStub.setLANFailure(true)
        await retryStub.setFallbackFailure(true)
        let retryClient = RemoteRouteClient(token: "test-token", send: { route, request in
            try await retryStub.send(route, request)
        })
        await retryClient.update(endpoints: mode == "fallback" ? [] : [endpoint], fallback: mode == "lan" ? nil : url)
        do {
            _ = try await retryClient.request(read)
            expect(false, "offline routes must fail")
        } catch is RemoteRouteError {}
        await retryStub.clear()
        do {
            _ = try await retryClient.request(write)
            expect(false, "mutations must wait for a healthy route")
        } catch is RemoteRouteError {}
        expect(await retryStub.calls.isEmpty, "no writes on routes still in cooldown")
        await retryStub.setLANFailure(false)
        await retryStub.setFallbackFailure(false)
        _ = try await retryClient.request(read)
        expect(await retryStub.calls.count == 1, "all-down recovery retries one route without waiting 30 seconds")
        await retryClient.stop()
    }

    let intermittentStub = Stub()
    let intermittent = RemoteRouteClient(token: "test-token", now: { clock.value }, send: { route, request in
        try await intermittentStub.send(route, request)
    })
    await intermittent.update(endpoints: [endpoint], fallback: nil)
    _ = try await intermittent.request(read)
    await intermittent.update(endpoints: [endpoint], fallback: url)
    for (index, succeeds) in [true, false, true, true].enumerated() {
        await intermittentStub.setFallbackFailure(!succeeds)
        _ = try await intermittent.request(read)
        let probe = await intermittent.probeTask
        expect(probe != nil, "intermittent recovery starts a probe")
        await probe?.value
        expect(await intermittent.preferred == (index == 3 ? fallback : lan),
               "Tailscale recovery requires consecutive successful probes")
        clock.value = clock.value.addingTimeInterval(16)
    }
    await intermittent.stop()

    let lateGate = ProbeGate()
    let lateStub = Stub()
    let lateClient = RemoteRouteClient(token: "test-token", send: { route, request in
        if request.path == "/old" {
            guard !route.isLAN else { throw RemoteRouteError.transport("Unexpected LAN fallback") }
            await lateGate.wait()
            throw RemoteRouteError.transport("Late failure")
        }
        return try await lateStub.send(route, request)
    })
    await lateClient.update(endpoints: [endpoint], fallback: url)
    let lateRequest = Task {
        try await lateClient.request(HTTPRequest(method: "GET", path: "/old", headers: read.headers, body: Data()))
    }
    for _ in 0..<100 {
        if await lateGate.started { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    expect(await lateGate.started, "old request started")
    _ = try await lateClient.request(read)
    await lateGate.resume()
    do {
        _ = try await lateRequest.value
        expect(false, "old failure must surface")
    } catch is CancellationError {}
    expect(await lateClient.preferred == fallback, "late failure cannot demote a newer successful route")
    expect(await lateStub.calls.map(\.0) == [fallback], "stale failure must not switch to healthy LAN")
    _ = try await lateClient.request(write)
    await lateClient.stop()

    for status in [401, 409] {
        let errorStub = Stub()
        await errorStub.setStatus(status)
        let errorClient = RemoteRouteClient(token: "test-token", send: { route, request in
            try await errorStub.send(route, request)
        })
        await errorClient.update(endpoints: [endpoint], fallback: url)
        let response = try await errorClient.request(read)
        expect(response.status == status, "host error passes through unchanged")
        expect(await errorStub.calls.count == 1, "authentication/application errors do not fail over")
        await errorClient.stop()
    }

    let blackhole = try TestServer(tls: false, respond: false)
    let blackholeEndpoint = try await blackhole.start()
    defer { blackhole.stop() }
    let server = try TestServer(tls: false)
    let serverEndpoint = try await server.start()
    defer { server.stop() }
    guard case .hostPort(_, let port) = serverEndpoint else { fatalError("Expected host/port") }
    let liveFallback = URL(string: "http://127.0.0.1:\(port.rawValue)")!
    let live = RemoteRouteClient(token: "test-token")
    await live.update(endpoints: [blackholeEndpoint], fallback: liveFallback)
    let start = Date()
    let response = try await live.request(read)
    expect(response.status == 200, "Tailscale HTTP is used ahead of stalled LAN")
    expect(Date().timeIntervalSince(start) < 1, "initial read never waits for stalled LAN")
    await live.update(endpoints: [blackholeEndpoint], fallback: nil)
    let lanStart = Date()
    do {
        _ = try await live.request(read)
        expect(false, "stalled LAN-only read must fail")
    } catch is RemoteRouteError {}
    expect(Date().timeIntervalSince(lanStart) < 3.5, "LAN read deadline stays below stale threshold")
    await live.update(endpoints: [blackholeEndpoint], fallback: liveFallback)
    let next = Date()
    _ = try await live.request(read)
    expect(Date().timeIntervalSince(next) < 1, "next read bypasses stalled LAN")
    await live.stop()

    let tls = try TestServer(tls: true)
    let tlsEndpoint = try await tls.start()
    defer { tls.stop() }
    guard case .hostPort(_, let blackholePort) = blackholeEndpoint else { fatalError("Expected host/port") }
    let slowHTTPS = RemoteRouteClient(token: "test-token")
    await slowHTTPS.update(
        endpoints: [tlsEndpoint],
        fallback: URL(string: "https://127.0.0.1:\(blackholePort.rawValue)")!
    )
    let httpsStart = Date()
    expect(try await slowHTTPS.request(read).status == 200, "stalled HTTPS falls back to authenticated LAN")
    let httpsElapsed = Date().timeIntervalSince(httpsStart)
    expect(httpsElapsed >= 2.5, "exercise the HTTPS deadline, not an immediate setup failure")
    expect(httpsElapsed < 4.5, "HTTPS fallback is bounded, not a 12-second stall")
    expect(await slowHTTPS.preferred == .lan(tlsEndpoint), "LAN remains healthy after HTTPS timeout")
    await slowHTTPS.stop()
    let secure = RemoteRouteClient(token: "test-token")
    await secure.update(endpoints: [tlsEndpoint], fallback: nil)
    expect(try await secure.request(read).status == 200, "real authenticated TLS-PSK request succeeds")
    await secure.stop()

    let bridge = RemoteLANBridge(token: "test-token")
    await bridge.update(endpoints: [tlsEndpoint], fallback: nil)
    let bridgeURL: URL = try await withCheckedThrowingContinuation { continuation in
        bridge.onReady = { continuation.resume(returning: $0) }
        bridge.onFailure = { continuation.resume(throwing: RemoteRouteError.transport($0)) }
        bridge.start()
    }
    bridge.onReady = nil
    bridge.onFailure = nil
    defer { bridge.stop() }
    var localRequest = URLRequest(url: bridgeURL.appendingPathComponent("api/v1/sessions"))
    localRequest.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
    let (_, localResponse) = try await URLSession.shared.data(for: localRequest)
    expect((localResponse as? HTTPURLResponse)?.statusCode == 200, "web bridge forwards authenticated LAN request")
    await bridge.update(endpoints: [blackholeEndpoint], fallback: liveFallback)
    let (_, switchedResponse) = try await URLSession.shared.data(for: localRequest)
    expect((switchedResponse as? HTTPURLResponse)?.statusCode == 200,
           "same web origin survives failed LAN and switches to fallback without reload")
    localRequest.setValue(nil, forHTTPHeaderField: "Authorization")
    let (_, unpairedResponse) = try await URLSession.shared.data(for: localRequest)
    expect((unpairedResponse as? HTTPURLResponse)?.statusCode == 401,
           "bridge never injects its pairing token into unauthenticated local requests")

    let raw = RemoteHTTPResponse(status: 200, contentType: "application/json", body: Data("{}".utf8)).data
    expect(String(decoding: raw, as: UTF8.self).contains("Content-Security-Policy:"),
           "bridge preserves the web client's content security policy")
    expect(try RemoteHTTPResponse.parse(raw.dropLast()) == nil, "partial HTTP response waits for body")
    expect(try RemoteHTTPResponse.parse(raw)?.body == Data("{}".utf8), "complete HTTP response round-trips")
    do {
        _ = try RemoteHTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n".utf8))
        expect(false, "invalid response length rejected")
    } catch is RemoteRouteError {}

    try await MainActor.run {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        let start = source.range(of: "    let refreshTask=null,refreshRequested=false;")!
        let end = source.range(of: "    function renderSessions", range: start.upperBound..<source.endIndex)!
        let refresh = String(source[start.lowerBound..<end.lowerBound])
        let context = JSContext()!
        context.exceptionHandler = { _, error in expect(false, "web refresh JavaScript: \(error?.toString() ?? "unknown")") }
        context.evaluateScript("""
        let token="test",selected="a",pending=[],rendered=[],connections=[];
        function api(path){return new Promise((resolve,reject)=>pending.push({path,resolve,reject}))}
        function renderSessions(items){}
        function render(session){rendered.push(session.id)}
        function connection(active){connections.push(active)}
        function pair(show){}
        \(refresh)
        refresh();refresh();refresh();
        """)
        expect(context.evaluateScript("pending.length")!.toInt32() == 1, "web refreshes coalesce while stalled")
        context.evaluateScript(#"pending.shift().resolve({sessions:[{id:"a"},{id:"b"}]})"#)
        expect(context.evaluateScript("pending[0].path")!.toString() == "/api/v1/sessions/a", "web loads selected session")
        context.evaluateScript(#"selected="b";refresh();pending.shift().resolve({session:{id:"a"}})"#)
        expect(context.evaluateScript("rendered.length")!.toInt32() == 0, "old selected session cannot overwrite new selection")
        context.evaluateScript(#"pending.shift().resolve({sessions:[{id:"a"},{id:"b"}]})"#)
        context.evaluateScript(#"pending.shift().resolve({session:{id:"b"}})"#)
        expect(context.evaluateScript("rendered.join(',')")!.toString() == "b", "coalesced refresh loads current selection")
        expect(context.evaluateScript("pending.length")!.toInt32() == 0, "coalesced refresh drains without a request backlog")
        context.evaluateScript(#"refresh();pending.shift().reject(new Error("Offline"))"#)
        expect(context.evaluateScript("refreshTask === null && connections.at(-1) === false")!.toBool() == true,
               "failed refresh releases the single-flight gate and reports disconnection")

        let apiStart = source.range(of: "    async function api(")!
        let apiEnd = source.range(of: "    function pair(", range: apiStart.upperBound..<source.endIndex)!
        context.evaluateScript("""
        let deadlines=[],cleared=[],aborted=false,fetches=[];
        class AbortController {
          constructor(){this.signal={}}
          abort(){aborted=true;this.signal.onabort?.()}
        }
        function setTimeout(callback,ms){deadlines.push({callback,ms});return deadlines.length}
        function clearTimeout(id){cleared.push(id)}
        function fetch(path,options){return new Promise((resolve,reject)=>{
          fetches.push({resolve,reject});if(options.signal)options.signal.onabort=()=>reject(new Error("Timed out"));
        })}
        \(source[apiStart.lowerBound..<apiEnd.lowerBound])
        api("/api/v1/sessions").catch(()=>{});
        """)
        expect(context.evaluateScript("deadlines[0].ms")!.toInt32() == 8000, "web reads have a bounded fallback-aware deadline")
        context.evaluateScript("deadlines[0].callback()")
        expect(context.evaluateScript("aborted && cleared.length === 1")!.toBool() == true,
               "web read timeout aborts the fetch and cleans up its timer")
        context.evaluateScript(#"api("/api/v1/sessions",{method:"POST"}).catch(()=>{})"#)
        expect(context.evaluateScript("deadlines.length")!.toInt32() == 1, "web mutations retain their longer response lifetime")
        context.evaluateScript(#"fetches.at(-1).resolve({ok:true,json:async()=>({})})"#)
    }
}

Task {
    do { try await runTests() } catch {
        failures += 1
        fputs("ERROR: \(error)\n", stderr)
    }
    print(failures == 0 ? "Remote routing tests passed" : "\(failures) remote routing tests failed")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
