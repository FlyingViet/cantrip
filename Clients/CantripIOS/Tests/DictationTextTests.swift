import XCTest
@testable import Hermes

/// Made-up names only: this repository is public.
final class DictationTextTests: XCTestCase {
    private let lexicon = FakeLexicon()

    private func rules(_ terms: [DictationTerm], corrections: [DictationCorrection] = []) -> [DictationText.Rule] {
        DictationVocabulary.rules(DictationVocabulary.assemble(terms, lexicon: lexicon), corrections: corrections)
    }

    func testFillersStuttersAndTimesAreCleanedUp() {
        let text = "Um, so the the backup failed again, uh, around 4.15 this morning"
        XCTAssertEqual(
            DictationText.finalize(text, rules: []),
            "So the backup failed again, around 4:15 this morning."
        )
        XCTAssertEqual(DictationText.finalize("i think i'm done", rules: []), "I think I'm done.")
        XCTAssertEqual(DictationText.removeDisfluencies("We shipped it, um."), "We shipped it.")
        XCTAssertEqual(DictationText.removeDisfluencies("She's in the ER tonight."), "She's in the ER tonight.")
    }

    func testNumberFormatsOnlyChangeClearTimesAndMoney() {
        XCTAssertEqual(DictationText.fixNumberFormats("a call at 9.30 and lunch"), "a call at 9:30 and lunch")
        XCTAssertEqual(DictationText.fixNumberFormats("ship version 4.15 today"), "ship version 4.15 today")
        XCTAssertEqual(
            DictationText.fixNumberFormats("Bump it to 1.25 and move from 3.45 to 4.10"),
            "Bump it to 1.25 and move from 3.45 to 4.10"
        )
        XCTAssertEqual(DictationText.fixNumberFormats("it costs about 4.50 dollars"), "it costs about 4.50 dollars")
        XCTAssertEqual(DictationText.fixNumberFormats("around 04:15 today"), "around 4:15 today")
        XCTAssertEqual(DictationText.fixNumberFormats("I spent $1200 and $45"), "I spent $1,200 and $45")
    }

    func testGuardedNumbersKeepsWordsThatAreNotQuantities() {
        let normalize: (String) -> String = { text in
            text.replacingOccurrences(of: "another one", with: "another 1")
                .replacingOccurrences(of: "First,", with: "1st,")
                .replacingOccurrences(of: "three hundred forty dollars", with: "$340")
                .replacingOccurrences(of: "fifteenth, twenty twenty six", with: "15, 2026")
                .replacingOccurrences(of: "nine thirty and a", with: "39")
                .replacingOccurrences(of: "odalys dot quill at example dot com", with: "odalys.quill@example.com")
        }
        XCTAssertEqual(
            DictationText.guardedNumbers("Open one tab and another one for docs.", normalize: normalize),
            "Open one tab and another one for docs."
        )
        XCTAssertEqual(DictationText.guardedNumbers("First, update it.", normalize: normalize), "First, update it.")
        XCTAssertEqual(
            DictationText.guardedNumbers("File the report for three hundred forty dollars.", normalize: normalize),
            "File the report for $340."
        )
        XCTAssertEqual(
            DictationText.guardedNumbers("It expires on November fifteenth, twenty twenty six.", normalize: normalize),
            "It expires on November 15, 2026."
        )
        XCTAssertEqual(
            DictationText.guardedNumbers("A screen at nine thirty and a recruiter call.", normalize: normalize),
            "A screen at nine thirty and a recruiter call.",
            "A conversion that swallows ordinary words is rejected"
        )
        XCTAssertEqual(
            DictationText.guardedNumbers("Write to odalys dot quill at example dot com today.", normalize: normalize),
            "Write to odalys.quill@example.com today."
        )
    }

