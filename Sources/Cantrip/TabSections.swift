import Foundation

/// A named group of tabs in the tab lists, like a Slack sidebar section. Tabs without one (or
/// whose section was deleted) show under "Tabs". Sections live on the host so every device
/// shows the same ones; whether a section is collapsed is each device's own choice.
struct TabSection: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String

    var json: [String: Any] { ["id": id.uuidString, "name": name] }
}

enum TabSectionError: LocalizedError, Equatable {
    case emptyName, nameTooLong, duplicate, tooMany, unavailable, notAllowed

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the section a name."
        case .nameTooLong: return "Section names must be \(TabSectionStore.maximumNameLength) characters or fewer."
        case .duplicate: return "There's already a section with that name."
        case .tooMany: return "You can have up to \(TabSectionStore.maximumCount) sections."
        case .unavailable: return "That section no longer exists. Refresh the tabs and try again."
        case .notAllowed: return "This tab can't be moved into a section."
        }
    }

    /// HTTP status for the Remote API.
    var status: Int {
        switch self {
        case .unavailable: return 404
        case .duplicate, .tooMany: return 409
        default: return 400
        }
    }
}

enum TabSectionStore {
    static let key = "tabSections"
    static let maximumCount = 50
    static let maximumNameLength = 40

    static func load(_ defaults: UserDefaults = .standard) -> [TabSection] {
        guard let data = defaults.data(forKey: key),
              let sections = try? JSONDecoder().decode([TabSection].self, from: data) else { return [] }
        var seen: Set<UUID> = []
        return sections.filter { seen.insert($0.id).inserted }
    }

    static func save(_ sections: [TabSection], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(sections) { defaults.set(data, forKey: key) }
    }

    /// A list drag (`onMove`: `destination` counts rows before the move) as the section's new
    /// position for `SessionManager.moveSection`.
    static func position(movingFrom source: Int, to destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }

    /// Whitespace collapsed to single spaces; 1 to `maximumNameLength` characters.
    static func normalizedName(_ raw: String) throws -> String {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { throw TabSectionError.emptyName }
        guard name.count <= maximumNameLength else { throw TabSectionError.nameTooLong }
        return name
    }
}

extension SessionManager {
    /// The section a tab shows under; nil for Tabs, reserved Home sessions and deleted sections.
    func sectionID(of session: ChatSession) -> UUID? {
        guard !Self.isCantripHomeReserved(session), !session.isPrivate,
              let id = session.tabMetadata.sectionID, tabSections.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    @discardableResult
    func createSection(named raw: String) throws -> TabSection {
        let name = try TabSectionStore.normalizedName(raw)
        guard tabSections.count < TabSectionStore.maximumCount else { throw TabSectionError.tooMany }
        try requireUniqueSectionName(name, except: nil)
        let section = TabSection(id: UUID(), name: name)
        tabSections.append(section)
        TabSectionStore.save(tabSections)
        return section
    }

    func renameSection(_ id: UUID, to raw: String) throws {
        let name = try TabSectionStore.normalizedName(raw)
        guard let index = tabSections.firstIndex(where: { $0.id == id }) else { throw TabSectionError.unavailable }
        try requireUniqueSectionName(name, except: id)
        tabSections[index].name = name
        TabSectionStore.save(tabSections)
    }

    /// Moves a section to `position` among the sections (clamped).
    func moveSection(_ id: UUID, to position: Int) throws {
        guard let index = tabSections.firstIndex(where: { $0.id == id }) else { throw TabSectionError.unavailable }
        var sections = tabSections
        let section = sections.remove(at: index)
        sections.insert(section, at: min(max(position, 0), sections.count))
        guard sections != tabSections else { return }
        tabSections = sections
        TabSectionStore.save(tabSections)
    }

    /// Deletes a section; its open tabs go back to Tabs (closed tabs do when reopened).
    func deleteSection(_ id: UUID) throws {
        guard tabSections.contains(where: { $0.id == id }) else { throw TabSectionError.unavailable }
        tabSections.removeAll { $0.id == id }
        TabSectionStore.save(tabSections)
        for session in sessions where session.tabMetadata.sectionID == id {
            try session.saveSection(nil)
        }
    }

    /// Files a tab under a section (nil = Tabs), placing it after the section's last tab.
    func setSection(_ sectionID: UUID?, for tabID: UUID) throws {
        guard let session = sessions.first(where: { $0.id == tabID }) else { throw SessionTabError.unavailable }
        guard !Self.isCantripHomeReserved(session), !session.isPrivate else { throw TabSectionError.notAllowed }
        if let sectionID, !tabSections.contains(where: { $0.id == sectionID }) { throw TabSectionError.unavailable }
        guard self.sectionID(of: session) != sectionID || session.tabMetadata.sectionID != sectionID else { return }
        let last = sessions.last { $0.id != tabID && self.sectionID(of: $0) == sectionID && !Self.isCantripHomeReserved($0) }
        try session.saveSection(sectionID)
        if let last { try moveSession(tabID, relativeTo: last.id, after: true) }
    }

    /// A new tab filed under a section.
    @discardableResult
    func newSession(inSection sectionID: UUID?) throws -> ChatSession {
        if let sectionID, !tabSections.contains(where: { $0.id == sectionID }) { throw TabSectionError.unavailable }
        let session = newSession()
        if let sectionID { try setSection(sectionID, for: session.id) }
        return session
    }

    private func requireUniqueSectionName(_ name: String, except id: UUID?) throws {
        if tabSections.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TabSectionError.duplicate
        }
    }
}
