//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import SiftMCP
import Testing

/// Covers the last check before a denial goes out: advice naming a symbol stands only when an index this machine knows could answer for it.
///
/// The class of wrong advice this closes is the grep for text the index does not record — `where SubagentStart` against a name that lives only in string literals answers "no symbol named", and every ignored wrong denial burns the credibility the next correct one spends.
@Suite(.temporaryDirectories, .hermeticIndexes)
struct AdvisableNameTests {
    private static func indexed(declaring type: String = "Alpha", extending extended: String? = nil) async throws -> URL {
        let root = try MCPTestRepo.make(declaring: type, extending: extended)
        let registryFile = try TemporaryDirectory.make("roots")
            .appendingPathComponent("roots.json")
        try await SiftEngine(directory: root, registry: RootsRegistry(fileURL: registryFile)).ensureFresh()
        return root
    }

    @Test
    func aDeclaredNameIsAnswerable() async throws {
        let root = try await Self.indexed()

        #expect(AdvisableName.couldAnswer("Alpha", from: root.path, siblingRoots: []))
        // Functions are stored labeled (`go()`), and the probe must match them from the bare name.
        #expect(AdvisableName.couldAnswer("go", from: root.path, siblingRoots: []))
    }

    /// The defect itself: a name that appears in no declaration — a string literal, a comment word — is not something `where` can answer, so it earns no denial.
    @Test
    func anUndeclaredNameIsNot() async throws {
        let root = try await Self.indexed()

        #expect(!AdvisableName.couldAnswer("SubagentStart", from: root.path, siblingRoots: []))
    }

    /// A repo that only *extends* a framework type declares nothing by that name, yet `where` still answers about it — the extensions themselves — so the nudge stands.
    @Test
    func anExtendedNameIsAnswerable() async throws {
        let root = try await Self.indexed(declaring: "Beta", extending: "Color")

        #expect(AdvisableName.couldAnswer("Color", from: root.path, siblingRoots: []))
    }

    /// An unindexed repository stays advisable — the first query indexes it, so absence of an index is not absence of the name.
    @Test
    func anUnindexedRepositoryStaysAnswerable() throws {
        let root = try MCPTestRepo.make()

        #expect(AdvisableName.couldAnswer("Anything", from: root.path, siblingRoots: []))
    }

    /// Outside any repository there is nothing to consult, and silence would be guessing.
    @Test
    func outsideAnyRepositoryStaysAnswerable() throws {
        let loose = try TemporaryDirectory.make("loose")

        #expect(AdvisableName.couldAnswer("Anything", from: loose.path, siblingRoots: []))
        #expect(AdvisableName.couldAnswer("Anything", from: nil, siblingRoots: []))
    }

    /// A name declared in a registered sibling keeps its nudge — `where` answers it with the cross-root pointer.
    @Test
    func aSiblingDeclarationKeepsTheNudge() async throws {
        let declaring = try await Self.indexed(declaring: "Kernel")
        let local = try await Self.indexed(declaring: "Beta")

        #expect(AdvisableName.couldAnswer("Kernel", from: local.path, siblingRoots: [declaring.path]))
        #expect(!AdvisableName.couldAnswer("Gamma", from: local.path, siblingRoots: [declaring.path]))
    }

