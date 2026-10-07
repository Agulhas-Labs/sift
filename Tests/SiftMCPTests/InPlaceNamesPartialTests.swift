//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A tree-wide alternation of a name beside prose, answered for the name with a line naming the prose it leaves to a search.
///
/// A suite of its own because `InPlaceNamesTests` holds the names shape without prose, and the subject here is the one difference: which branches the answer covers, and that it says so.
@Suite(.temporaryDirectories)
struct InPlaceNamesPartialTests {
    /// A package declaring `Depot` and `Gizmo` and using both, built with an index store so a `where` has callers to list.
    private static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "public struct Depot {\n    public init() {}\n}\n",
            "Sources/App/Gizmo.swift": "public struct Gizmo {\n    public init() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    var depot = Depot()\n    var second = Gizmo()\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// What the hook decides for `command` run in `root`, against the ledger, usage and suppression logs under `directory`.
    private static func outcome(_ command: String, in root: URL, records directory: URL) async throws -> PreToolUseCommand.Verdict? {
        let suppressions = SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl"))
        guard let lookup = PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Bash", "tool_input": ["command": command]],
            in: root.path,
            noting: suppressions,
            couldAnswer: { _, _ in true }
        ) else {
            return nil
        }
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
                payload: ["agent_id": "a1"],
                cwd: root.path,
                ledger: AdviceLedger(directory: directory.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl")),
                suppressions: suppressions,
                answerer: { match, serverGone, _ in
                    InPlaceAnswerer.answer(
                        match.call,
                        from: match.directory,
                        serverGone: serverGone,
                        wholeCommand: match.isWholeCommand,
                        timeBudget: InPlaceAnswerTests.roomy,
                        backoff: backoff
                    )
                }
            ).verdict
        }
    }

    /// The `rule` of every line the suppression log under `directory` holds, in order.
    private static func rules(under directory: URL) -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("suppressions.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return entry?["rule"] as? String
        }
    }

    /// The reading keeps each prose branch as written beside the names, and reads an alternation of prose alone as text.
    @Test
    func theReadingKeepsTheProseBesideTheNames() {
        #expect(SweepPattern.reading(of: #""Depot\|stale index""#) == .partial(names: ["Depot"], prose: ["stale index"]))
        #expect(SweepPattern.reading(of: "Depot|Gizmo|revisit this later") == .partial(names: ["Depot", "Gizmo"], prose: ["revisit this later"]))
        #expect(SweepPattern.reading(of: #"stale index\|revisit this later"#) == .text)
        #expect(SweepPattern.reading(of: #"Depot\|Gizmo"#) == .names(["Depot", "Gizmo"]))
    }

    /// Every branch with no name of its own is named in the caveat, not only a branch with a space in it — and where a declaration-opening branch (`final class`) rides beside real prose the whole alternation is withheld, as any prose did before this reading could narrow to a partial at all, rather than answered on the names with a caveat that could never say what the declaration branch was.
    @Test
    func everyUnnamedBranchIsInTheCaveatUnlessItOpensADeclaration() {
        #expect(SweepPattern.reading(of: #"SweepPattern\|stale index\|final class"#) == .text)
        #expect(
            SweepPattern.reading(of: #"SweepPattern\|--verdict\|stale index"#)
                == .partial(names: ["SweepPattern"], prose: ["--verdict", "stale index"])
        )
    }

    /// A prose branch is quoted in the caveat exactly as the caller wrote it, trimming only the whitespace and the parentheses that grouped the alternation — never the parentheses the branch's own text carried.
    @Test
    func theCaveatKeepsParenthesesTheBranchWasWrittenWith() {
        #expect(
            SweepPattern.reading(of: #"SweepPattern\|call it()"#)
                == .partial(names: ["SweepPattern"], prose: ["call it()"])
        )
    }

    /// The tree search carries the prose into its call, on both surfaces.
    @Test
    func theCallCarriesTheUncoveredBranches() {
        let shell = InPlaceShape.match(forShell: #"grep -rn "Depot\|stale index" Sources"#, in: "/repo")
        let tool = InPlaceShape.match(forSearchTool: "Grep", input: ["output_mode": "content", "pattern": "Depot|stale index", "path": "Sources"], in: "/repo")

        #expect(shell?.call == .symbols(names: ["Depot"], paths: ["Sources"], uncovered: ["stale index"]))
        #expect(tool?.call == .symbols(names: ["Depot"], paths: ["/repo/Sources"], uncovered: ["stale index"]))
    }

    /// The answer is the name's `where` with one line naming the prose it does not cover; its identical re-run goes through, and the answer is logged under its own rule.
    @Test
    func aNameBesideProseIsAnsweredWithTheCaveat() async throws {
        let root = try await Self.builtPackage()
        let command = #"grep -rn "Depot\|stale index" Sources"#

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))
        #expect(answered.calls.map(\.target) == ["Depot"])
        let answer = try #require(InPlaceAnswer.answer(inReason: answered.reason))
        #expect(answer.contains(#"This answer does not cover "stale index"; re-run the identical command to sweep for that."#))
        #expect(answer.contains("where Depot"))

        let directory = try TemporaryDirectory.make("partial-verdict")
        let first = try await Self.outcome(command, in: root, records: directory)
        #expect(first?.token == "in-place")
        #expect(first?.call == "where Depot")
        #expect(Self.rules(under: directory) == ["partialAlternation"])

        let rerun = try await Self.outcome(command, in: root, records: directory)
        #expect(rerun?.token == "allowed")
        #expect(rerun?.rule == "ledger")
    }

    /// An alternation of names alone is answered as it always was: no caveat, and nothing logged.
    @Test
    func anAlternationOfNamesAloneCarriesNoCaveat() async throws {
        let root = try await Self.builtPackage()
        let command = #"grep -rn "Depot\|Gizmo" Sources"#

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))
        #expect(answered.calls.map(\.target) == ["Depot", "Gizmo"])
        #expect(!answered.reason.contains("does not cover"))

        let directory = try TemporaryDirectory.make("names-verdict")
        #expect(try await Self.outcome(command, in: root, records: directory)?.token == "in-place")
        #expect(Self.rules(under: directory).isEmpty)
    }

    /// A sweep alternating prose with a lowercase word stands on the word as a name, as an answer naming the prose it leaves out reads it; listing files and folding case leave that answer nothing to stand in for, so the search runs.
    @Test
    func aSweepAlternatingProseWithALowercaseWordStandsOnTheWord() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let lookup = PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Bash", "tool_input": ["command": #"grep -rn -i "open question\|rounding" Sources --include=*.swift"#]],
            in: nil,
            noting: recording.log
        ) { _, _ in true }

        #expect(lookup?.suggestion.call == "where rounding")
        #expect(lookup?.inPlace == nil)
        #expect(recording.rules.isEmpty)
    }

    /// Prose alone, one named file and several named files are withheld as they were before the partial answer existed.
    @Test(arguments: [
        (#"grep -rn "stale index\|revisit this later" Sources --include=*.swift"#, "untargeted"),
        (#"grep -n "Depot\|stale index" Sources/App/Depot.swift"#, "phrase"),
        (#"grep -n "Depot\|stale index" Sources/App/Depot.swift Sources/App/Gizmo.swift"#, "severalNames"),
    ])
    func everyOtherShapeIsWithheldAsBefore(command: String, rule: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let lookup = PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Bash", "tool_input": ["command": command]],
            in: nil,
            noting: recording.log
        ) { _, _ in true }

        #expect(lookup == nil, "\(command)")
        #expect(recording.rules == [rule], "\(command)")
    }
}
