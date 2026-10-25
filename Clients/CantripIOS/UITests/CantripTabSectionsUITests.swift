import XCTest

/// The tab drawer with sections from a local host such as the Gateway QA host seeded with "Work"
/// and "Personal": headers collapse, and Move to Section files a tab. Run with
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL=http://127.0.0.1:<port>` and
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN=<token>`.
final class CantripTabSectionsUITests: XCTestCase {
    func testSectionsCollapseAndTabsMoveBetweenThem() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host with sections and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label == 'Tabs'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 30))
        tabsButton.tap()
        let personal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Personal,'")).firstMatch
        XCTAssertTrue(personal.waitForExistence(timeout: 15), "Sections show as headers")
        // The row itself, not its "Reorder Resume" handle.
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-tab-' AND label == 'Resume'")).firstMatch
        XCTAssertTrue(resume.exists)
        attach(app, "1-sections")

        personal.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !resume.exists }, "Collapsing hides the section's idle tabs")
        XCTAssertEqual(personal.value as? String, "Collapsed")
        attach(app, "2-collapsed")
        personal.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))

        resume.press(forDuration: 1.2)
        let move = app.buttons["Move to Section"]
        XCTAssertTrue(move.waitForExistence(timeout: 5), "A tab's menu offers Move to Section")
        move.tap()
        let work = app.buttons["Work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        attach(app, "3-move-menu")
        work.tap()
        let workHeader = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Work,'")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) { workHeader.label.contains("4 tabs") }, "Resume joins Work: \(workHeader.label)")
        attach(app, "4-moved")
    }

    /// Edit Sections from a header's visible "…": drag a section by its ≡ handle, rename one, and
    /// check the host saved both. Needs a host with at least three sections; the first two swap.
    func testEditSectionsReordersAndRenames() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host with sections and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let sections = try hostSections(url: url, token: token)
        let before = sections.map(\.name)
        XCTAssertGreaterThanOrEqual(before.count, 3, "The host needs three sections")
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label == 'Tabs'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 30))
        tabsButton.tap()
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "\(before[0]) section options")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "Section headers show a visible … menu")
        attach(app, "edit-1-drawer")
        menu.tap()
        let edit = app.buttons["Edit Sections…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The section menu offers Edit Sections")
        attach(app, "edit-2-menu")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Sections"].waitForExistence(timeout: 5))
        attach(app, "edit-3-sheet")

        // Drag the first section below the second by its ≡ handle.
        let firstHandle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder \(before[0]),")).firstMatch
        let secondHandle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder \(before[1]),")).firstMatch
        XCTAssertTrue(firstHandle.waitForExistence(timeout: 5), "Rows have reorder handles")
        firstHandle.press(forDuration: 0.6, thenDragTo: secondHandle, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitUntil(timeout: 10) {
            (try? self.hostSectionNames(url: url, token: token)).map { Array($0.prefix(2)) } == [before[1], before[0]]
        }, "The Mac saves the dragged order: \((try? hostSectionNames(url: url, token: token)) ?? [])")
        attach(app, "edit-4-dragged")

        // Rename by tapping a row.
        let row = app.buttons["sections.editor.row.\(sections[2].id)"]
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.value as? String, "Section 3 of \(before.count)")
        row.tap()
        // Alerts drop their text field's identifier.
        let field = app.alerts["Rename Section"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Tapping a section asks for its name")
        XCTAssertEqual(field.value as? String, before[2], "The prompt starts with the current name")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: before[2].count + 2))
        field.typeText(before[2] + " QA")
        attach(app, "edit-5-rename")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            (try? self.hostSectionNames(url: url, token: token))?.contains(before[2] + " QA") == true
        }, "The Mac saves the new name")
        attach(app, "edit-6-renamed")
        app.buttons["sections.editor.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.navigationBars["Edit Sections"].exists })
        attach(app, "edit-7-drawer-after")
    }

    private func hostSectionNames(url: String, token: String) throws -> [String] {
        try hostSections(url: url, token: token).map(\.name)
    }

    private func hostSections(url: String, token: String) throws -> [(id: String, name: String)] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url + "/api/v1/sections")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        var result: Result<Data, Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = data.map { .success($0) } ?? .failure(error ?? URLError(.badServerResponse))
            done.signal()
        }.resume()
        done.wait()
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(result).get()) as? [String: Any]
        return (object?["sections"] as? [[String: Any]] ?? []).compactMap { section in
            guard let id = section["id"] as? String, let name = section["name"] as? String else { return nil }
            return (id, name)
        }
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { return }
            deny.tap()
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