    /// The hook wiring: a classified lookup whose symbol no index declares is dropped before the ledger ever sees it, and the drop is recorded — a gate nobody can see firing is a rate nobody can question.
    ///
    /// The fallback the advisor builds for a word that is not a member of the file's type is judged here too, on the word the caller searched for: `digest Alpha` cannot say whether a file mentions `QzxNeverDeclared`, so falling back to it is not a reason to deny. A word some index does declare keeps the fallback, which is what that file's shape answers.
    @Test
    func theHookDropsADenialNoIndexCanStandBehindAndRecordsTheDrop() async throws {
        let root = try await Self.indexed(declaring: "Alpha", extending: "Color")
        let logFile = try TemporaryDirectory.make("suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let suppressions = SuppressionLog(fileURL: logFile)
        let payload: (String) -> [String: Any] = { pattern in
            [
                "tool_name": "Bash",
                "tool_input": ["command": "grep -n \"\(pattern)\" \(root.path)/Sources/App/Alpha.swift"],
            ]
        }

        #expect(PreToolUseCommand.lookup(
            command: nil, payload: payload("QzxNeverDeclared"), in: root.path, noting: suppressions
        ) == nil)
        let kept = PreToolUseCommand.lookup(
            command: nil, payload: payload("func go"), in: root.path, noting: suppressions
        )
        #expect(kept?.suggestion.call == "digest Alpha.go")
        // `spin` is declared on another type in the same repository, so the index can answer for the name —
        // but not as a member of `Alpha`, and the type-level digest is what is actually there.
        let fallback = PreToolUseCommand.lookup(
            command: nil, payload: payload("spin"), in: root.path, noting: suppressions
        )
        #expect(fallback?.suggestion.call == "digest Alpha")
        let recorded = try String(contentsOf: logFile, encoding: .utf8)
        #expect(recorded.contains("QzxNeverDeclared"))
        // The two kept denials are not suppressions, so exactly one line stands.
        #expect(recorded.split(separator: "\n").count == 1)
    }

    /// A `Type.member` offer is judged by type and member together, at the level the hook runs at: the index holds the member, so the offer is delivered naming it.
    ///
    /// Asked as the dotted string instead, the probe behind the gate compares a symbol's own name — which never holds a dot — and every member offer the advisor builds is thrown away against a spelling no index could record. Pinned through `PreToolUseCommand.lookup` against a real index rather than through the advisor, because the advisor is below the gate: a suggestion built correctly and then suppressed is no offer at all.
    @Test
    func theHookDeliversAMemberOfferTheIndexHolds() async throws {
        let root = try await Self.indexed()
        let logFile = try TemporaryDirectory.make("suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let suppressions = SuppressionLog(fileURL: logFile)
        let payload: (String) -> [String: Any] = { pattern in
            [
                "tool_name": "Bash",
                "tool_input": ["command": "grep -rn \"\(pattern)\" \(root.path)/Sources"],
            ]
        }

        let held = PreToolUseCommand.lookup(
            command: nil, payload: payload("Alpha\\.go"), in: root.path, noting: suppressions
        )
        #expect(held?.suggestion.call == "where Alpha.go")
        // A member the index does not hold is not offered as one; the type it was written under is real, and
        // `where` for it is the call that stands.
        let type = PreToolUseCommand.lookup(
            command: nil, payload: payload("Alpha\\.QzxNeverDeclared"), in: root.path, noting: suppressions
        )
        #expect(type?.suggestion.call == "where Alpha")
    }

    /// The same question through the search tool gets the same answer: a word that is not a member of the file's type is checked against the index on both surfaces, so which one a caller reaches for cannot change the verdict.
    ///
    /// Without the check on this side the `Grep` spelling offers `digest Alpha.QzxNeverDeclared` — a member of nothing — and the shell spelling offers the type's digest, which is the detour the advisors exist not to teach.
    @Test
    func bothSearchSurfacesJudgeAMemberOfferAlike() async throws {
        let root = try await Self.indexed(declaring: "Alpha", extending: "Color")
        let logFile = try TemporaryDirectory.make("suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let suppressions = SuppressionLog(fileURL: logFile)
        let file = "\(root.path)/Sources/App/Alpha.swift"
        let call: ([String: Any]) -> String? = { payload in
            PreToolUseCommand.lookup(
                command: nil, payload: payload, in: root.path, noting: suppressions
            )?.suggestion.call
        }

        // A name the index declares elsewhere: both surfaces fall back to the type's digest.
        let shell = call(["tool_name": "Bash", "tool_input": ["command": "grep -n \"spin\" \(file)"]])
        let tool = call(["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": "spin", "path": file]])

        #expect(shell == "digest Alpha")
        #expect(tool == shell)
        // A word no index declares at all: both surfaces stay silent, on the same judgement.
        #expect(call(["tool_name": "Bash", "tool_input": ["command": "grep -n \"QzxNeverDeclared\" \(file)"]]) == nil)
        #expect(call(["tool_name": "Grep", "tool_input": ["pattern": "QzxNeverDeclared", "path": file]]) == nil)
    }

    /// A name no index declares is not the same claim as a name asked of no index, and the symbol gate keeps its denial where the second is what happened: `couldAnswer` answering `false` because there is nothing to ask must never read as "nothing declares this".
    ///
    /// The tree judgement beside it is stated rather than read off the fixture, because the two rules disagree about this repository on purpose and only one of them is under test here: an unindexed repository draws no nudge at all (``SiftMCP/RepositoryIndex``), which would take this command for a reason that says nothing about the gate this pins.
    @Test
    func theSymbolGateKeepsADenialWhereNoIndexExistsYet() throws {
        let root = try MCPTestRepo.make()
        let logFile = try TemporaryDirectory.make("suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "grep -n \"QzxNeverDeclared\" \(root.path)/Sources/App/Alpha.swift"],
        ]

        #expect(PreToolUseCommand.lookup(
            command: nil, payload: payload, in: root.path, noting: SuppressionLog(fileURL: logFile),
            couldAnswer: { AdvisableName.couldAnswer($0, from: $1) }
        ) != nil)
    }

    /// A sweep of a tree for an alternation of names reaches the `where`-per-name offer, and reaches it through the real predicate: the names are read out of the pattern and checked against an index that holds them, and the offer is made only where every one of them is declared.
    ///
    /// **Pinned against a real index and a real tree because a stubbed `couldAnswer` cannot see what dropped this.** The classifier read "is there Swift here at all" off the one-symbol reading, which stops at a `|`, so a tree-wide `grep -rn "Alpha|Color" Sources` was no lookup at all — nothing built, nothing withheld, nothing logged — while the same sweep written `--include=*.swift` was refused with one `where` per name. The pattern is identical in both; all that differed was whether the Swift-ness was in the arguments or had to be probed off the filesystem, which is not a difference a caller chooses for a reason (`PatternReading.namesOnly(_:)`). The unit fixtures for the alternation shapes all name a `.swift` path or a Swift filter, so none of them crosses the probe this exercises.
    @Test
    func aTreeSweepForSeveralNamesIsOfferedOneWherePerNameOnlyWhenEveryOneIsDeclared() async throws {
        let root = try await Self.indexed(declaring: "Alpha", extending: "Color")
        let logFile = try TemporaryDirectory.make("suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let suppressions = SuppressionLog(fileURL: logFile)
        let sweep: (String) -> String? = { pattern in
            PreToolUseCommand.lookup(
                command: "grep -rn \"\(pattern)\" \(root.path)/Sources",
                payload: [:],
                in: root.path,
                noting: suppressions
            )?.suggestion.call
        }

        #expect(sweep("Alpha|Color") == "where Alpha\nwhere Color")
        // The same sweep with its Swift-ness written in the arguments has always been offered this; the two
        // spellings are one ask and cannot answer differently.
        #expect(sweep("Alpha|Color") == PreToolUseCommand.lookup(
            command: "grep -rn \"Alpha|Color\" \(root.path)/Sources --include=*.swift",
            payload: [:],
            in: root.path,
            noting: suppressions
        )?.suggestion.call)
        // Every name has to be declared for the offer to be made: a `where` for the rest answers "no symbol
        // named", and one covering fewer names than the ask answers a question nobody put.
        #expect(sweep("Alpha|QzxNeverDeclared") == nil)
        // None declared stays withheld, which is the widening's own limit — the classification reaching
        // further cannot make the hook say more than the index can stand behind.
        // Both names invented rather than placeholders: a placeholder this repository's own vocabulary uses
        // may be declared in a sibling the registry knows, and `couldAnswer` asks those too.
        #expect(sweep("QzxNeverDeclared|QzxAlsoNeverDeclared") == nil)
        // A pattern with no name in any branch is no lookup here either, probe or no probe.
        #expect(sweep(#"0\.1\.0\|2026-09"#) == nil)
        #expect(try String(contentsOf: logFile, encoding: .utf8).contains("unknownName"))
    }

    /// A sweep of a tree for a *shape* — a declaration's own form rather than a name — reaches the `search` that asks it, whether the sweep's Swift-ness is written in its arguments or has to be probed off the filesystem.
    ///
    /// **The half of that invariant a name-only gate leaves open.** `grep -rn "final class" Sources` was let through as prose while `grep -rn "final class" Sources --include=*.swift` beside it was refused with `search kind:class modifier:final` — the same pattern, differing only in where the Swift-ness was provable from, which is not a difference a caller chooses for a reason. And a shape query is the sweep `search` answers best, since a declaration's form is the thing `grep` cannot express.
    ///
    /// **Against a real index and a real tree because the probe is what the gap lived behind.** The unit fixtures for every shape name a `.swift` path or a Swift filter, so none of them crosses it.
    ///
    /// The last assertion is the bar, and it is where a shape differs from a name. A name no index declares is withheld downstream (`AdvisableName`); nothing withholds a shape, because `search kind:class modifier:final` is always answerable. So the bar sits in the classification: a shape must spell Swift's own declaration vocabulary, and a pattern that reads as only a fragment of a name — a wildcard over a token, which is what prose is made of — stays out.
    @Test
    func aTreeSweepForAShapeIsOfferedTheSearchThatAsksIt() async throws {
        let root = try await Self.indexed()
        let logFile = try TemporaryDirectory.make("shape-suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let suppressions = SuppressionLog(fileURL: logFile)
        let offer: (String) -> String? = { command in
            PreToolUseCommand.lookup(command: command, payload: [:], in: root.path, noting: suppressions)?
                .suggestion.call
        }
        let sweep: (String) -> String? = { offer("grep -rn \"\($0)\" \(root.path)/Sources") }
        let marked: (String) -> String? = { offer("grep -rn \"\($0)\" \(root.path)/Sources --include=*.swift") }

        #expect(sweep("final class") == "search kind:class modifier:final")
        #expect(sweep("@Test func") == "search attr:Test kind:func")
        // The two spellings of one sweep are one ask, for a shape as for a name.
        #expect(sweep("final class") == marked("final class"))
        #expect(sweep("@Test func") == marked("@Test func"))
        // A shape that is only a `name:` fragment is no evidence of Swift off the pattern alone — marked, it
        // is still the offer it always was.
        #expect(sweep("T[0-9]{3}") == nil)
        #expect(marked("T[0-9]{3}") == "search name:T")
    }

    /// A comma list of names is the same sweep however its Swift-ness is provable, and what it is is *text*.
    ///
    /// **The asymmetry, closed by narrowing the reading rather than widening the classifier.** `grep -rn "Alpha|Color" Sources` is refused with one `where` per name, and `grep -rn "Alpha, Color" Sources` beside it drew nothing at all — while the same comma sweep written `--include=*.swift` was refused with both names. Two spellings of one sweep answering differently is the thing the invariant above forbids.
    ///
    /// It is closed downwards because a comma list is not the ask an alternation is. `A|B` genuinely looks for either name, and `where A` with `where B` is that pair of questions; `A, B` is a literal adjacency on one line, which no index call answers — `where` for each name answers about each wherever it stands, which is not what was asked. And nothing writes it: over 10,000 real search segments from this machine's transcripts, the comma spelling appears once, in a line of prose about this very shape quoted into a session.
    @Test
    func aTreeSweepForACommaListIsTextInBothItsSpellings() async throws {
        let root = try await Self.indexed(declaring: "Alpha", extending: "Color")
        let logFile = try TemporaryDirectory.make("comma-suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let suppressions = SuppressionLog(fileURL: logFile)
        let offer: (String) -> String? = { command in
            PreToolUseCommand.lookup(command: command, payload: [:], in: root.path, noting: suppressions)?
                .suggestion.call
        }
        let sweep: (String) -> String? = { offer("grep -rn \"\($0)\" \(root.path)/Sources") }
        let marked: (String) -> String? = { offer("grep -rn \"\($0)\" \(root.path)/Sources --include=*.swift") }

        #expect(sweep("Alpha, Color") == nil)
        #expect(marked("Alpha, Color") == nil)
        // The alternation is a different ask and keeps its offer, in both spellings.
        #expect(sweep("Alpha|Color") == "where Alpha\nwhere Color")
        #expect(marked("Alpha|Color") == "where Alpha\nwhere Color")
    }

    /// The member memo agrees with the unmemoised check it stands in for — a hit, a miss, a member of a type no index declares at all, and a repeated question, which is the shape a memo could get wrong by answering the second ask from a stale cache rather than the same rule.
    @Test
    func theMemberMemoAgreesWithTheUnmemoisedCheck() async throws {
        let root = try await Self.indexed(declaring: "Alpha", extending: "Color")
        let memoised = AdvisableName.memoisedMember()

        // A hit: `go` is declared on `Alpha`.
        #expect(memoised("go", "Alpha", root.path) == AdvisableName.couldAnswer(member: "go", of: "Alpha", from: root.path))
        #expect(memoised("go", "Alpha", root.path))

        // A miss: `spin` is declared on another type in the same repository, so the index answers for the
        // name but not as a member of `Alpha`.
        #expect(memoised("spin", "Alpha", root.path) == AdvisableName.couldAnswer(member: "spin", of: "Alpha", from: root.path))
        #expect(!memoised("spin", "Alpha", root.path))

        // A member of a type the index declares nowhere at all.
        #expect(
            memoised("go", "QzxNeverDeclared", root.path)
                == AdvisableName.couldAnswer(member: "go", of: "QzxNeverDeclared", from: root.path)
        )
        #expect(!memoised("go", "QzxNeverDeclared", root.path))

        // Repeated: the second ask of a question already answered still agrees with a fresh, unmemoised check.
        #expect(memoised("go", "Alpha", root.path) == AdvisableName.couldAnswer(member: "go", of: "Alpha", from: root.path))
    }

    /// A build abandoned past the in-place budget leaves a store that opens at the current schema with nothing indexed into it — 0 files, no `indexed_head` — exactly what `IndexStore`'s own init leaves before anything has been indexed.
    ///
    /// That store must count as no index at all, or the gate reads its silence as "declared nowhere" and the hook goes quiet for the rest of the tree's life: the defect this pins.
    @Test
    func theHookDeniesAReadInAnUnindexedRepositoryAndIndexesItOnDemand() throws {
        let root = try MCPTestRepo.make(declaring: "Zorblatt")
        _ = try IndexStore(databasePath: SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path)

        #expect(AdvisableName.couldAnswer("Zorblatt", from: root.path, siblingRoots: []))

        let logFile = try TemporaryDirectory.make("suppressions")
            .appendingPathComponent("suppressions.jsonl")
        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "grep -rn Zorblatt \(root.appendingPathComponent("Sources").path)"],
        ]

        let lookup = PreToolUseCommand.lookup(
            command: nil, payload: payload, in: root.path, noting: SuppressionLog(fileURL: logFile),
            couldAnswer: { AdvisableName.couldAnswer($0, from: $1) }
        )

        #expect(lookup?.suggestion.call == "where Zorblatt")
    }
}