    func testVocabularyRulesRestoreProjectAndPersonSpelling() {
        let terms = [
            DictationTerm(text: "QuillPad", kind: .project, weight: 0.9),
            DictationTerm(text: "Zephyrly", kind: .project, weight: 0.9),
            DictationTerm(text: "Orbit Lane", kind: .company, weight: 0.8),
            DictationTerm(text: "Odalys Brennecke", kind: .person, weight: 0.8),
            DictationTerm(text: "Harbor", kind: .company, weight: 0.8),
        ]
        XCTAssertEqual(
            DictationText.applyRules(rules(terms), to: "open quill pad, then zephyr ly with orbit lane and odalys brennecke"),
            "open QuillPad, then Zephyrly with Orbit Lane and Odalys Brennecke"
        )
        XCTAssertEqual(
            DictationText.applyRules(rules(terms), to: "the harbor is calm; quill. pad"),
            "the harbor is calm; quill. pad",
            "Ordinary words and phrases split by punctuation keep their spelling"
        )
    }

    func testConfidentLearnedCorrectionsApplyOnlyToNonWords() {
        let now = Date()
        let corrections = [
            DictationCorrection(heard: "Zefferly", corrected: "Zephyrly", count: 2, lastUsed: now, heardIsWord: false),
            DictationCorrection(heard: "flexible", corrected: "Plexo", count: 5, lastUsed: now, heardIsWord: true),
            DictationCorrection(heard: "Kwilpad", corrected: "QuillPad", count: 1, lastUsed: now, heardIsWord: false),
        ]
        XCTAssertEqual(
            DictationText.applyRules(rules([], corrections: corrections), to: "ask Zefferly for a flexible Kwilpad plan"),
            "ask Zephyrly for a flexible Kwilpad plan"
        )
    }

