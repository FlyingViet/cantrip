import Foundation

/// Runs a command to completion and collects what it prints.
///
/// Output is read while the command runs. A pipe holds 64 KB, so a command that prints more
/// waits until someone reads it: reading only after the exit never finishes. For commands that
/// stream into the UI or stay up (agent CLIs, `!` commands), use `Process` directly.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var output: Data
        var errorOutput: Data
        var timedOut = false

        var succeeded: Bool { !timedOut && status == 0 }
        /// Standard output (and standard error when merged), trimmed.
        var text: String { Self.trimmed(output) }
        var errorText: String { Self.trimmed(errorOutput) }

        private static func trimmed(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum ErrorOutput {
        case discard, capture
        /// Into `output`, interleaved as printed.
        case merge
    }

    /// Runs `executable` and waits for it. Throws only when it can't start.
    ///
    /// - Parameters:
    ///   - timeout: After this the command gets SIGTERM, then SIGKILL `killAfter` seconds later.
    ///   - outputLimit: Bytes kept per stream; the rest is read and dropped so the command never stalls.
    ///   - launched: Called with the running process, e.g. to stop it from elsewhere.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        input: Data? = nil,
        errorOutput: ErrorOutput = .capture,
        timeout: TimeInterval? = nil,
        killAfter grace: TimeInterval = 2,
        outputLimit: Int = 16_000_000,
        launched: ((Process) -> Void)? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }

        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let output = Collector(outputPipe.fileHandleForReading, limit: outputLimit)
        var errors: Collector?
        switch errorOutput {
        case .discard:
            process.standardError = FileHandle.nullDevice
        case .merge:
            process.standardError = outputPipe
        case .capture:
            let errorPipe = Pipe()
            process.standardError = errorPipe
            errors = Collector(errorPipe.fileHandleForReading, limit: outputLimit)
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            output.cancel()
            errors?.cancel()
            throw error
        }
        launched?(process)

        if let input, let writer = inputPipe?.fileHandleForWriting {
            // A command that exits without reading its input must not take Cantrip down with SIGPIPE.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }

        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if exited.wait(timeout: .now() + grace) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 5)
                }
            }
        } else {
            exited.wait()
        }

        // A background child can keep the pipes open after the command exits, so don't wait long for their end.
        let drained = DispatchTime.now() + 2
        let outputData = output.collect(until: drained)
        let errorData = errors?.collect(until: drained) ?? Data()
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: status, output: outputData, errorOutput: errorData, timedOut: timedOut)
    }

    /// Trimmed standard output of a command that started and exited 0; nil otherwise.
    static func output(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: TimeInterval? = nil
    ) -> String? {
        guard let result = try? run(executable, arguments, environment: environment, directory: directory,
                                    errorOutput: .discard, timeout: timeout),
              result.succeeded else { return nil }
        return result.text
    }

    /// Reads one stream as data arrives, keeping at most `limit` bytes.
    private final class Collector: @unchecked Sendable {
        private let handle: FileHandle
        private let limit: Int
        private let lock = NSLock()
        private var data = Data()
        private var ended = false
        private let finished = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = max(0, limit)
            handle.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                lock.lock()
                defer { lock.unlock() }
                if chunk.isEmpty {
                    // At end of file the handler keeps firing with empty data until it's removed.
                    guard !ended else { return }
                    ended = true
                    handle.readabilityHandler = nil
                    finished.signal()
                } else if data.count < self.limit {
                    data.append(chunk.prefix(self.limit - data.count))
                }
            }
        }

        func collect(until deadline: DispatchTime) -> Data {
            _ = finished.wait(timeout: deadline)
            handle.readabilityHandler = nil
            return lock.withLock { data }
        }

        func cancel() {
            handle.readabilityHandler = nil
        }
    }
}

extension String {
    /// Single-quoted for a POSIX shell command line.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
