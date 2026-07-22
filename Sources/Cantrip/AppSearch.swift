import Foundation

struct AppSearchScore: Equatable {
    let tier: Int
    let gaps: Int
    let start: Int
    let nameLength: Int
}

enum AppSearchMatcher {
    static func bestMatchIndex(
        query: String,
        candidates: [(name: String, isRunning: Bool)]
    ) -> Int? {
        let matches = candidates.enumerated().compactMap { index, candidate in
            score(query: query, appName: candidate.name).map {
                (index: index, candidate: candidate, score: $0)
            }
        }

        return matches.min { lhs, rhs in
            if lhs.score.tier != rhs.score.tier {
                return lhs.score.tier < rhs.score.tier
            }
            if lhs.candidate.isRunning != rhs.candidate.isRunning {
                return lhs.candidate.isRunning
            }
            if lhs.score.gaps != rhs.score.gaps {
                return lhs.score.gaps < rhs.score.gaps
            }
            if lhs.score.start != rhs.score.start {
                return lhs.score.start < rhs.score.start
            }
            if lhs.score.nameLength != rhs.score.nameLength {
                return lhs.score.nameLength < rhs.score.nameLength
            }
            return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name)
                == .orderedAscending
        }?.index
    }

    static func score(query rawQuery: String, appName rawName: String) -> AppSearchScore? {
        let query = searchableQuery(from: rawQuery)
        let name = normalize(rawName)
        guard query.count >= 2, !name.isEmpty else { return nil }

        let queryCharacters = Array(query)
        let nameCharacters = Array(name)
        let nameLength = nameCharacters.count

        if name == query {
            return AppSearchScore(tier: 0, gaps: 0, start: 0, nameLength: nameLength)
        }

        let wordStarts = nameCharacters.indices.filter { index in
            isWordCharacter(nameCharacters[index]) &&
                (index == nameCharacters.startIndex ||
                    !isWordCharacter(nameCharacters[nameCharacters.index(before: index)]))
        }

        if let start = wordStarts.first(where: {
            word(at: $0, in: nameCharacters) == queryCharacters
        }) {
            return AppSearchScore(tier: 1, gaps: 0, start: start, nameLength: nameLength)
        }

        if name.hasPrefix(query) {
            return AppSearchScore(tier: 2, gaps: 0, start: 0, nameLength: nameLength)
        }

        if let start = wordStarts.first(where: {
            starts(with: queryCharacters, at: $0, in: nameCharacters)
        }) {
            return AppSearchScore(tier: 3, gaps: 0, start: start, nameLength: nameLength)
        }

        if let range = name.range(of: query) {
            let start = name.distance(from: name.startIndex, to: range.lowerBound)
            return AppSearchScore(tier: 4, gaps: 0, start: start, nameLength: nameLength)
        }

        guard queryCharacters.count >= 3,
              let positions = subsequencePositions(
                query: queryCharacters,
                in: nameCharacters
              ),
              let first = positions.first,
              let last = positions.last else { return nil }

        let span = last - first + 1
        let gaps = span - queryCharacters.count
        guard span <= max(queryCharacters.count * 2, queryCharacters.count + 3) else {
            return nil
        }

        return AppSearchScore(tier: 5, gaps: gaps, start: first, nameLength: nameLength)
    }

    private static func searchableQuery(from rawQuery: String) -> String {
        let query = normalize(rawQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openPrefix = "open "
        guard query.hasPrefix(openPrefix) else { return query }
        return String(query.dropFirst(openPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale.current
        )
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func word(
        at start: Int,
        in characters: [Character]
    ) -> [Character] {
        Array(characters[start...].prefix(while: isWordCharacter))
    }

    private static func starts(
        with query: [Character],
        at start: Int,
        in characters: [Character]
    ) -> Bool {
        guard start + query.count <= characters.count else { return false }
        return Array(characters[start..<(start + query.count)]) == query
    }

    private static func subsequencePositions(
        query: [Character],
        in name: [Character]
    ) -> [Int]? {
        var positions: [Int] = []
        var cursor = 0

        for character in query {
            while cursor < name.count, name[cursor] != character {
                cursor += 1
            }
            guard cursor < name.count else { return nil }
            positions.append(cursor)
            cursor += 1
        }
        return positions
    }
}