    func testBoostRepairRestoresSwallowedWordsAndPunctuation() {
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Remind me to text Odalys Brennecke about dinner.",
                boosted: "Remind me to Odalys Brennecke about dinner."
            ),
            "Remind me to text Odalys Brennecke about dinner."
        )
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Second, restart flexo. Third, rerun it.",
                boosted: "Second, restart Plexo Third, rerun it."
            ),
            "Second, restart Plexo. Third, rerun it."
        )
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Email OdalysBrenecka at odalys about it",
                boosted: "Email Odalys Brennecke odalys about it"
            ),
            "Email Odalys Brennecke at odalys about it"
        )
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Send Ferdinand a kovalchik the report.",
                boosted: "Send Ferdinand Kowalczyk the report."
            ),
            "Send Ferdinand Kowalczyk the report."
        )
    }

    func testSelfCorrectionsKeepOnlyTheCorrection() {
        XCTAssertEqual(DictationText.applySelfCorrections("Let's meet at 2, actually 3, with Odalys."), "Let's meet at 3, with Odalys.")
        XCTAssertEqual(DictationText.applySelfCorrections("Ship it Tuesday, no, Wednesday."), "Ship it Wednesday.")
        XCTAssertEqual(DictationText.applySelfCorrections("call at two I mean at three"), "call at three")
        XCTAssertEqual(DictationText.applySelfCorrections("At 3 no one showed up."), "At 3 no one showed up.")
        XCTAssertEqual(
            DictationText.applySelfCorrections("Give me a second, sorry, one more thing."),
            "Give me a second, sorry, one more thing."
        )
        XCTAssertEqual(DictationText.applySelfCorrections("Ship it Tuesday no Wednesday."), "Ship it Tuesday no Wednesday.")
        XCTAssertEqual(
            DictationText.applySelfCorrections("Add 2 actually useful tests."),
            "Add 2 actually useful tests.",
            "A cue between unrelated words is ordinary speech"
        )
    }

    func testBoostRepairRejectsLookalikeOrdinaryWords() {
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Did Harbor or Zephyrly reply about it?",
                boosted: "Did Harbor or Zephyrly Fireline about it?"
            ),
            "Did Harbor or Zephyrly reply about it?"
        )
        XCTAssertEqual(
            DictationText.repairBoost(original: "Send Ingrid Oakfur the report.", boosted: "Send Ingrid Okafor the report."),
            "Send Ingrid Okafor the report.",
            "A word heard as a name may be replaced even when it looks different"
        )
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Let's meet at 2, actually 3, with Odalys.",
                boosted: "Let's Orbit Lane Zephyrly, with Odalys."
            ),
            "Let's meet at 2, actually 3, with Odalys."
        )
        let terms = [["odalys", "brennecke"], ["quillpad"], ["orbit", "lane"]]
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Open a tab for Zephyrly and check the quill pad build",
                boosted: "Open a tab for Odalys Brennecke QuillPad build", terms: terms
            ),
            "Open a tab for Zephyrly and check the QuillPad build",
            "Neighbouring replacements are judged one at a time"
        )
        XCTAssertEqual(
            DictationText.repairBoost(
                original: "Meet with O'Dallis Brennanke about the launch.",
                boosted: "Meet with Odalys Brennecke Orbit Lane.", terms: terms
            ),
            "Meet with Odalys Brennecke about the launch."
        )
        XCTAssertEqual(
            DictationText.repairBoost(original: "Um, so the backup failed.", boosted: "Hermes so the backup failed."),
            "Um, so the backup failed."
        )
        XCTAssertEqual(
            DictationText.repairBoost(original: "ship the orbit lean build", boosted: "ship the Orbit Lane build", terms: [["orbit", "lane"]]),
            "ship the Orbit Lane build"
        )
    }

    func testCapitalizationKeepsListLines() {
        XCTAssertEqual(
            DictationText.fixCapitalization("Plan:\n1. update the node\n2. restart it"),
            "Plan:\n1. Update the node.\n2. Restart it"
        )
    }

    func testSpokenEnumerationsBecomeNumberedLists() {
        XCTAssertEqual(
            DictationText.formatLists("Plan for today. First, update the node. Second, restart Plexo. Third, rerun the tests."),
            "Plan for today.\n1. Update the node.\n2. Restart Plexo.\n3. Rerun the tests."
        )
        XCTAssertEqual(
            DictationText.formatLists("Here's the plan, first, update the node, second, restart Plexo, finally, rerun tests. Thanks"),
            "Here's the plan:\n1. Update the node\n2. Restart Plexo\n3. Rerun tests.\nThanks"
        )
        XCTAssertEqual(
            DictationText.formatLists("Wait a second, the first build failed."),
            "Wait a second, the first build failed."
        )
    }

    func testSegmentJoinLowercasesContinuations() {
        XCTAssertEqual(
            DictationText.joinSegments(["Open the dashboard", "And check the logs.", "Then Zephyrly."]),
            "Open the dashboard and check the logs. Then Zephyrly."
        )
        XCTAssertEqual(DictationText.joinSegments(["Ask", "I think"]), "Ask I think")
    }

    func testGuardrailsAcceptCleanupButRejectInventedContent() {
        let allowed = DictationVocabulary.allowedKeys([DictationTerm(text: "Plexo", kind: .project, weight: 1)])
        let original = "Let's meet at 2, actually 3, with Odalys about the flexo release."
        XCTAssertEqual(
            DictationText.evaluate(original: original, candidate: "Let's meet at 3 with Odalys about the Plexo release.", allowedKeys: allowed),
            .accepted
        )
        XCTAssertEqual(
            DictationText.evaluate(original: "Um so I think we should ship it today", candidate: "I think we should ship it today.", allowedKeys: []),
            .accepted
        )
        XCTAssertEqual(
            DictationText.evaluate(original: original, candidate: "Let's meet at 3 with Odalys about the release at the cafe downtown.", allowedKeys: allowed),
            .rejected("added “cafe”")
        )
        XCTAssertEqual(
            DictationText.evaluate(original: original, candidate: "Meet with Odalys.", allowedKeys: allowed),
            .rejected("changed 75% of words")
        )
        XCTAssertEqual(DictationText.evaluate(original: original, candidate: "  ", allowedKeys: allowed), .rejected("empty"))
        XCTAssertEqual(
            DictationText.evaluate(original: original, candidate: "Let's meet at 3, with Odalys about the Plexo.", allowedKeys: allowed),
            .rejected("swapped in “Plexo”")
        )
        XCTAssertEqual(
            DictationText.evaluate(original: original, candidate: "Let's meet at 3 actually 3, with Odalys about the flexo release.", allowedKeys: allowed),
            .rejected("repeated “3”")
        )
        XCTAssertEqual(
            DictationText.evaluate(original: "Email Odalys about the Cantrip Blanche plan.", candidate: "Email Odalys about the Cantrip plan.", allowedKeys: []),
            .rejected("removed “blanche”")
        )
    }

    func testModelEditsApplyOnlyWhereTheyMatch() {
        let edits = [
            DictationText.Edit(find: "2,", replace: "3"),
            DictationText.Edit(find: "2, actually 3", replace: "3"),
            DictationText.Edit(find: "flexo", replace: "Plexo"),
            DictationText.Edit(find: "not in the text", replace: "nope"),
        ]
        XCTAssertEqual(
            DictationText.applyEdits(edits, to: "Meet at 2, actually 3, about flexo."),
            "Meet at 3, about Plexo."
        )
    }

    func testCorrectionsBeforeSendingAreLearnedAsTerms() {
        XCTAssertEqual(
            DictationText.substitutions(
                dictated: "Ask zephyr lee about the quillpad build and dinner.",
                final: "Ask Zephyrly about the QuillPad build and lunch."
            ),
            [.init(heard: "zephyr lee", corrected: "Zephyrly"), .init(heard: "quillpad", corrected: "QuillPad")]
        )
        XCTAssertEqual(
            DictationText.substitutions(dictated: "the plan works", final: "The plan works"),
            []
        )
    }
}

