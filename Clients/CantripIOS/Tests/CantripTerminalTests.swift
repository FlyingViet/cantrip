import Foundation
import XCTest
@testable import Hermes

/// A tab's terminal: offsets never show output twice, Up/Down browse history, and the model
/// polls and sends commands once on one route.
@MainActor
final class CantripTerminalTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000a7"

    private func snapshot(_ text: String, start: Int, end: Int? = nil, epoch: String = "e1", reset: Bool = false,
                          running: Bool = false, history: [String] = []) -> CantripTerminalSnapshot {
        .init(epoch: epoch, start: start, end: end ?? start + text.unicodeScalars.count, text: text, reset: reset,
              isRunning: running, agentCommandRunning: false, history: history, workdir: "/Users/me/Coding/Plexa")
    }

    func testBufferAppendsByOffsetAndSkipsOverlaps() {
        var buffer = CantripTerminalBuffer()
        buffer.apply(snapshot("$ ls\n", start: 0, reset: true))
        XCTAssertEqual(buffer.output, "$ ls\n")
        XCTAssertEqual(buffer.end, 5)
        buffer.apply(snapshot("a.txt\n", start: 5))
        // A slower poll from an earlier place overlaps the command's reply.
        buffer.apply(snapshot("ls\na.txt\nb.txt\n", start: 2))
        XCTAssertEqual(buffer.output, "$ ls\na.txt\nb.txt\n", "Overlapping output appears once")
        buffer.apply(snapshot("a.txt\n", start: 5))
        XCTAssertEqual(buffer.output, "$ ls\na.txt\nb.txt\n", "Stale replies change nothing")
        buffer.apply(snapshot("é🙂\n", start: buffer.end))
        XCTAssertEqual(buffer.end, 20, "Offsets count Unicode scalars, as the Mac does")
    }

    func testBufferResetsOnClearTrimOrGap() {
        var buffer = CantripTerminalBuffer()
        buffer.apply(snapshot("old\n", start: 0, reset: true))
        buffer.apply(snapshot("", start: 0, end: 0, epoch: "e2", reset: true))
        XCTAssertEqual(buffer.output, "", "Clear on any device empties the terminal")
        XCTAssertEqual(buffer.epoch, "e2")
        buffer.apply(snapshot("kept\n", start: 40, epoch: "e2"))
        XCTAssertNil(buffer.epoch, "A gap asks for everything on the next poll")
        XCTAssertEqual(buffer.output, "")
        buffer.apply(snapshot("kept\n", start: 40, epoch: "e2", reset: true))
        XCTAssertEqual(buffer.output, "kept\n")
        XCTAssertEqual(buffer.end, 45)
    }

    func testHistoryBrowsesAndRestoresTheDraft() {
        var history = CantripTerminalHistory()
        let commands = ["ls", "git status", "make test"]
        XCTAssertNil(history.step(backward: false, history: commands, current: "gi"))
        XCTAssertEqual(history.step(backward: true, history: commands, current: "gi"), "make test")
        XCTAssertEqual(history.step(backward: true, history: commands, current: "make test"), "git status")
        XCTAssertEqual(history.step(backward: true, history: commands, current: ""), "ls")
        XCTAssertEqual(history.step(backward: true, history: commands, current: ""), "ls", "Stops at the oldest")
        XCTAssertEqual(history.step(backward: false, history: commands, current: ""), "git status")
        XCTAssertEqual(history.step(backward: false, history: commands, current: ""), "make test")
        XCTAssertEqual(history.step(backward: false, history: commands, current: ""), "gi", "Down past the newest restores the draft")
        XCTAssertNil(history.index)
        XCTAssertNil(history.step(backward: true, history: [], current: "x"))
    }

    func testPathCarriesTheClientsPlace() throws {
        XCTAssertEqual(try CantripRemoteAPI.terminalPath(sessionID: sessionID, action: nil, from: nil, epoch: nil),
                       "/api/v1/sessions/\(sessionID)/terminal")
        XCTAssertEqual(try CantripRemoteAPI.terminalPath(sessionID: sessionID, action: "interrupt", from: 12, epoch: "a b"),
                       "/api/v1/sessions/\(sessionID)/terminal/interrupt?from=12&epoch=a%20b")
    }

    func testModelPollsRunsOnceAndReportsOlderMacs() async throws {
        let model = try StartFreshFixture.model(for: self)
        var commands: [String] = []
        var posts = 0
        var text = ""
        StartFreshRequestProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/sessions" {
                return (200, try JSONSerialization.data(withJSONObject: ["sessions": [] as [Any]]))
            }
            XCTAssertTrue(path.hasPrefix("/api/v1/sessions/\(self.sessionID)/terminal"), path)
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            let from = Int(query.first { $0.name == "from" }?.value ?? "") ?? 0
            if request.httpMethod == "POST" {
                posts += 1
                let body = try XCTUnwrap(Self.body(of: request))
                let command = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])["command"]
                commands.append(try XCTUnwrap(command))
                text += "$ \(command ?? "")\n"
            }
            let scalars = Array(text.unicodeScalars)
            let tail = String(String.UnicodeScalarView(scalars[min(from, scalars.count)...]))
            let reply: [String: Any] = [
                "epoch": "e1", "start": min(from, scalars.count), "end": scalars.count, "text": tail,
                "reset": from == 0, "isRunning": false, "agentCommandRunning": false,
                "history": commands, "workdir": "/Users/me/Coding/Plexa",
            ]
            return (200, try JSONSerialization.data(withJSONObject: reply))
        }
        let terminal = CantripTerminalModel()
        terminal.start(remote: model, sessionID: sessionID)
        terminal.stop()
        await terminal.poll()
        XCTAssertTrue(terminal.isLoaded, terminal.errorMessage ?? "Not loaded")
        XCTAssertEqual(terminal.workdir, "/Users/me/Coding/Plexa")
        let multiline = await terminal.run("echo one\necho two")
        XCTAssertFalse(multiline, "One line at a time")
        let ran = await terminal.run("  git status  ")
        XCTAssertTrue(ran)
        XCTAssertEqual(commands, ["git status"])
        XCTAssertEqual(posts, 1, "A command is sent once")
        XCTAssertEqual(terminal.buffer.output, "$ git status\n")
        XCTAssertEqual(terminal.history, ["git status"])
        await terminal.poll()
        XCTAssertEqual(terminal.buffer.output, "$ git status\n", "A caught-up poll adds nothing")

        StartFreshRequestProtocol.handler = { _ in
            (404, try JSONSerialization.data(withJSONObject: ["error": "not found"]))
        }
        await terminal.poll()
        XCTAssertEqual(terminal.errorMessage, CantripTerminalModel.unsupported)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&chunk, maxLength: chunk.count)
            guard count > 0 else { break }
            data.append(chunk, count: count)
        }
        return data
    }
}
