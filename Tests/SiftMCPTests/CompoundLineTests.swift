//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A line of two lookups or more, every other statement a literal `echo`/`printf` or a `cd`, answered as the whole command.
@Suite(.temporaryDirectories)
struct CompoundLineTests {
    /// What the shell matcher reads `command` as, run from `directory`.
    private static func match(_ command: String, in directory: String = "/repo") -> InPlaceShape.Match? {
        InPlaceShape.match(forShell: command, in: directory)
    }

    /// ``InPlaceAnswerer/answer(_:serverGone:timeBudget:sizeBudget:backoff:oversized:)`` for what `command` matches in `root`, on a thread of its own as the hook runs it.
    private static func outcome(
        _ command: String,
        in root: URL,
        sizeBudget: Int = InPlaceAnswer.sizeBudget,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), "\(command) is not a candidate", sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: sizeBudget, backoff: backoff)
        }
    }

    /// Whether `match` is a compound line's: the whole command, not one statement of it or several reads riding beside something else.
    private static func isCompound(_ match: InPlaceShape.Match?) -> Bool {
        guard let match else { return false }
        return match.isWholeCommand && match.lookups >= 2
    }

    /// A window and a member grep cut by `head`, side by side, are one match of two calls covering the whole line.
    @Test
    func twoLookupsOfDifferentShapesAreOneMatch() throws {
        let match = try #require(Self.match("sed -n 1,5p Sources/App/Alpha.swift; grep -n 'func load' -A8 Sources/App/Depot.swift | head -5"))

        #expect(match.calls.count == 2)
        #expect(match.calls[0].readPath == "Sources/App/Alpha.swift")
        #expect(match.windowed == [true, false])
        #expect(match.calls[1].shape == .members)
        #expect(match.isWholeCommand)
        #expect(match.lookups == 2)
        #expect(match.literals.isEmpty)
        #expect(!match.fallbackFollows)
    }

    /// A `cd` opening the line moves where every lookup resolves, and an `&&` behind a proven window needs nothing more.
    @Test
    func aMoveOpeningTheLineIsFollowed() throws {
        let root = try TemporaryDirectory.make("compound-cd")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let command = "cd Sources && sed -n 1,5p App/Alpha.swift && grep -n 'func load' App/Depot.swift"
        let match = try #require(Self.match(command, in: root.path))

        #expect(Self.isCompound(match))
        #expect(match.directory == root.appendingPathComponent("Sources").standardizedFileURL.path)
        #expect(match.fallbackFollows)
        // A directory that is not there is a `cd` that fails, and the line is not answered whole.
        #expect(!Self.isCompound(Self.match("cd Elsewhere && sed -n 1,5p App/Alpha.swift; grep -n 'func load' App/Depot.swift", in: root.path)))
    }

    /// A `..` operand behind a `cd` into a symbolic link resolves from where the link points, so a compound line's lookups are placed there, and a line whose operands stay below the link keeps the link's own path.
    @Test
    func aClimbingOperandBehindACdIntoALinkIsPlacedWhereTheLinkPoints() throws {
        let root = try TemporaryDirectory.make("compound-link")
        let deep = root.appendingPathComponent("Other/Deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: deep)

        let climbing = try #require(Self.match("cd Link && sed -n 1,5p ../Sources/App/Alpha.swift; grep -n 'func load' ../Sources/App/Depot.swift", in: root.path))
        let staying = try #require(Self.match("cd Link && sed -n 1,5p App/Alpha.swift; grep -n 'func load' App/Depot.swift", in: root.path))

        #expect(climbing.directory == deep.resolvingSymlinksInPath().path)
        #expect(staying.directory == root.appendingPathComponent("Link").standardizedFileURL.path)
    }

    /// Literals print where they fall: before the call after them, or after the last.
    @Test
    func literalsAreKeptWhereTheyFall() throws {
        let labelled = try #require(Self.match("grep -n 'func load' Sources/App/Depot.swift | head -5; echo ---; sed -n 1,5p Sources/App/Alpha.swift"))
        #expect(labelled.literals == [1: "---\n"])

        let headed = try #require(Self.match(#"head -5 Sources/App/Alpha.swift; echo "=== x ==="; head -5 Sources/App/Depot.swift; printf '%s\n' end done"#))
        #expect(headed.calls.map(\.readPath) == ["Sources/App/Alpha.swift", "Sources/App/Depot.swift"])
        #expect(headed.literals == [1: "=== x ===\n", 2: "end\ndone\n"])
        #expect(headed.isWholeCommand)
    }

    /// A read beside a grep, which could never share an answer before, is one compound line.
    @Test
    func aReadBesideAGrepIsOneMatch() {
        #expect(Self.isCompound(Self.match("cat Sources/App/Depot.swift && grep -n 'func go' Sources/App/Alpha.swift")))
    }

    /// Anything on the line this cannot print verbatim or answer leaves the line to today's reading, which answers two lookups of different shapes not at all.
    @Test(arguments: [
        "sed -n 1,5p Sources/App/Alpha.swift; ls; grep -n 'func load' Sources/App/Depot.swift",
        "sed -n 1,5p Sources/App/Alpha.swift; echo $X; grep -n 'func load' Sources/App/Depot.swift",
        #"sed -n 1,5p Sources/App/Alpha.swift; echo "a\nb"; grep -n 'func load' Sources/App/Depot.swift"#,
        #"sed -n 1,5p Sources/App/Alpha.swift; echo a\\nb; grep -n 'func load' Sources/App/Depot.swift"#,
        "sed -n 1,5p Sources/App/Alpha.swift; echo -n x; grep -n 'func load' Sources/App/Depot.swift",
        "sed -n 1,5p Sources/App/Alpha.swift; echo -; grep -n 'func load' Sources/App/Depot.swift",
        "sed -n 1,5p Sources/App/Alpha.swift; echo =ls; grep -n 'func load' Sources/App/Depot.swift",
        "sed -n 1,5p Sources/App/Alpha.swift; echo x > out.txt; grep -n 'func load' Sources/App/Depot.swift",
        "sed -n 1,5p Sources/App/Alpha.swift; printf '%d\\n' 3; grep -n 'func load' Sources/App/Depot.swift",
        "sed -n 1,5p Sources/App/Alpha.swift; grep -n 'func load' Sources/App/Depot.swift > out.txt",
        "sed -n 1,5p Sources/App/Alpha.swift; grep -n 'func load' Sources/App/Depot.swift | grep -v test",
        "sed -n 1,5p Sources/App/Alpha.swift; grep -n 'func load' Sources/App/Depot.swift &",
        "sed -n 1,5p Sources/App/Alpha.swift & grep -n 'func load' Sources/App/Depot.swift",
        "! sed -n 1,5p Sources/App/Alpha.swift; grep -n 'func load' Sources/App/Depot.swift",
    ])
    func aStatementThatCannotBeAccountedForLeavesTheLine(command: String) {
        #expect(!Self.isCompound(Self.match(command)), "\(command)")
        #expect(Self.match(command)?.literals.isEmpty ?? true, "\(command)")
    }

    /// An `&&` behind a window no proof covers — an every-line `awk` into a count, answered alone but off the closed list — is no proven joint, though the same window behind a `;` needs no proof.
    @Test
    func anUnprovenJointLeavesTheLine() {
        #expect(Self.isCompound(Self.match("awk 1 Sources/App/Alpha.swift | head -2; grep -n 'func load' Sources/App/Depot.swift")))
        #expect(!Self.isCompound(Self.match("awk 1 Sources/App/Alpha.swift | head -2 && grep -n 'func load' Sources/App/Depot.swift")))
        // A bare name grep's success is a line printed, and its answer runs no search to show one.
        #expect(!Self.isCompound(Self.match("grep -rn Depot Sources && grep -n 'func load' Sources/App/Depot.swift")))
        // A fallback that could print needs the same proof; one proven silent does not.
        #expect(!Self.isCompound(Self.match("awk 1 Sources/App/Alpha.swift | head -2 || echo none; grep -n 'func load' Sources/App/Depot.swift")))
        #expect(Self.isCompound(Self.match("awk 1 Sources/App/Alpha.swift | head -2 || true; grep -n 'func load' Sources/App/Depot.swift")))
    }

    /// A lookup answered on its own beside anything else keeps today's partial answer: one lookup is no compound line.
    @Test
    func oneLookupKeepsItsPartialAnswer() throws {
        let match = try #require(Self.match("sed -n 1,5p Sources/App/Alpha.swift; ls"))

        #expect(match.calls.count == 1)
        #expect(!match.isWholeCommand)
        #expect(match.literals.isEmpty)
    }

    /// Each part is what its statement prints, in command order under one header: a window's digest, the literal verbatim, the member's source for its grep, and every byte charged to a call.
    @Test
    func eachPartIsAnsweredInCommandOrder() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        // A window of a file whose digest is smaller than the lines it prints, so the digest answers it.
        let members = (1 ... 30).map { "    func item\($0)() -> Int {\n        let count = \($0) // \(String(repeating: "x", count: 150))\n        let doubled = count * 2\n        let tripled = count * 3\n        return doubled + tripled\n    }" }
        try ("/// A crate.\nstruct Crate {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Crate.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let command = #"sed -n 1,500p Sources/App/Crate.swift; echo "=== depot ==="; grep -n 'func stock3()' -A4 Sources/App/Depot.swift; printf '%s\n' end"#
        let outcome = try await Self.outcome(command, in: root)
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
        let reason = answered.reason

        #expect(reason.hasPrefix("sift answered this with `digest Sources/App/Crate.swift`"))
        #expect(reason.components(separatedBy: "\ntree: ").count == 2)
        let digest = try #require(reason.range(of: "Sources/App/Crate.swift — module: "))
        let label = try #require(reason.range(of: "\n\n=== depot ===\n"))
        let member = try #require(reason.range(of: "func stock3() -> Int {\n        let count = 3\n        let doubled = count * 2\n        return doubled + count\n    }"))
        let end = try #require(reason.range(of: "\n\nend\n"))
        #expect(digest.lowerBound < label.lowerBound)
        #expect(label.lowerBound < member.lowerBound)
        #expect(member.lowerBound < end.lowerBound)
        #expect(!reason.contains("func stock4()"))
        #expect(answered.calls.reduce(0) { $0 + $1.bytes.served } == reason.utf8.count)
    }

    /// A joint whose proof fails withholds the whole line: a grep that prints nothing, or a read of a file that is not there, before an `&&`.
    @Test(arguments: [
        "grep -n 'func stock99()' Sources/App/Depot.swift && sed -n 1,5p Sources/App/Alpha.swift",
        "cat Sources/App/Missing.swift && grep -n 'func stock3()' Sources/App/Depot.swift",
        "sed -n 1,9999p Sources/App/Depot.swift; grep -n 'func stock99()' Sources/App/Depot.swift",
    ])
    func aFailedPartWithholdsTheWholeLine(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        #expect(try await Self.outcome(command, in: root) == .withheld(.notExact))
    }

    /// The size budget bounds the whole line, every part included: two parts reading two files, each answered alone within a budget the pair exceeds together, are withheld together.
    ///
    /// The budget is the larger part's own answer, measured here rather than fixed, since every answer's freshness header names the fixture's directory.
    @Test
    func theSizeBudgetBoundsTheWholeLine() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let parts = ["grep -n 'func stock3()' -A4 Sources/App/Depot.swift", "grep -n 'func go' Sources/App/Alpha.swift"]
        var sizes: [Int] = []
        for part in parts {
            guard case let .answered(answered) = try await Self.outcome(part, in: root) else {
                Issue.record("\(part) is answered alone")
                return
            }
            sizes.append(answered.reason.utf8.count)
        }
        let budget = try #require(sizes.max())
        let command = parts.joined(separator: "; echo ---; ")
        var fitAlone: [Bool] = []
        for part in parts {
            try await fitAlone.append(Self.outcome(part, in: root, sizeBudget: budget).isAnswered)
        }

        #expect(fitAlone == [true, true], "each part alone fits in \(budget) B")
        #expect(try await Self.outcome(command, in: root, sizeBudget: budget) == .withheld(.overSize))
        #expect(try await Self.outcome(command, in: root).isAnswered)
    }

    /// A literal printed between two windows of one file, which share one digest, would be moved past the second, so the line is left to today's reading; two windows with nothing printed between them still share it.
    @Test
    func aLiteralBetweenTwoWindowsOfOneFileLeavesTheLine() {
        let split = "sed -n 1,5p Sources/App/Alpha.swift; echo '=== B ==='; sed -n 1,5p Sources/App/Depot.swift; echo '=== A again ==='; sed -n 60,70p Sources/App/Alpha.swift"
        #expect(!Self.isCompound(Self.match(split)))
        let together = "sed -n 1,5p Sources/App/Alpha.swift; sed -n 60,70p Sources/App/Alpha.swift; echo '=== B ==='; sed -n 1,5p Sources/App/Depot.swift"
        let match = Self.match(together)
        #expect(Self.isCompound(match))
        #expect(match?.calls.count == 2)
        #expect(match?.literals == [1: "=== B ===\n"])
    }

    /// A part said twice is said once, but not across a literal printed between the two, which the one copy cannot sit on both sides of.
    @Test
    func aRepeatAcrossALiteralIsWithheld() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let grep = "grep -n 'func stock3()' Sources/App/Depot.swift"

        #expect(try await Self.outcome("\(grep); echo sep; \(grep)", in: root) == .withheld(.notExact))
        #expect(try await Self.outcome("\(grep); \(grep)", in: root).isAnswered)
    }

    /// A compound line's own withholding stands even where it has an ordinary reading, because that reading itself always leaves the grep's lines out and would only replace the real reason with ``InPlaceAnswerer/Withholding/otherStatementsRun``: here a name grep with no store to answer it from, beside a read.
    @Test
    func aWithheldLineKeepsItsOwnOutcomeOverAnOrdinaryReadingThatRunsOtherStatements() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let match = try #require(Self.match("grep -rn stock3 Sources/App/Depot.swift Sources/App; cat Sources/App/Alpha.swift", in: root.path))
        let ordinary = try #require(match.ordinary)
        #expect(Self.isCompound(match))
        #expect(ordinary.calls.map(\.readPath) == ["Sources/App/Alpha.swift"])
        #expect(!ordinary.isWholeCommand)
        #expect(ordinary.lookups == 1)
        #expect(ordinary.runsOtherStatements)

        let backoff = try InPlaceAnswerTests.backoff()
        let answer: @Sendable (InPlaceShape.Match) -> InPlaceAnswerer.Outcome = { InPlaceAnswerer.answer($0, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
        let (reading, outcome) = await InPlaceAnswerTests.onItsOwnThread { InPlaceAnswerer.firstAnswered(match) { match, _ in answer(match) } }
        #expect(reading == match)
        #expect(outcome == .withheld(.noStore))
    }

    /// A compound line answered normally never reaches the ordinary reading at all: the match's own outcome is the one `firstAnswered` returns.
    @Test
    func anAnsweredLineNeverConsultsItsOrdinaryReading() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let command = "sed -n 1,500p Sources/App/Depot.swift; grep -n 'func stock3()' -A4 Sources/App/Depot.swift"
        let match = try #require(Self.match(command, in: root.path))
        #expect(Self.isCompound(match))

        let backoff = try InPlaceAnswerTests.backoff()
        let answer: @Sendable (InPlaceShape.Match) -> InPlaceAnswerer.Outcome = { InPlaceAnswerer.answer($0, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
        let (reading, outcome) = await InPlaceAnswerTests.onItsOwnThread { InPlaceAnswerer.firstAnswered(match) { match, _ in answer(match) } }
        #expect(reading == match)
        guard case .answered = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
    }

    /// The ordinary reading is given only what the withheld line left of the one time budget, and is not asked at all where the line used it up.
    @Test
    func theFallbackReadingSharesTheLinesTimeBudget() throws {
        // Two whole reads, whose ordinary reading covers both statements too (unlike a grep beside a read, whose
        // ordinary always leaves the grep's lines out): a fallback this test can actually reach.
        let match = try #require(Self.match("cat Sources/App/Alpha.swift; cat Sources/App/Depot.swift"))
        #expect(try #require(match.ordinary).runsOtherStatements == false)
        let slow: TimeInterval = 0.2
        var budgets: [TimeInterval] = []
        _ = InPlaceAnswerer.firstAnswered(match, timeBudget: 1) { _, budget in
            budgets.append(budget)
            if budgets.count == 1 {
                Thread.sleep(forTimeInterval: slow)
            }
            return .withheld(.overSize)
        }
        #expect(budgets.count == 2)
        #expect(budgets.first == 1)
        #expect(budgets.last.map { $0 <= 1 - slow } == true)

        var asked = 0
        let (reading, outcome) = InPlaceAnswerer.firstAnswered(match, timeBudget: slow / 2) { _, _ in
            asked += 1
            Thread.sleep(forTimeInterval: slow)
            return .withheld(.overTime)
        }
        #expect(asked == 1)
        #expect(reading == match)
        #expect(outcome == .withheld(.overTime))
    }

    /// A package whose `Depot` has a member and a use, built so `where` has the index store it lists references from.
    private static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "public struct Depot {\n    public init() {}\n    func count() -> Int {\n        3\n    }\n}\n",
            "Sources/App/Gizmo.swift": "public struct Gizmo {\n    public init() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    var depot = Depot()\n    var second = Gizmo()\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A literal is printed verbatim, with no mark on it; the answer after text a `printf` leaves without a newline opens on a marked line of its own, so its header stays readable; and a module guessed for the line's files is warned about once.
    @Test
    func literalsAreVerbatimAndTheWarningIsSaidOnce() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let command = "cat Sources/App/Alpha.swift; echo ---; grep -n 'func stock3()' -A4 Sources/App/Depot.swift; printf 'x'; sed -n 1,500p Sources/App/Depot.swift"
        let outcome = try await Self.outcome(command, in: root)
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
        let reason = answered.reason

        #expect(reason.contains("\n\n---\n"))
        #expect(!reason.contains("\(SourcePassthrough.partMarker)---"))
        let window = "Sources/App/Depot.swift — module: "
        #expect(reason.contains("\nx\n\n\(SourcePassthrough.partMarker)\(window)"))
        #expect(reason.components(separatedBy: "module guessed").count == 2)
    }

    /// The one warning a compound answer says counts the files a part's warning counted rather than named, beside every file the parts named past the cap.
    @Test
    func theWarningSaidOnceKeepsEveryPartsUnnamedCount() throws {
        let many = try #require(GuessedModuleNotice(paths: (1 ... 10).map { "Sources/App/F\($0).swift" }).banner)
        let one = try #require(GuessedModuleNotice(paths: ["Sources/App/Z.swift"]).banner)
        #expect(many.contains(" (+2 more) — "))

        let body = CompoundAnswerBody.joined([
            (isLiteral: false, text: "\(many)\n\nfirst"),
            (isLiteral: false, text: "\(one)\n\nsecond"),
        ])

        // Nine named across the two, eight shown, and the two the first part only counted, which may include the second's file.
        #expect(body.components(separatedBy: "module guessed").count == 2)
        #expect(body.contains(" (+up to 3 more) — "))

        let twice = CompoundAnswerBody.joined([
            (isLiteral: false, text: "\(many)\n\nfirst"),
            (isLiteral: false, text: "\(many)\n\nsecond"),
        ])
        #expect(twice.contains(" (+up to 4 more) — "))
    }

    /// A `where` sweep joins a line under its own header, which states the semantic store's freshness as the shared one does not: two sweeps with a literal between them, and a sweep beside a member grep, whose part stands under the shared header.
    @Test
    func aSweepJoinsTheLineUnderItsOwnHeader() async throws {
        let root = try await Self.builtPackage()
        let sweeps = try await Self.outcome("grep -rn Depot Sources; echo ---; grep -rn Gizmo Sources", in: root)
        let mixed = try await Self.outcome("grep -rn Depot Sources; grep -n 'func count()' -A2 Sources/App/Depot.swift", in: root)
        guard case let .answered(both) = sweeps, case let .answered(beside) = mixed else {
            Issue.record("expected both answered, got \(sweeps) and \(mixed)")
            return
        }
        // A part's first line opens on the marker that sets it apart.
        let headers = { (reason: String) in reason.split(separator: "\n").filter { $0.hasPrefix("tree: ") || $0.hasPrefix("\(SourcePassthrough.partMarker)tree: ") } }

        // Each sweep under its own header, and no shared one where no part stands under it.
        #expect(headers(both.reason).count == 2)
        #expect(both.reason.contains("\nwhere Depot\n"))
        let dashes = try #require(both.reason.range(of: "\n\n---\n"))
        let gizmo = try #require(both.reason.range(of: "\nwhere Gizmo\n"))
        #expect(dashes.lowerBound < gizmo.lowerBound)
        // The shared header over the member, and the sweep's own beside it.
        #expect(headers(beside.reason).count == 2)
        #expect(beside.reason.contains("func count() -> Int {"))
        #expect(beside.calls.map(\.tool).contains("where"))
    }

    /// `exec` replaces the shell with the command it names, and `exit` or `return` ends it, so nothing after either runs: a line carrying one, however it is spelled, is answered not at all, not even for the lookups beside it.
    @Test(arguments: [
        "exec grep -n 'func load' Sources/App/Depot.swift; head -5 Sources/App/Alpha.swift",
        "head -5 Sources/App/Alpha.swift; exec head -5 Sources/App/Depot.swift; head -5 Sources/App/Beta.swift",
        "sed -n 1,5p Sources/App/Alpha.swift; exec true; grep -n 'func load' Sources/App/Depot.swift",
        "builtin exec cat Sources/App/Alpha.swift; cat Sources/App/Beta.swift",
        "command exec cat Sources/App/Alpha.swift; cat Sources/App/Beta.swift",
        #"\exec cat Sources/App/Alpha.swift; cat Sources/App/Beta.swift"#,
        "cat Sources/App/Alpha.swift; exit; cat Sources/App/Beta.swift",
        "cat Sources/App/Alpha.swift; builtin exit 0; cat Sources/App/Beta.swift",
        "cat Sources/App/Alpha.swift; return; cat Sources/App/Beta.swift",
    ])
    func aLineCarryingExecIsNotMatched(command: String) {
        #expect(Self.match(command) == nil, "\(command)")
    }

    /// A window beside a whole read is weighed against its own lines, never paid for by the whole read's saving: its members answer it where its digest is not smaller and they save the floor on their own, and the line is not answered where they are not smaller either.
    @Test
    func aWindowBesideAWholeReadIsWeighedAgainstItsOwnLines() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        // Long signatures make the digest's first page heavier than the window, and the window's three padded members save the floor with their own.
        let padding = String(repeating: "x", count: 1800)
        let members = (1 ... 100).map { "    func item\($0)(quantity: Int, label: String, owner: String, location: String, reference: Int) -> Int {\n        let count = \($0)\($0 <= 3 ? " // " + padding : "")\n        let doubled = count * 2\n        let tripled = count * 3\n        return doubled + tripled\n    }" }
        try ("/// A crate.\nstruct Crate {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Crate.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let outcome = try await Self.outcome("cat Sources/App/Depot.swift; sed -n 2,20p Sources/App/Crate.swift", in: root)
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift", "Sources/App/Crate.swift:2-20"])
        let window = try #require(answered.calls.last?.bytes.source)
        #expect(try #require(answered.calls.last?.bytes.served) < window)
        #expect(answered.reason.contains("only members of Sources/App/Crate.swift lines 2-20 are shown; the whole digest would be no smaller than these lines"))
        #expect(try await Self.outcome("cat Sources/App/Depot.swift; sed -n 1,3p Sources/App/Crate.swift", in: root) == .withheld(.notSmaller))
        #expect(try await Self.outcome("cat Sources/App/Depot.swift; sed -n 900,910p Sources/App/Crate.swift", in: root) == .withheld(.notSmaller))
    }
}

private extension InPlaceAnswerer.Outcome {
    /// Whether this outcome is an answer.
    var isAnswered: Bool {
        if case .answered = self {
            return true
        }
        return false
    }
}