final class DictationVocabularyTests: XCTestCase {
    private let lexicon = FakeLexicon()

    func testAssemblyMergesSourcesAndDropsJunk() {
        let terms = DictationVocabulary.assemble([
            DictationTerm(text: "Quillpad", kind: .other, weight: 0.4, sources: ["tab"]),
            DictationTerm(text: "QuillPad", kind: .project, weight: 0.4, sources: ["memory"]),
            DictationTerm(text: "quillpad.md", kind: .note, weight: 0.2, sources: ["memory"]),
            DictationTerm(text: "a", kind: .other, weight: 1),
            DictationTerm(text: "https://example.com/x", kind: .other, weight: 1),
            DictationTerm(text: "/Users/someone/file", kind: .other, weight: 1),
            DictationTerm(text: "12345", kind: .other, weight: 1),
            DictationTerm(text: "Odalys Brennecke", kind: .person, weight: 0.9, sources: ["contacts"]),
            DictationTerm(text: "Harbor", kind: .company, weight: 0.3, sources: ["tracker"]),
        ], lexicon: lexicon)
        XCTAssertEqual(terms.map(\.text), ["Odalys Brennecke", "QuillPad", "Harbor"])
        let quill = terms[1]
        XCTAssertEqual(quill.kind, .project)
        XCTAssertEqual(quill.sources, ["tab", "memory"])
        XCTAssertEqual(quill.aliases, ["Quill Pad"])
        XCTAssertTrue(quill.exactCase)
        XCTAssertFalse(terms[2].exactCase, "Dictionary words are left to boosting and context")
        XCTAssertTrue(terms[0].exactCase)
    }

