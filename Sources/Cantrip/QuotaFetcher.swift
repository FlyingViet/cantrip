import Foundation

enum CopilotQuotaError: String, Error, LocalizedError {
    case unavailable, runtime, authentication, response, timeout

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Install an up-to-date Copilot CLI and Node.js on the Cantrip Mac to read account usage."
        case .runtime: return "Copilot's account API could not start. Update the Copilot CLI on the Mac and retry."
        case .authentication: return "Sign in to Copilot on the Cantrip Mac to read account usage."
        case .response: return "Copilot did not return a usable account allowance. Update the CLI and retry."
        case .timeout: return "The Copilot account lookup timed out. Retry when the Mac is online."
        }
    }
}

enum QuotaFetcher {
    /// GitHub's own allowance endpoint with the `gh` sign-in: one request, well under a second.
    /// Falls back to asking the Copilot SDK (seconds, a separate runtime) when that doesn't work.
    static func fetchCopilotQuota(completion: @escaping (Result<CopilotAccountUsage, Error>) -> Void) {
        fetchCopilotQuotaDirect { result in
            if case .success = result { return completion(result) }
            fetchCopilotQuotaFromSDK(completion: completion)
        }
    }

    static let copilotUserEndpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    static func fetchCopilotQuotaDirect(completion: @escaping (Result<CopilotAccountUsage, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let gh = ToolLocator.shared.gh,
                  let run = try? ProcessRunner.run(gh, ["auth", "token"], errorOutput: .discard, timeout: 10),
                  run.status == 0, !run.timedOut,
                  let token = String(data: run.output, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                return completion(.failure(CopilotQuotaError.unavailable))
            }
            var request = URLRequest(url: copilotUserEndpoint, timeoutInterval: 15)
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let account = copilotAccount(fromUser: data) else {
                    return completion(.failure(CopilotQuotaError.response))
                }
                completion(.success(account))
            }.resume()
        }
    }

    /// The allowance buckets from GitHub's Copilot user payload, as the SDK probe projects them.
    static func copilotAccount(fromUser data: Data) -> CopilotAccountUsage? {
        guard let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = user["quota_snapshots"] as? [String: [String: Any]] else { return nil }
        func number(_ value: Any?) -> Double? {
            (value as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
        }
        func date(_ value: Any?) -> String? {
            (value as? String).flatMap { ISODate.date(from: $0) }.map(ISODate.string(from:))
        }
        let userBilling = user["token_based_billing"] as? Bool
        let userReset = date(user["quota_reset_date_utc"]) ?? date(user["quota_reset_date"])
        var buckets: [CopilotQuotaBucket] = []
        for id in ["premium_interactions", "chat", "completions"] {
            guard let s = snapshots[id] else { continue }
            let entitlement = number(s["entitlement"])
            let unlimited = s["unlimited"] as? Bool ?? (entitlement == -1)
            let remaining = number(s["quota_remaining"]) ?? number(s["remaining"])
            var percent: Double?
            if let entitlement, entitlement > 0, let remaining { percent = remaining / entitlement * 100 }
            else { percent = number(s["percent_remaining"]) }
            let billing = s["token_based_billing"] as? Bool ?? userBilling
            let epoch = number(s["quota_reset_at"]) ?? 0
            let reset = epoch > 0 && epoch < 253_402_300_800
                ? ISODate.string(from: Date(timeIntervalSince1970: epoch)) : userReset
            buckets.append(CopilotQuotaBucket(
                id: id, billingMode: billing == true ? "credits" : billing == false ? "requests" : "unknown",
                isUnlimited: unlimited,
                remainingPercent: unlimited ? nil : percent.map { max(0, min(100, $0)) },
                entitlement: (entitlement ?? -1) >= 0 ? entitlement : nil,
                remaining: (remaining ?? -1) >= 0 ? remaining : nil,
                overage: number(s["overage_count"]), overageAllowed: s["overage_permitted"] as? Bool,
                resetAt: reset, observedAt: date(s["timestamp_utc"])
            ))
        }
        guard !buckets.isEmpty else { return nil }
        return CopilotAccountUsage(login: (user["login"] as? String).map { String($0.prefix(100)) },
                                   plan: (user["copilot_plan"] as? String).map { String($0.prefix(100)) },
                                   buckets: buckets)
    }

    static func fetchCopilotQuotaFromSDK(completion: @escaping (Result<CopilotAccountUsage, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
                environment["NO_COLOR"] = "1"
                let run = try ProcessRunner.run(
                    "/usr/bin/env", ["node", "--input-type=module", "-e", script], environment: environment,
                    directory: FileManager.default.homeDirectoryForCurrentUser, errorOutput: .discard, timeout: 25
                )
                if run.timedOut { throw CopilotQuotaError.timeout }
                let data = run.output
                guard run.status == 0 else { throw CopilotQuotaError.unavailable }
                let result = try JSONDecoder().decode(ProbeResult.self, from: data)
                if let error = result.error { throw error }
                guard let account = result.account, !account.buckets.isEmpty else {
                    throw CopilotQuotaError.response
                }
                completion(.success(account))
            } catch {
                // Neither SDK errors nor authentication payloads may reach logs or Remote.
                completion(.failure((error as? CopilotQuotaError) ?? CopilotQuotaError.response))
            }
        }
    }

    private struct ProbeResult: Decodable {
        let account: CopilotAccountUsage?
        let error: CopilotQuotaError?
    }

    // Only this allowlisted projection crosses the process boundary. No chat
    // session is created, and the SDK owns a separate, short-lived runtime.
    static let script = CopilotRuntime.discoveryScript + "\n" + #"""
    const finite = value => typeof value === 'number' && Number.isFinite(value) ? value : undefined;
    const bool = value => typeof value === 'boolean' ? value : undefined;
    const text = value => typeof value === 'string' ? value.slice(0, 100) : undefined;
    const iso = value => {
      if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}(T.*(?:Z|[+-]\d{2}:\d{2}))?$/.test(value)) return undefined;
      const date = new Date(value);
      return Number.isFinite(date.getTime()) ? date.toISOString() : undefined;
    };
    function project(quota, auth) {
      const user = auth?.authInfo?.copilotUser;
      if (!user) throw new Error('authentication');
      const raw = user.quota_snapshots ?? {};
      const buckets = [];
      for (const id of ['premium_interactions', 'chat', 'completions']) {
        const normalized = quota?.quotaSnapshots?.[id];
        const source = raw[id];
        if (!source && !normalized) continue;
        const s = source ?? {};
        const n = normalized ?? {};
        const entitlement = finite(s.entitlement) ?? finite(n.entitlementRequests);
        const unlimited = bool(s.unlimited) ?? bool(n.isUnlimitedEntitlement) ?? entitlement === -1;
        const remaining = finite(s.quota_remaining) ?? finite(s.remaining);
        const percent = entitlement > 0 && remaining !== undefined
          ? remaining / entitlement * 100
          : finite(s.percent_remaining) ?? finite(n.remainingPercentage);
        const billing = bool(s.token_based_billing) ?? bool(user.token_based_billing);
        const epoch = finite(s.quota_reset_at);
        const reset = epoch > 0 && epoch < 253402300800 ? new Date(epoch * 1000).toISOString()
          : iso(user.quota_reset_date_utc) ?? iso(user.quota_reset_date);
        buckets.push({
          id, billingMode: billing === true ? 'credits' : billing === false ? 'requests' : 'unknown',
          isUnlimited: unlimited,
          remainingPercent: unlimited || percent === undefined ? undefined : Math.max(0, Math.min(100, percent)),
          entitlement: entitlement >= 0 ? entitlement : undefined,
          remaining: remaining !== undefined && remaining >= 0 ? remaining : undefined,
          overage: finite(s.overage_count) ?? finite(n.overage),
          overageAllowed: bool(s.overage_permitted) ?? bool(n.overageAllowedWithExhaustedQuota),
          resetAt: reset, observedAt: iso(s.timestamp_utc)
        });
      }
      if (!buckets.length) throw new Error('response');
      return { login: text(auth.authInfo.login), plan: text(user.copilot_plan), buckets };
    }
    async function main() {
      const paths = resolveCopilotRuntime();
      const { CopilotClient, RuntimeConnection } = await import(paths.sdk);
      client = new CopilotClient({
        connection: RuntimeConnection.forStdio({ path: paths.runtime }),
        logLevel: 'none', useLoggedInUser: true, workingDirectory: homedir()
      });
      await client.start();
      if (!client.rpc.account?.getQuota || !client.rpc.account?.getCurrentAuth) throw new Error('runtime');
      if (!(await client.rpc.account.getCurrentAuth())?.authInfo?.copilotUser) throw new Error('authentication');
      const quota = await client.rpc.account.getQuota({});
      const auth = await client.rpc.account.getCurrentAuth();
      return project(quota, auth);
    }
    let client;
    let finished = false;
    async function finish(result) {
      if (finished) return;
      finished = true;
      clearTimeout(deadline);
      if (client) await client.forceStop();
      process.stdout.write(JSON.stringify(result), () => process.exit(0));
    }
    process.on('SIGTERM', () => { void finish({ error: 'timeout' }); });
    const deadline = setTimeout(() => { void finish({ error: 'timeout' }); }, 18000);
    try { await finish({ account: await main() }); }
    catch (error) {
      const code = ['unavailable', 'authentication', 'response', 'runtime'].includes(error?.message)
        ? error.message : 'runtime';
      await finish({ error: code });
    }
    """#
}

extension CopilotQuotaError: Codable {}
