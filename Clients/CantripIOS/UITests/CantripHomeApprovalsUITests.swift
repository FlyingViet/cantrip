import XCTest

/// Real touches answering Cantrip Home background-run requests in place, against a local fixture
/// host (`fake_home_host.py`) whose two hidden runs wait on an approval and a question.
/// Run with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`.
final class CantripHomeApprovalsUITests: XCTestCase {
    private var host: URL!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["CANTRIP_UITEST_HOME_URL"], let url = URL(string: raw) else {
            throw XCTSkip("Start fake_home_host.py and set CANTRIP_UITEST_HOME_URL")
        }
        continueAfterFailure = false
        host = url
        var request = URLRequest(url: url.appendingPathComponent("qa/reset"))
        request.httpMethod = "POST"
        _ = try fetch(request)
    }

    private func fetch(_ request: URLRequest) throws -> Data {
        var result: Result<Data, Error>?
        let done = expectation(description: "fixture host")
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data ?? Data())
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    /// What the fixture host received, as (request ID, decision, text).
    private func answers() throws -> [(request: String, decision: String, text: String?)] {
        let data = try fetch(URLRequest(url: host.appendingPathComponent("qa/answers")))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["answers"] as? [[String: Any]] ?? []).map {
            (($0["request"] as? String ?? "").uppercased(), $0["decision"] as? String ?? "", $0["text"] as? String)
        }
    }

    private func launch(lane: String, notifyRun: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host.absoluteString,
                               "-CantripUITestRemoteToken", "history-qa-token", "-CantripUITestLane", lane]
        if let notifyRun {
            app.launchArguments += ["-CantripUITestNotifyHomeRun", notifyRun, "-CantripUITestNotifyAfter", "10"]
        }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        return app
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return try condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPushFromCantripRemoteOpensTheRequestInHomeAndApprovingResumesTheRun() throws {
        let app = launch(lane: "cantrip", notifyRun: "40000000-0000-0000-0000-0000000000a1")
        let remoteLane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Cantrip Remote' OR label == 'Bass Compass'")).firstMatch
        XCTAssertTrue(remoteLane.waitForExistence(timeout: 20), "Starts in the Remote lane")
        attach(app, "0-remote-lane-before-push")
        let sheet = app.navigationBars["Background"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 25), "The push opens Home's Background list")
        let approval = app.staticTexts["Daily follow-up tracker wants to send a message"]
        XCTAssertTrue(approval.waitForExistence(timeout: 10), "The approval appears in place")
        XCTAssertTrue(app.staticTexts["Needs your input"].exists)
        attach(app, "1-push-opens-approval-in-home")
        app.buttons["Approve once"].firstMatch.tap()
        XCTAssertTrue(try waitUntil(timeout: 10) {
            try answers().contains { $0.request == "50000000-0000-0000-0000-0000000000A1" && $0.decision == "approve" }
        }, "Approving reaches the hidden run's session")
        XCTAssertTrue(approval.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Answered on the phone; the run continued and finished."].waitForExistence(timeout: 15),
                      "The run resumes and finishes")
        attach(app, "2-approved-run-finished")
        sheet.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        let homeHeader = app.buttons.matching(NSPredicate(format: "label == 'Pip'")).firstMatch
        XCTAssertTrue(homeHeader.exists && (homeHeader.value as? String)?.contains("Cantrip Home") == true,
                      "Home stays open; no redirect to Cantrip Remote")
        attach(app, "3-home-after-answer")
    }

    func testTasksAndBackgroundButtonAnswerQuestionsAndApprovalsInPlace() throws {
        let app = launch(lane: "home")
        let tasksTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tasks'")).firstMatch
        XCTAssertTrue(tasksTab.waitForExistence(timeout: 20))
        let background = app.buttons["Background"].firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 15) { (background.value as? String)?.contains("need your input") == true },
                      "Home's Background button says requests are waiting")
        tasksTab.tap()
        let respond = app.buttons["Respond to Bills and subscriptions monitor"]
        XCTAssertTrue(respond.waitForExistence(timeout: 15), "Tasks shows which task's run waits")
        attach(app, "4-tasks-needs-input")
        respond.tap()
        let sheet = app.navigationBars["Background"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Respond opens the request in place")
        let question = app.staticTexts["Which inbox should I check for the Comcast bill?"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        attach(app, "5-task-question-in-place")
        app.buttons["Work inbox"].firstMatch.tap()
        XCTAssertTrue(try waitUntil(timeout: 10) {
            try answers().contains { $0.request == "50000000-0000-0000-0000-0000000000B2"
                && $0.decision == "submit" && $0.text == "Work inbox" }
        }, "A choice answers the question run")
        XCTAssertTrue(question.waitForNonExistence(timeout: 10))

        sheet.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        app.buttons["Chat"].firstMatch.tap()
        background.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The Background button opens the same list")
        let approval = app.staticTexts["Daily follow-up tracker wants to send a message"]
        XCTAssertTrue(approval.waitForExistence(timeout: 10))
        app.buttons["Deny"].firstMatch.tap()
        XCTAssertTrue(try waitUntil(timeout: 10) {
            try answers().contains { $0.request == "50000000-0000-0000-0000-0000000000A1" && $0.decision == "deny" }
        }, "Deny reaches the run too")
        XCTAssertTrue(approval.waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 15) { (background.value as? String)?.contains("need your input") != true },
                      "Nothing is left waiting")
    }
}
