//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A search of named Swift files — one, several, or a glob of them — for a name is no in-place shape, since a name's `where` lists sites in files the search never named; a declaration grep of them keeps its own scoped shapes.
@Suite(.temporaryDirectories)
struct InPlaceNamedFilesTests {
    /// A package whose names have sites in some of its files and not in others, built with an index store so a `where` has references to list.
    private static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "public struct Depot {\n    public static let pending = 1\n    public init() {}\n    public func stock(in count: Int) -> Int { count }\n}\n",
            "Sources/App/Gizmo.swift": "public struct Gizmo {\n    public init() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    var depot = Depot()\n    var second = Gizmo()\n    var level = Depot.pending\n    func count() -> Int { depot.stock(in: level) }\n}\n",
            // One directory down, where a glob of `Sources/App` does not reach.
            "Sources/App/Shelf/Crate.swift": "struct Crate {\n    var gizmo = Gizmo()\n}\n",
            // Over the floor a read's digest stands above, and naming `Gizmo` on more lines than a `where` row lists.
            "Sources/App/Big.swift": Self.bigSource,
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Twelve methods of five lines each naming `Gizmo`: 86 lines, sixty of them `Gizmo` references.
    private static var bigSource: String {
        let methods = (1 ... 12).map { index in
            "    func f\(index)() -> [Gizmo] {\n" + ["a", "b", "c", "d"].map { "        let \($0) = Gizmo() \(WorthAnsweringFixture.comment)\n" }.joined()
                + "        return [a, b, c, d]\n    }\n"
        }
        return "struct Big {\n" + methods.joined() + "}\n"
    }

