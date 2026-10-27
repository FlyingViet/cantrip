import Foundation

struct CopilotModelInfo: Codable, Equatable, Identifiable {
    let id: String
    var contextWindow: Int?
    var maxOutputTokens: Int?
    /// nil means unknown; an empty list means effort is not supported.
    var reasoningEfforts: [String]?
    var contextTiers: [String]?
    var defaultContextPromptTokens: Int?
    var longContextPromptTokens: Int?

    var contextLabel: String? {
        contextWindow.map(Self.tokenLabel)
    }

    func promptTokens(for tier: String) -> Int? {
        switch tier {
        case "default": return defaultContextPromptTokens
        case "long_context": return longContextPromptTokens
        default: return nil
        }
    }

    static func tokenLabel(_ tokens: Int) -> String {
        let divisor = tokens >= 1_000_000 ? 1_000_000 : tokens >= 1000 ? 1000 : 1
        let suffix = divisor == 1_000_000 ? "M" : divisor == 1000 ? "k" : ""
        let value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                           Double(tokens) / Double(divisor))
            .replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
        return value + suffix
    }

    static func choices(supported: [String]?, fallback: [String], selected: String) -> [String] {
        var seen = Set<String>()
        return ((supported ?? fallback) + [selected]).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }
}

enum CopilotModelError: String, Error, LocalizedError, Codable {
    case unavailable, runtime, response, timeout

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Install Node.js and an up-to-date Copilot CLI, and check the Copilot path in Settings."
        case .runtime:
            return "Could not read Copilot's model catalog. Check the Mac's connection and Copilot CLI sign-in, then retry."
        case .response:
            return "Copilot returned no usable model catalog. Update the CLI and retry."
        case .timeout:
            return "The Copilot model lookup timed out. Retry when the Mac is online."
        }
    }
}

enum CopilotModelFetcher {
    static func fetch(command: String, completion: @escaping (Result<[CopilotModelInfo], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
                environment["NO_COLOR"] = "1"
                environment["CANTRIP_COPILOT_COMMAND"] = command
                let run: ProcessRunner.Result
                do {
                    run = try ProcessRunner.run(
                        "/usr/bin/env", ["node", "--input-type=module", "-e", script], environment: environment,
                        directory: FileManager.default.homeDirectoryForCurrentUser, errorOutput: .discard, timeout: 25
                    )
                } catch { throw CopilotModelError.unavailable }
                guard !run.timedOut else { throw CopilotModelError.timeout }
                guard run.status == 0 else { throw CopilotModelError.unavailable }
                let result = try JSONDecoder().decode(ProbeResult.self, from: run.output)
                if let error = result.error { throw error }
                guard let models = result.models, !models.isEmpty else { throw CopilotModelError.response }
                completion(.success(models))
            } catch {
                // SDK errors can contain authentication data; expose only fixed messages.
                completion(.failure((error as? CopilotModelError) ?? CopilotModelError.response))
            }
        }
    }

    private struct ProbeResult: Decodable {
        let models: [CopilotModelInfo]?
        let error: CopilotModelError?
    }

    static let script = CopilotRuntime.discoveryScript + "\n" + #"""
    const positive = value => Number.isSafeInteger(value) && value > 0 ? value : undefined;
    const strings = value => Array.isArray(value)
      ? [...new Set(value.filter(v => typeof v === 'string' && /^[a-z][a-z0-9_-]{0,39}$/.test(v)))]
      : undefined;
    function project(models) {
      if (!Array.isArray(models)) throw new Error('response');
      const seen = new Set();
      const result = [];
      for (const model of models) {
        const id = model?.id;
        if (typeof id !== 'string' || !id.length || id.length > 200 || seen.has(id)
            || (model.policy?.state && model.policy.state !== 'enabled')) continue;
        seen.add(id);
        const limits = model.capabilities?.limits ?? {};
        const prices = model.billing?.tokenPrices;
        const output = positive(limits.max_output_tokens);
        const context = positive(limits.max_context_window_tokens);
        const tiers = strings(model.supportedContextTiers);
        const hasLongContext = prices?.longContext != null;
        result.push({
          id, contextWindow: context, maxOutputTokens: output,
          reasoningEfforts: model.capabilities?.supports?.reasoningEffort === false
            ? [] : strings(model.supportedReasoningEfforts),
          contextTiers: tiers ?? (id === 'auto' ? undefined
            : hasLongContext ? ['default', 'long_context'] : ['default']),
          defaultContextPromptTokens: positive(prices?.maxPromptTokens) ?? positive(prices?.contextMax)
            ?? (hasLongContext || tiers?.includes('long_context') ? undefined : positive(limits.max_prompt_tokens)),
          longContextPromptTokens: positive(prices?.longContext?.maxPromptTokens)
            ?? positive(prices?.longContext?.contextMax)
        });
      }
      if (!result.length) throw new Error('response');
      return result;
    }
    async function main() {
      let paths;
      try { paths = resolveCopilotRuntime(process.env.CANTRIP_COPILOT_COMMAND || 'copilot'); }
      catch { throw new Error('unavailable'); }
      const { CopilotClient, RuntimeConnection } = await import(paths.sdk);
      client = new CopilotClient({
        connection: RuntimeConnection.forStdio({ path: paths.runtime }),
        logLevel: 'none', useLoggedInUser: true, workingDirectory: homedir()
      });
      await client.start();
      return project((await client.rpc.models.list({})).models);
    }
    let client;
    let finished = false;
    async function finish(result) {
      if (finished) return;
      finished = true;
      clearTimeout(deadline);
      const shutdownDeadline = setTimeout(() => process.exit(1), 2000);
      try { if (client) await client.forceStop(); }
      catch { result = { error: 'runtime' }; }
      process.stdout.write(JSON.stringify(result), () => {
        clearTimeout(shutdownDeadline);
        process.exit(0);
      });
    }
    process.on('SIGTERM', () => { void finish({ error: 'timeout' }); });
    const deadline = setTimeout(() => { void finish({ error: 'timeout' }); }, 18000);
    try { await finish({ models: await main() }); }
    catch (error) {
      const code = ['unavailable', 'response'].includes(error?.message) ? error.message : 'runtime';
      await finish({ error: code });
    }
    """#
}
