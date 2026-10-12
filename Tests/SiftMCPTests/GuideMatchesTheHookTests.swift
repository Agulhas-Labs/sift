//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// What the always-loaded rule tells an agent the hook will do with a command is what the hook does.
///
/// The rule is prose and the hook is code, and nothing else holds the two to one story. The drift this exists for: a bare `sed -n` named once as a search and once as a ranged read, when the hook tells the two apart by the script — a pattern address is a search, a numeric window is a read — and a "names nothing" exemption stated for every search when the hook grants it only to one with no single file behind it.
struct GuideMatchesTheHookTests {
    /// `Sift.md`, with line breaks folded so a sentence reads the same wherever the wrap fell.
    private static func ruleText() throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the repository root
        let rule = try String(contentsOf: root.appendingPathComponent("Sift.md"), encoding: .utf8)
        return rule.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The `refusals` topic `Sift.md` points a reader at for this exact accounting, with line breaks folded the same way.
    ///
    /// The size pass that split the rule moved this material behind `sift help refusals` rather than carrying it twice, so a claim this file checks lives in exactly one of the two — asserted against separately, never against the two joined into one string, which would let a claim missing from `Sift.md` hide behind the topic actually carrying it.
    private static func topicText(named name: String = "refusals") -> String {
        (HelpTopics.topic(named: name)?.body ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The `queries` topic, folded the same way: the reading-code habits the rule no longer repeats in full.
    private static func queriesText() -> String {
        topicText(named: "queries")
    }

    /// Every `sed -n` either source names carries the script that decides what it is — bare, it is both a search and a read.
    @Test
    func theRuleNeverNamesSedWithoutItsScript() throws {
        for text in try [Self.ruleText(), Self.topicText()] {
            let mentions = text.ranges(of: "sed -n")

            #expect(!mentions.isEmpty)
            for mention in mentions {
                #expect(text[mention.upperBound...].hasPrefix(" '"), "a bare `sed -n`: …\(text[mention.lowerBound...].prefix(60))")
            }
        }
        // These two exact phrasings live in the `refusals` topic, not in `Sift.md`, which only points a reader
        // there for the depth behind the one-line mention above.
        let topic = Self.topicText()

        #expect(topic.contains("`sed -n '/pattern/p'` on a `.swift` file"))
        #expect(topic.contains("`sed -n '120,160p'`, `head`, `tail` on one file"))
    }

    /// The topic says what a command let through means — no smaller answer — and that it is no advice to run it that way.
    ///
    /// The wording it replaces called a let-through one the hook "decided against", and an agent read the silence as permission for the whole read.
    @Test
    func theTopicDoesNotReadALetThroughAsApproval() {
        let topic = Self.topicText()

        #expect(topic.contains("A command the hook lets through is one it had no smaller answer for; that is not a recommendation to run it that way — `digest` and `where` are still the cheaper first call."))
        #expect(!topic.contains("decided against"))
    }

    /// The rule sends a location cited by an issue, a review or a build error to the digest that takes it, and puts the CLI in a Bash line already being made.
    @Test
    func theRuleSendsACitedLocationToAnAnchoredDigest() throws {
        let rule = try Self.ruleText()

        #expect(rule.contains("**A cited location is not already located**"))
        #expect(rule.contains("`digest File.swift:120` (or `:95-135`)"))
        // The same-line habit moved behind `sift help queries`.
        #expect(Self.queriesText().contains("`sift digest …` and `sift where …` go in the same line"))
    }

    /// The two scripts the rule gives are classified the way the rule files them: the pattern address a search, the numeric window a ranged read, advised as the read of its file.
    @Test
    func theRulesTwoSedScriptsAreClassifiedAsItSays() {
        let search = "sed -n '/pattern/p' Sources/App/View.swift"
        let window = "sed -n '120,160p' Sources/App/View.swift"

        #expect(ShellInspection.isSwiftLookup(search))
        #expect(ShellInspection.windowedReadPath(search, holdsSource: nil) == nil)
        #expect(ShellAdvice.suggestion(for: search, holdsSource: nil) != nil, "a pattern address is refused once")
        #expect(ShellInspection.windowedReadPath(window, holdsSource: nil) == "Sources/App/View.swift")
        #expect(ShellAdvice.suggestion(for: window, holdsSource: nil)?.call == "digest View", "a numeric window is the read of its file")
    }

    /// The exemption for a pattern that names nothing is stated as tree-wide, because that is the only search the hook grants it to.
    ///
    /// Lives in the `refusals` topic, not in `Sift.md` itself.
    @Test
    func theNamesNothingExemptionIsTreeWide() {
        #expect(Self.topicText().contains("a tree-wide search whose pattern names nothing at all"))
        #expect(TextSearch.describes(patternNamesNothing: true, file: nil, counting: false))
        #expect(!TextSearch.describes(patternNamesNothing: true, file: "Sources/App/View.swift", counting: false))
    }

    /// A ranged read of a file whose digest the context holds is never interrupted, and one an index call located is never counted — both halves, as the hook applies them.
    ///
    /// The sentence stating both lives in the `refusals` topic, not in `Sift.md` itself.
    @Test
    func aDigestedFilesRangedReadIsNeverInterruptedAndALocatedOneIsNeverCounted() {
        #expect(Self.topicText().contains(
            "A `Read` with `offset`/`limit` of a file an index call located is never counted against you, and a *ranged* read of a file this context has been handed the digest of is never interrupted, in either spelling"
        ))
        // Exercised rather than only asserted of the guide's prose: a ranged read of a `.swift` file a digest
        // located is scored `.guided`, never `.cold` — the actual counting `TranscriptScan` does, not only what
        // the sentence above promises it does. The hook never asks `ReadAdvice` for a ranged verdict on a
        // `.swift` path (it passes `ranged && !window`, and a `.swift` ranged read is always a `window`); that
        // side is pinned by `DigestedFilesTests` and `AlreadyDigestedReadTests` instead.
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("RecordDetailView", id: "d1", file: "Sources/App/RecordDetailView.swift") + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
            ]
        )
        #expect(lookups == [.indexed, .guided(file: "/repo/Sources/App/RecordDetailView.swift")])
    }

    /// The never-interrupted list names every shape the hook actually lets through: a fixed-string search for anything but a name, which the hook never refuses (``SearchToolAdvice/textSearchReason(tool:input:in:)``, ``TextSearch/Reason/fixedString``), and every one of a merge's three markers, not just the two that open and close it.
    ///
    /// The list lives in the `refusals` topic, which `Sift.md` points at; the short rule no longer repeats it.
    @Test
    func theNeverInterruptedListNamesFixedStringsAndEveryConflictMarker() {
        let text = Self.topicText()

        #expect(text.contains("a fixed-string search (`-F`, `fgrep`) for anything but a name"))
        #expect(text.contains("`<<<<<<<`"))
        #expect(text.contains("`=======`"))
        #expect(text.contains("`>>>>>>>`"))
    }

    /// The rule's hook paragraph states the lookup rule, the escape hatch and the rewrite; the topic it points at names what a lookup is.
    @Test
    func theRuleStatesTheLookupRuleAndTheTopicNamesWhatALookupIs() throws {
        let rule = try Self.ruleText()

        #expect(rule.contains("A lookup of Swift source is answered in place, or let through."))
        #expect(rule.contains("a re-run is never held against you"))
        #expect(rule.contains("A raw build or test is rewritten to `sift run --`, and the answer's first line says so"))
        #expect(Self.topicText().contains("a shell command, a Grep, a Glob, or a whole-file Read"))
    }

    /// The `refusals` topic says a build the user's own ask or deny rule matches runs as written, neither rewritten nor refused with its wrapping named.
    @Test
    func theRefusalsTopicNamesTheStandAsideForTheUsersRules() {
        let text = Self.topicText()

        #expect(text.contains("A build the user's own rules speak for runs as written."))
        #expect(text.contains("ask or deny rule"))
    }

    /// The `refusals` topic says a settings file the hook cannot read makes it stand aside from every build, as `WrappedRunPermission.hasUnreadableSettings` does.
    @Test
    func theRefusalsTopicNamesTheStandAsideForAnUnreadableSettingsFile() {
        #expect(Self.topicText().contains("So is every build while a settings file has something in it the hook cannot read as JSON"))
    }
}
