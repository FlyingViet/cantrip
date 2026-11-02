import XCTest
@testable import Hermes

/// Grouped workspace lists: pure logic shared by Cantrip Agent and Cantrip Gateway Mac.
final class CantripHomeWorkspaceGroupTests: XCTestCase {
    private let stages = [
        "Applied", "Recruiter conversation scheduled", "Recruiter screen complete",
        "Technical interview scheduled", "Interviewing", "Final round", "Offer",
        "Rejected", "Withdrawn",
    ]
    private let trackerGroups = """
    "groupField":"stage","groups":[
    {"title":"In progress","values":["Recruiter conversation scheduled","Recruiter screen complete",
    "Technical interview scheduled","Interviewing","Final round","Offer"],"collapsed":false},
    {"title":"Applied","values":["Applied"],"collapsed":false},
    {"title":"Done","values":["Rejected","Withdrawn"],"collapsed":true}]
    """

    private func list(_ extra: String = "") throws -> CantripHomeTaskListPresentation {
        try JSONDecoder().decode(CantripHomeTaskListPresentation.self, from: Data("""
        {"titleField":"company","subtitleFields":["role"],"badgeField":"stage",
        "dateField":null\(extra.isEmpty ? "" : ",\(extra)")}
        """.utf8))
    }

    private func workspace(
        _ list: CantripHomeTaskListPresentation, _ records: [(String, String?)]
    ) -> CantripHomeTaskWorkspace {
        CantripHomeTaskWorkspace(
            recordLabel: "interview application",
            recordLabelPlural: "interview applications", icon: "briefcase.fill",
            fields: [
                .init(key: "company", label: "Company", kind: .text, required: true, options: nil),
                .init(key: "role", label: "Role", kind: .text, required: false, options: nil),
                .init(key: "stage", label: "Current stage", kind: .choice, required: false,
                      options: stages),
            ],
            list: list, detailSections: [],
            records: records.map { company, stage in
                var values = ["company": company]
                values["stage"] = stage
                return .init(id: UUID(), values: values, createdAt: .now, updatedAt: .now)
            }
        )
    }

    func testListsWithoutGroupsDecodeAndStayFlat() throws {
        let legacy = try list()
        XCTAssertNil(legacy.groupField)
        XCTAssertNil(legacy.groups)
        let flat = workspace(legacy, [("Headway", "Recruiter conversation scheduled")])
        XCTAssertNil(CantripHomeWorkspaceGrouping.sections(for: flat, records: flat.records))
    }

    func testTrackerGroupsKeepSavedOrderAndCount() throws {
        let grouped = try list(trackerGroups)
        XCTAssertEqual(grouped.groupField, "stage")
        XCTAssertEqual(grouped.groups?.map(\.title), ["In progress", "Applied", "Done"])
        XCTAssertEqual(grouped.groups?.map(\.collapsed), [false, false, true])
        let tracker = workspace(grouped, [
            ("Headway", "Recruiter conversation scheduled"),
            ("Legora", "Technical interview scheduled"),
            ("Persona", "Applied"),
            ("Rippling", "Technical interview scheduled"),
            ("Pinterest", "Applied"),
            ("Betterment", "Rejected"),
            ("Datalab", "Recruiter screen complete"),
            ("Ro", "Rejected"),
            ("Brex", "Withdrawn"),
        ])
        let sections = try XCTUnwrap(
            CantripHomeWorkspaceGrouping.sections(for: tracker, records: tracker.records)
        )
        XCTAssertEqual(sections.map(\.title), ["In progress", "Applied", "Done"])
        XCTAssertEqual(sections.map { $0.records.map { $0.values["company"]! } }, [
            ["Headway", "Legora", "Rippling", "Datalab"],
            ["Persona", "Pinterest"],
            ["Betterment", "Ro", "Brex"],
        ])
        XCTAssertEqual(sections.map(\.startsCollapsed), [false, false, true])
        XCTAssertEqual(sections.map(\.id), ["In progress", "Applied", "Done"])

        // Counts follow records as they change stage.
        var moved = tracker.records
        moved[1] = .init(id: moved[1].id, values: ["company": "Legora", "stage": "Rejected"],
                         createdAt: .now, updatedAt: .now)
        let after = try XCTUnwrap(CantripHomeWorkspaceGrouping.sections(for: tracker, records: moved))
        XCTAssertEqual(after.map(\.records.count), [3, 2, 4])
    }

    func testUnlistedAndMissingValuesFallUnderOtherAndEmptyGroupsStay() throws {
        let grouped = try list("""
        "groupField":"stage","groups":[{"title":"Applied","values":["Applied"]},
        {"title":"Offers","values":["Offer"]}]
        """)
        let tracker = workspace(grouped, [
            ("Ro", "Rejected"), ("Persona", "Applied"), ("Unknown", nil), ("Brex", "Withdrawn"),
        ])
        let sections = try XCTUnwrap(
            CantripHomeWorkspaceGrouping.sections(for: tracker, records: tracker.records)
        )
        XCTAssertEqual(sections.map(\.title), ["Applied", "Offers", "Other"])
        XCTAssertEqual(sections.map(\.records.count), [1, 0, 3])
        XCTAssertEqual(sections.last?.id, CantripHomeWorkspaceGrouping.otherID)
        XCTAssertEqual(sections.last?.records.map { $0.values["company"]! }, ["Ro", "Unknown", "Brex"])

        let searched = try XCTUnwrap(CantripHomeWorkspaceGrouping.sections(
            for: tracker, records: tracker.records.filter { $0.values["company"] == "Persona" },
            searching: true
        ))
        XCTAssertEqual(searched.map(\.title), ["Applied"], "Search hides sections without matches")
    }

    func testGroupFieldAloneMakesOneSectionPerUsedOption() throws {
        let tracker = workspace(try list(#""groupField":"stage""#), [
            ("Ro", "Rejected"), ("Persona", "Applied"), ("Pinterest", "Applied"),
        ])
        let sections = try XCTUnwrap(
            CantripHomeWorkspaceGrouping.sections(for: tracker, records: tracker.records)
        )
        XCTAssertEqual(sections.map(\.title), ["Applied", "Rejected"], "Option order, no empty options")
        XCTAssertEqual(sections.map(\.records.count), [2, 1])
    }

    func testCollapseStateIsRememberedPerTask() throws {
        let suite = "CantripHomeWorkspaceGroupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = UUID()
        let other = UUID()
        XCTAssertEqual(CantripHomeWorkspaceGroupState.load(taskID: tracker, defaults: defaults), [:])
        CantripHomeWorkspaceGroupState.save(
            ["Done": false, "Applied": true], taskID: tracker, defaults: defaults
        )
        XCTAssertEqual(CantripHomeWorkspaceGroupState.load(taskID: tracker, defaults: defaults),
                       ["Done": false, "Applied": true])
        XCTAssertEqual(CantripHomeWorkspaceGroupState.load(taskID: other, defaults: defaults), [:])
        CantripHomeWorkspaceGroupState.save([:], taskID: tracker, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: CantripHomeWorkspaceGroupState.key(taskID: tracker)))
    }
}
