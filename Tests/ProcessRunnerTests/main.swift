import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func sh(_ script: String, errorOutput: ProcessRunner.ErrorOutput = .capture, input: Data? = nil,
                timeout: TimeInterval? = 20, killAfter: TimeInterval = 2,
                outputLimit: Int = 16_000_000) -> (ProcessRunner.Result?, TimeInterval) {
    let start = Date()
    let result = try? ProcessRunner.run("/bin/sh", ["-c", script], input: input, errorOutput: errorOutput,
                                        timeout: timeout, killAfter: killAfter, outputLimit: outputLimit)
    return (result, Date().timeIntervalSince(start))
}

private let big = 200_000
private let printBig = "head -c \(big) /dev/zero | tr '\\0' a"

// MARK: Output larger than a pipe holds

do {
    let (result, elapsed) = sh(printBig)
    expect(result?.output.count == big && result?.status == 0 && result?.timedOut == false,
           "200 KB on stdout is read in full: \(result?.output.count ?? -1) bytes, status \(result?.status ?? -1)")
    expect(elapsed < 5, "a large output doesn't stall until the timeout: \(elapsed)s")

    let (errors, errorElapsed) = sh("\(printBig) >&2; echo done")
    expect(errors?.errorOutput.count == big && errors?.text == "done",
           "200 KB on stderr doesn't stall stdout: \(errors?.errorOutput.count ?? -1) bytes, \(errors?.text ?? "nil")")
    expect(errorElapsed < 5, "a large stderr doesn't stall until the timeout: \(errorElapsed)s")

    let (discarded, _) = sh("\(printBig) >&2; echo done", errorOutput: .discard)
    expect(discarded?.text == "done" && discarded?.errorOutput.isEmpty == true, "discarded stderr isn't kept")

    let (merged, _) = sh("echo one; echo two >&2; echo three", errorOutput: .merge)
    expect(merged?.text == "one\ntwo\nthree", "merged stderr lands in output in order: \(merged?.text ?? "nil")")
}

// MARK: Output limit

do {
    let (result, elapsed) = sh(printBig, outputLimit: 1000)
    expect(result?.output.count == 1000 && result?.status == 0,
           "output past the limit is drained and dropped: \(result?.output.count ?? -1) bytes, status \(result?.status ?? -1)")
    expect(elapsed < 5, "a limited output still finishes: \(elapsed)s")
}

// MARK: Timeouts

do {
    let (result, elapsed) = sh("exec sleep 30", timeout: 0.3)
    expect(result?.timedOut == true && result?.succeeded == false, "a command past its timeout is stopped")
    expect(elapsed < 3, "SIGTERM ends a command that honors it: \(elapsed)s")

    let (stubborn, stubbornElapsed) = sh("trap '' TERM; exec sleep 30", timeout: 0.3, killAfter: 0.3)
    expect(stubborn?.timedOut == true, "a command ignoring SIGTERM still times out")
    expect(stubbornElapsed < 4, "SIGKILL follows when SIGTERM is ignored: \(stubbornElapsed)s")

    let (background, backgroundElapsed) = sh("(sleep 4 &); echo hi")
    expect(background?.text == "hi" && background?.status == 0,
           "output before a background child is kept: \(background?.text ?? "nil")")
    expect(backgroundElapsed < 3.5, "a background child holding the pipe doesn't hold the result: \(backgroundElapsed)s")
}

// MARK: Input

do {
    let payload = Data(repeating: UInt8(ascii: "b"), count: big)
    let start = Date()
    let echoed = try? ProcessRunner.run("/bin/cat", input: payload, timeout: 20)
    expect(echoed?.output == payload, "input larger than a pipe goes in while output comes out")
    expect(Date().timeIntervalSince(start) < 5, "large input and output don't deadlock")

    let ignored = try? ProcessRunner.run("/usr/bin/true", input: Data(count: 1_000_000), timeout: 20)
    expect(ignored?.status == 0, "a command that never reads its input doesn't raise SIGPIPE in the caller")
}

// MARK: Launch, environment, folder

do {
    var threw = false
    do { try ProcessRunner.run("/nonexistent/tool") } catch { threw = true }
    expect(threw, "a missing executable throws")

    let result = try? ProcessRunner.run("/bin/sh", ["-c", "printf %s \"$CANTRIP_TEST\"; pwd -P"],
                                        environment: ["CANTRIP_TEST": "value"],
                                        directory: URL(fileURLWithPath: "/usr/bin"))
    expect(result?.text == "value/usr/bin", "environment and folder are applied: \(result?.text ?? "nil")")

    var launched: Process?
    _ = try? ProcessRunner.run("/usr/bin/true", launched: { launched = $0 })
    expect(launched?.isRunning == false, "launched hands over the process")

    expect(ProcessRunner.output("/bin/echo", ["  hi  "]) == "hi", "output() trims a successful command")
    expect(ProcessRunner.output("/bin/sh", ["-c", "echo no; exit 3"]) == nil, "output() is nil for a failed command")
    expect(ProcessRunner.output("/nonexistent/tool") == nil, "output() is nil when the command can't start")
}

// MARK: Shell quoting

do {
    expect("it's here".shellQuoted == "'it'\\''s here'", "single quotes are escaped")
    let echoed = ProcessRunner.output("/bin/sh", ["-c", "printf %s " + "a 'b' $HOME `x`".shellQuoted])
    expect(echoed == "a 'b' $HOME `x`", "a quoted string reaches the command unchanged: \(echoed ?? "nil")")
}

if failures == 0 {
    print("Process runner tests passed")
} else {
    exit(1)
}