    /// The verdict the hook reaches on `command` run from `root`, on a thread of its own as the hook runs, and the usage log the answer was recorded to.
    private static func hookOutcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (verdict: PreToolUseCommand.Verdict, usage: URL) {
        let backoff = try InPlaceAnswerTests.backoff()
        let directory = try TemporaryDirectory.make("named-files-verdict").appendingPathComponent("named-files-verdict")
        let usage = directory.appendingPathComponent("usage.jsonl")
        let lookup = try #require(PreToolUseCommand.lookup(
            command: command,
            payload: [:],
            in: root.path,
            noting: SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl")),
            couldAnswer: { _, _ in true }
        ), sourceLocation: sourceLocation)
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
                payload: ["agent_id": "a1"],
                cwd: root.path,
                ledger: AdviceLedger(directory: directory.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: usage),
                suppressions: SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl")),
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
            )
        }
        return (outcome.verdict, usage)
    }

    /// Each shape that was once answered with a name's `where` is no candidate, over one file, several, or a glob of them.
    @Test
    func aNameGrepOfNamedFilesIsNoCandidate() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let shapes = [
            "grep -n \"pending\" Sources/App/Depot.swift",
            // A recursive search of one file recurses into nothing, and is that file's search.
            "grep -rn Alpha Sources/App/Alpha.swift",
            "grep -n \"Depot.pending\" Sources/App/Uses.swift | head -5",
            "grep -n Gizmo Sources/App/Gizmo.swift Sources/App/Uses.swift",
            "grep -rn \"Gizmo\" Sources/App/Shelf/*.swift",
            "grep -rn \"Depot(\" Sources/App/*.swift | head -5",
            "grep -rn \"Depot.pending\\|Depot\\.pending\" Sources/App/*.swift",
        ]
        for command in shapes {
            #expect(InPlaceShape.match(forShell: command, in: root.path) == nil, "\(command)")
        }
        // A declaration grep of one file is still that file's own proven shape, ahead of the names.
        #expect(InPlaceShape.match(forShell: "grep -n \"func stock\" Sources/App/Depot.swift", in: root.path)?.call.shape == .members)
        // Across several files or a glob a declaration's form is no name's question: a member's is the member
        // shape asked file by file, and any other keeps its refusal.
        #expect(InPlaceShape.match(forShell: "grep -n 'func go' Sources/App/Alpha.swift Sources/App/Gizmo.swift", in: root.path)?.call.shape == .members)
        #expect(InPlaceShape.match(forShell: "grep -n 'static\\|case ' Sources/App/Alpha.swift Sources/App/Gizmo.swift", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -rn 'Depot\\|static let' Sources/App/*.swift", in: root.path) == nil)
        // Context lines and a case-folded search leave the shape, as they leave the tree's.
        #expect(InPlaceShape.match(forShell: "grep -n -A3 Gizmo Sources/App/Uses.swift Sources/App/Gizmo.swift", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -in Gizmo Sources/App/*.swift", in: root.path) == nil)
        // A whole-line search (`-x`) leaves the shape too: it prints only a line that is the name alone, which
        // `where` cannot promise, as it leaves the tree's.
        #expect(InPlaceShape.match(forShell: "grep -n -x Gizmo Sources/App/Uses.swift", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -n --line-regexp Gizmo Sources/App/Uses.swift", in: root.path) == nil)
    }

    /// The measured shapes, metatype and self-expression spellings and a bracket class among them, are each let through rather than answered with the name's `where` — the last from a directory the command moves out of with a `cd`.
    @Test
    func aNameGrepOfNamedFilesIsLetThrough() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let shapes = [
            "grep -n \"pending\" Sources/App/Depot.swift",
            "grep -n \"Depot.pending\" Sources/App/Uses.swift | head -5",
            "grep -n Gizmo Sources/App/Gizmo.swift Sources/App/Uses.swift",
            "grep -rn \"Gizmo\" Sources/App/Shelf/*.swift",
            "grep -rn \"Depot(\" Sources/App/*.swift | head -5",
            "grep -rn \"Depot.pending\\|Depot\\.pending\" Sources/App/*.swift",
            "grep -n Self.pending Sources/App/Uses.swift",
            "grep -n Depot.Type Sources/App/Uses.swift",
            "grep -n Depot.self Sources/App/Uses.swift",
            "grep -n Gizmo Sources/App/[UV]ses.swift",
        ]
        let elsewhere = try TemporaryDirectory.make("elsewhere")
        let candidates = shapes.filter { InPlaceShape.match(forShell: $0, in: root.path) != nil }

        #expect(candidates.isEmpty)
        #expect(InPlaceShape.match(forShell: "cd \(root.path) && grep -n \"func stock(in\" Sources/App/Depot.swift", in: elsewhere.path) == nil)
    }

    /// A name with no site in the files named is no candidate either, whatever the glob matches, and neither is the same name searched where it has one.
    @Test
    func aNameAbsentFromTheNamedFilesIsWithheld() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let commands = [
            "grep -n Gizmo Sources/App/Depot.swift",
            "grep -rn Depot Sources/App/Shelf/*.swift",
            "grep -n Crate Sources/App/*.swift",
            "grep -n Crate Sources/App/Gizmo.swift Sources/App/Uses.swift",
            "grep -n Crate Sources/App/Shelf/*.swift",
        ]
        for command in commands {
            #expect(InPlaceShape.match(forShell: command, in: root.path) == nil, "\(command)")
        }
    }

    /// A name grep of a file a `where` row would list past its cap is no candidate, as every name grep of named files is.
    @Test
    func aFileListedPastTheRowCapIsNoCandidate() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")

        #expect(InPlaceShape.match(forShell: "grep -n Gizmo Sources/App/Big.swift", in: root.path) == nil)
    }

    /// A file that is not there is never answered, whether its directory is named as the filesystem spells it or through a symlink, and neither is one that is there.
    @Test
    func aFileThatIsNotThereIsNeverAnswered() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let link = try TemporaryDirectory.make("named-files-link").appendingPathComponent("probe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        for directory in [root.path, link.path] {
            for command in ["grep -rn Crate Sources/App/Nope.swift", "grep -n Crate Sources/App/Nope.swift", "grep -n Crate Sources/App/Shelf/Crate.swift"] {
                #expect(InPlaceShape.match(forShell: command, in: directory) == nil, "\(command) from \(directory)")
            }
        }
    }

    /// A glob in quotes reaches the search unexpanded, as a path no file has, so it is no names call — and the same glob bare, a set of named files, is none either.
    @Test
    func aQuotedGlobIsNotReadAsExpanded() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        for command in ["grep -n Gizmo 'Sources/App/*.swift'", "grep -rn Gizmo \"Sources/App/*.swift\""] {
            #expect(InPlaceShape.match(forShell: command, in: root.path) == nil, "\(command)")
        }

        #expect(InPlaceShape.match(forShell: "grep -n Gizmo Sources/App/*.swift", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -n 'Gizmo*' Sources/App/*.swift", in: root.path) == nil)
    }

    /// A brace expansion is text the shell would have split into several paths before the search ever ran — never one path, and no glob `fnmatch` reads either — so it draws no in-place answer at all, rather than the false `outsideSearch` a literal, never-there path would.
    @Test
    func aBraceExpansionIsNotReadAsAPathOrAGlob() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")

        #expect(InPlaceShape.match(forShell: "grep -n Gizmo Sources/App/{Uses,Gizmo}.swift", in: root.path) == nil)
    }

    /// Every withholding a search of named files draws stands in front of the answer: a string literal, a phrase, and an alternation of names confined to the files named.
    @Test
    func theNamedFilesWithholdingsStand() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let reasons: [(String, TextSearch.Reason)] = [
            ("grep -n '\"Depot' Sources/App/Depot.swift", .stringLiteral),
            ("grep -n \"Depot is built\" Sources/App/Depot.swift", .phrase),
            ("grep -n \"Depot\\|Gizmo\" Sources/App/Uses.swift", .severalNames),
            ("grep -n \"Depot\\|Gizmo\" Sources/App/*.swift", .severalNames),
        ]
        for (command, reason) in reasons {
            #expect(ShellAdvice.textSearchReason(command, holdsSource: nil, cwd: root.path) == reason, "\(command)")
        }
    }

    /// The hook lets a name grep of one file through rather than answer it with the name's `where`, which would list sites in files the grep never named.
    @Test
    func theHookLetsAOneFileNameGrepThrough() async throws {
        let root = try await Self.builtPackage()
        let command = "grep -n pending Sources/App/Depot.swift"
        let lookup = try #require(PreToolUseCommand.lookup(
            command: command,
            payload: [:],
            in: root.path,
            noting: SuppressionLog(fileURL: TemporaryDirectory.make("ignored").appendingPathComponent("ignored.jsonl")),
            couldAnswer: { _, _ in true }
        ))
        #expect(lookup.inPlace == nil)

        let verdict = try await Self.hookOutcome(command, in: root).verdict
        #expect(verdict.token == "allowed")
        #expect(verdict.call == nil)
    }

    /// A name grep of one file beside a read of it steps back to the ride-along it was on a line that is not a compound one, so the read keeps the digest it was answered with, and that digest locates the file for a window after it.
    @Test
    func aNameGrepBesideAReadLeavesTheReadItsDigest() async throws {
        let root = try await Self.builtPackage()
        let file = root.appendingPathComponent("Sources/App/Big.swift").path
        let commands = [
            "grep -n f12 Sources/App/Big.swift && sed -n 1,9999p Sources/App/Big.swift",
            "grep -n f12 Sources/App/Big.swift; cat Sources/App/Big.swift; ls",
        ]
        for command in commands {
            #expect(InPlaceShape.match(forShell: command, in: root.path)?.call.readPath == "Sources/App/Big.swift", "\(command)")
            let answered = try await InPlaceAnswerTests.answered(command, in: root)
            #expect(answered?.calls.map { "\($0.tool) \($0.target)" } == ["digest Sources/App/Big.swift"], "\(command)")
            let (verdict, usage) = try await Self.hookOutcome(command, in: root)
            #expect(verdict.token == "in-place", "\(command)")
            #expect(DigestedFiles(usageLog: usage).locates(file, session: "s1", agent: "a1"), "\(command)")
        }
        // On a line of nothing else the grep is still no lookup an answer stands in for: the read alone is.
        let compound = try #require(InPlaceShape.match(forShell: "grep -n f12 Sources/App/Big.swift; cat Sources/App/Big.swift", in: root.path))

        #expect(compound.calls.map(\.shape) == [.read])
        #expect(InPlaceShape.match(forShell: "grep -n f12 Sources/App/Big.swift", in: root.path) == nil)
    }

    /// A member path reads as that path whether its dot is escaped or bare behind a capitalised type, and two spellings of one name alternated are that one name.
    @Test
    func aMemberPathReadsAsThePath() {
        #expect(SweepPattern.reading(of: "Depot.pending") == .names(["Depot.pending"]))
        #expect(SweepPattern.reading(of: "Depot\\.pending") == .names(["Depot.pending"]))
        #expect(SweepPattern.reading(of: "Depot.pending\\|Depot\\.pending") == .names(["Depot.pending"]))
        #expect(SweepPattern.reading(of: "Depot(") == .names(["Depot"]))
        // Between lowercase words a bare dot is a regex's any-character, and no member path.
        #expect(SweepPattern.reading(of: "tab.about") != .names(["tab.about"]))
        #expect(SweepPattern.reading(of: "Self.pending") == .names(["pending"]))
        #expect(SweepPattern.reading(of: "Depot.Type") == .names(["Depot"]))
        #expect(SweepPattern.reading(of: "Depot.self") == .names(["Depot"]))
    }
}
