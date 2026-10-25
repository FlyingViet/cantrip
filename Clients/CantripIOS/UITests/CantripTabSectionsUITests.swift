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

        // No ≡ handles: touch and hold the first section, then drag it below the second.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder '")).firstMatch.exists,
                       "Rows show no reorder handles")
        let firstRow = app.descendants(matching: .any)["sections.editor.row.\(sections[0].id)"]
        let secondRow = app.descendants(matching: .any)["sections.editor.row.\(sections[1].id)"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.8, thenDragTo: secondRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
            withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(waitUntil(timeout: 10) {
            (try? self.hostSectionNames(url: url, token: token)).map { Array($0.prefix(2)) } == [before[1], before[0]]
        }, "The Mac saves the dragged order: \((try? hostSectionNames(url: url, token: token)) ?? [])")
        attach(app, "edit-4-dragged")

        // Rename by tapping a row.
        let row = app.descendants(matching: .any)["sections.editor.row.\(sections[2].id)"]
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

    /// The drawer has no ≡ handles: touch and hold a tab, then drag, reorders it; a still hold still
    /// opens its menu; touch and hold a section header, then drag onto another, reorders sections.
    func testHoldToDragReordersTabsAndSectionsInTheDrawer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host with sections and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let sections = try hostSections(url: url, token: token)
        XCTAssertGreaterThanOrEqual(sections.count, 2)
        let tabs = try hostTabs(url: url, token: token)
        let group = tabs.filter { $0.sectionID == sections.last { section in tabs.filter { $0.sectionID == section.id }.count >= 2 }?.id }
        XCTAssertGreaterThanOrEqual(group.count, 2, "The host needs a section with two tabs")
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()
        let tabsButton = app.buttons.matching(NSPredicate(format: "label == 'Tabs'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 30))
        tabsButton.tap()
        let list = app.descendants(matching: .any)["cantrip-tab-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder '")).firstMatch.exists,
                       "Tab rows show no ≡ reorder handles")
        attach(app, "drag-1-no-handles")

        // A still hold opens the tab's menu.
        func row(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-tab-' AND label == %@", title)).firstMatch
        }
        let first = row(group[0].title), second = row(group[1].title)
        for _ in 0..<10 where !(second.exists && second.isHittable) { list.swipeUp() }
        XCTAssertTrue(first.isHittable && second.isHittable)
        first.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Move to Section"].waitForExistence(timeout: 5), "A still hold still opens the menu")
        attach(app, "drag-2-menu")
        // Dismiss the menu with a tap outside it (the menu covers the middle of the drawer).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.96)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["Move to Section"].exists })

        // Touch and hold, then drag, moves the tab below its neighbor.
        let below = second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        // Hold until the row lifts (about half a second), then move: a drag, not the menu.
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: below, withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(waitUntil(timeout: 10) {
            let order = ((try? self.hostTabs(url: url, token: token)) ?? []).map(\.id)
            guard let a = order.firstIndex(of: group[0].id), let b = order.firstIndex(of: group[1].id) else { return false }
            return a > b
        }, "The Mac saves the dragged tab order")
        attach(app, "drag-3-tab-moved")

        // Touch and hold a section header, then drag it onto the first section's header.
        let lastSection = sections[sections.count - 1], firstSection = sections[0]
        let lastHeader = app.buttons["cantrip-tab-section-\(lastSection.id)"]
        let firstHeader = app.buttons["cantrip-tab-section-\(firstSection.id)"]
        for _ in 0..<10 where !(firstHeader.exists && firstHeader.isHittable) { list.swipeDown() }
        // Collapse the bulky sections in between so both headers fit on screen.
        for section in sections.dropFirst().dropLast() {
            let header = app.buttons["cantrip-tab-section-\(section.id)"]
            if header.exists, header.isHittable, (header.value as? String) == "Expanded" { header.tap() }
        }
        for _ in 0..<10 where !(lastHeader.exists && lastHeader.isHittable) { list.swipeUp() }
        XCTAssertTrue(lastHeader.isHittable && firstHeader.isHittable, "Both headers are on screen")
        lastHeader.press(forDuration: 0.6, thenDragTo: firstHeader, withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(waitUntil(timeout: 10) {
            (try? self.hostSectionNames(url: url, token: token))?.first == lastSection.name
        }, "The Mac saves the dragged section order: \((try? hostSectionNames(url: url, token: token)) ?? [])")
        attach(app, "drag-4-section-moved")
    }

    /// From the tab drawer: New Section makes an empty section, a tab moves into it from its menu,
    /// and the header's … deletes it after confirming; the tab stays open, back under Tabs.
    func testNewEmptySectionThenDeleteFromTheDrawer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host with sections and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let name = "Later"
        XCTAssertFalse(try hostSectionNames(url: url, token: token).contains(name))
        let unfiled = try XCTUnwrap(try hostTabs(url: url, token: token).first { $0.sectionID == nil }, "The host needs an unfiled tab")
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label == 'Tabs'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 30))
        tabsButton.tap()
        // The list loads rows as they scroll in; New Section is the last one.
        let list = app.descendants(matching: .any)["cantrip-tab-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let newSection = app.buttons["cantrip-tab-new-section"]
        for _ in 0..<10 where !(newSection.exists && newSection.isHittable) { list.swipeUp() }
        XCTAssertTrue(newSection.waitForExistence(timeout: 5), "The tab list ends with New Section")
        attach(app, "new-1-button")
        newSection.tap()
        let field = app.alerts["New Section"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "New Section asks for a name")
        field.typeText(name)
        attach(app, "new-2-prompt")
        app.alerts["New Section"].buttons["Create"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.hostSectionNames(url: url, token: token))?.contains(name) == true },
                      "The Mac saves the empty section")
        XCTAssertFalse(try hostTabs(url: url, token: token).contains { $0.sectionID != nil && $0.sectionName == name },
                       "New Section files no tab")
        let header = app.buttons.matching(NSPredicate(format: "label == %@", "\(name), 0 tabs")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "The empty section shows as a header")
        attach(app, "new-3-empty-section")

        // Move a tab into it from the tab's menu (the unfiled tabs are at the top).
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-tab-' AND label == %@", unfiled.title)).firstMatch
        for _ in 0..<10 where !(row.exists && row.isHittable) { list.swipeDown() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)
        let move = app.buttons["Move to Section"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.tap()
        let target = app.buttons[name]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Move to Section lists the empty section")
        target.tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            (try? self.hostTabs(url: url, token: token))?.first { $0.id == unfiled.id }?.sectionName == name
        }, "The tab moves into the new section")
        let filledHeader = app.buttons.matching(NSPredicate(format: "label == %@", "\(name), 1 tab")).firstMatch
        for _ in 0..<10 where !(filledHeader.exists && filledHeader.isHittable) { list.swipeUp() }
        XCTAssertTrue(filledHeader.waitForExistence(timeout: 10))
        attach(app, "new-4-filed")

        // Delete it from the header's …; it asks first because it has a tab.
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "\(name) section options")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let delete = app.buttons["Delete Section…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "A section with tabs offers Delete Section…")
        attach(app, "delete-1-menu")
        delete.tap()
        let confirm = app.buttons["Delete Section"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a section with tabs asks first")
        XCTAssertTrue(try hostSectionNames(url: url, token: token).contains(name), "Nothing is deleted before confirming")
        attach(app, "delete-2-confirm")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.hostSectionNames(url: url, token: token))?.contains(name) == false },
                      "The Mac deletes the section")
        let after = try XCTUnwrap(try hostTabs(url: url, token: token).first { $0.id == unfiled.id }, "Deleting a section keeps its tabs")
        XCTAssertNil(after.sectionID, "The tab goes back to Tabs")
        for _ in 0..<10 where !(row.exists && row.isHittable) { list.swipeDown() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        attach(app, "delete-3-after")
    }

    private func hostTabs(url: String, token: String) throws -> [(id: String, title: String, sectionID: String?, sectionName: String?)] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url + "/api/v1/sessions")))
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
        let names = Dictionary(uniqueKeysWithValues: (object?["sections"] as? [[String: Any]] ?? []).compactMap { section in
            (section["id"] as? String).map { ($0, section["name"] as? String ?? "") }
        })
        return (object?["sessions"] as? [[String: Any]] ?? []).compactMap { tab in
            guard let id = tab["id"] as? String, let title = tab["title"] as? String, tab["isCantripHome"] as? Bool != true else { return nil }
            let section = tab["sectionID"] as? String
            return (id, title, section, section.flatMap { names[$0] })
        }
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