    func testAssemblyCapsByWeight() {
        let many = (0..<50).map { DictationTerm(text: "Zork\($0)ville", kind: .other, weight: Double($0) / 50) }
        let capped = DictationVocabulary.assemble(many, lexicon: lexicon, cap: 10)
        XCTAssertEqual(capped.count, 10)
        XCTAssertEqual(capped.first?.text, "Zork49ville")
    }

    func testTitleCandidatesFindProjectNames() {
        XCTAssertEqual(DictationVocabulary.titleCandidates("Fix Orbit Lane login", lexicon: lexicon), ["Orbit Lane"])
        XCTAssertEqual(DictationVocabulary.titleCandidates("Zephyrly sync bug", lexicon: lexicon), ["Zephyrly"])
        XCTAssertEqual(DictationVocabulary.titleCandidates("QuillPad: release 2.1", lexicon: lexicon), ["QuillPad"])
        XCTAssertEqual(DictationVocabulary.titleCandidates("New tab", lexicon: lexicon), [])
    }

    func testRelevantTermsMatchWhatWasSaid() {
        let terms = [
            DictationTerm(text: "Zephyrly", kind: .project, weight: 0.5),
            DictationTerm(text: "QuillPad", kind: .project, weight: 0.9, aliases: ["Quill Pad"]),
            DictationTerm(text: "Odalys Brennecke", kind: .person, weight: 0.9),
        ]
        let relevant = DictationVocabulary.relevant(terms, to: "ask zephyr lee about it")
        XCTAssertEqual(relevant.map(\.text), ["Zephyrly"])
    }

    func testLearningCountsRepeatsAndRemembersOrdinaryWords() {
        let start = Date(timeIntervalSince1970: 0)
        var corrections = DictationVocabulary.record(
            [.init(heard: "flexo", corrected: "Plexo"), .init(heard: "Kwilpad", corrected: "QuillPad")],
            into: [], isWord: lexicon.isWord, now: start
        )
        corrections = DictationVocabulary.record(
            [.init(heard: "Kwilpad", corrected: "QuillPad")], into: corrections, isWord: lexicon.isWord, now: start
        )
        XCTAssertEqual(corrections.map(\.count), [1, 2])
        XCTAssertEqual(corrections.map(\.heardIsWord), [true, false])
        let terms = DictationVocabulary.terms(from: corrections)
        XCTAssertEqual(terms.map(\.text), ["Plexo", "QuillPad"])
        XCTAssertEqual(terms[1].aliases, ["Kwilpad"])
        let rules = DictationVocabulary.rules([], corrections: corrections)
        XCTAssertEqual(rules, [DictationText.Rule(keys: ["kwilpad"], replacement: ["QuillPad"])])
        XCTAssertEqual(terms[0].aliases, [], "An ordinary misheard word is not boosted as an alias")
    }

    func testLearnedWordsNeverBecomeGlobalReplacementsAfterOneFix() {
        let start = Date(timeIntervalSince1970: 0)
        let corrections = DictationVocabulary.record(
            DictationText.substitutions(dictated: "Ask mark and do not merge.", final: "Ask Marco and do NOT merge."),
            into: [], isWord: { ["mark", "not", "ask", "and", "do", "merge"].contains($0) }, now: start
        )
        XCTAssertEqual(corrections.map(\.corrected), ["Marco"], "Recasing an ordinary word is emphasis, not a term")
        let terms = DictationVocabulary.assemble(DictationVocabulary.terms(from: corrections), lexicon: lexicon)
        XCTAssertEqual(
            DictationText.applyRules(DictationVocabulary.rules(terms, corrections: corrections), to: "Mark it as a question mark."),
            "Mark it as a question mark."
        )
    }
}

struct FakeLexicon: DictationLexicon {
    private let words: Set<String> = [
        "fix", "orbit", "lane", "login", "sync", "bug", "release", "new", "tab", "harbor", "flexo",
        "the", "plan", "works", "build"
    ]

    func isWord(_ word: String) -> Bool { words.contains(word.lowercased()) }
}
