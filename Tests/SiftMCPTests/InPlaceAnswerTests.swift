//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The refusal that carries its answer: what it says, what it is computed from, and every doubt that turns it back into the refusal that only names its call.
@Suite(.temporaryDirectories)
struct InPlaceAnswerTests {
    /// A time budget no loaded machine can overrun, for the tests about what an answer holds; the budget itself is tested with none.
    ///
    /// A day, not sixty seconds: under load the answer's own task can wait that long for a thread of the concurrency pool, and the verdict then turns `overTime` by the clock rather than by anything the hook decided.
    static let roomy: TimeInterval = 86400

    /// A back-off of its own for one call, so no test leaves a record anywhere a person reads.
    static func backoff() throws -> InPlaceBackoff {
        try InPlaceBackoff(directory: TemporaryDirectory.make("backoff").appendingPathComponent("backoff"))
    }

    /// The padding of ``indexedRepository(padding:)`` that adds the floor and a quarter again across the depot's forty members, for a test whose window over most of them is answered with members that do not show its lines.
    static let pastTheFloor = InPlaceAnswer.windowSavingFloor / 32

    /// A repository indexed as a session would have left it: `Alpha` from the shared fixture, and a `Depot` long enough that its digest compresses.
    ///
    /// `padding` bytes of trailing comment on every member's `let count` line make the file's source that much larger without changing a line number or its digest, for a test whose window must save more than ``InPlaceAnswer/windowSavingFloor``.
    static func indexedRepository(padding: Int = 0) async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let comment = padding > 0 ? " //" + String(repeating: "x", count: padding - 3) : ""
        let members = (1 ... 40).map { index in
            "    func stock\(index)() -> Int {\n        let count = \(index)\(comment)\n        let doubled = count * 2\n        return doubled + count\n    }"
        }
        try ("/// A depot.\nstruct Depot {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The repository the review's cases ran in: a store whose `func save` is matched by a prefix, a nested type, a second type and a string literal; a local that shares a static's name; a digest that collapses a nested type and truncates a trailing one; and a file of two views.
    static func reviewedRepository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        var store = [
            "import Foundation",
            "",
            "/// A store.",
            "public struct Store {",
            "    public static let now = Date()",
            "    var items: [String] = []",
            "    public init() {}",
            "    public func save() {",
            "        let now = Date()",
            "        let message = \"func save is here in a string\"",
            "        _ = (now, message)",
            "    }",
            "    public func saves() {",
            "        for item in items { _ = item.lowercased() }",
            "    }",
            "    func classify(_ value: Int) -> String {",
            "        switch value {",
            "        case 0: return \"zero\"",
            "        default: return \"many\"",
            "        }",
            "    }",
            "    struct Cache {",
            "        func save() {}",
            "        var initial = 0",
            "    }",
        ]
        store += (0 ..< 60).flatMap { ["    func filler\($0)(_ value: Int) -> Int {", "        value * \($0)", "    }"] }
        store += ["}", "", "struct Other {", "    func save() {}", "}"]
        try MCPTestRepo.add([
            "Sources/App/Store.swift": store.joined(separator: "\n") + "\n",
            "Sources/App/Screens.swift": "struct Screen: View {\n    var body: Int {\n        1\n    }\n}\n\nprivate struct Row: View {\n    var body: Int {\n        2\n    }\n}\n",
            "Sources/App/Viewing.swift": "protocol View {\n    associatedtype Body\n}\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A document long enough that its outline is worth having, written into `root` at `Docs/Plan.md`: eight headings over prose no heading scan reads.
    @discardableResult
    static func document(in root: URL) throws -> URL {
        let titles = ["Purpose", "Shape", "Storage", "Query", "Freshness", "Budgets", "Failure modes", "Open questions"]
        var lines: [String] = ["# Plan", ""]
        for (index, title) in titles.enumerated() {
            lines.append("## \(title)")
            lines.append("")
            lines += (1 ... 10).map { "Paragraph \($0) of section \(index + 1), written at a length a real note would run to, and past the 8 KiB a whole read is let through at." }
            lines.append("")
        }
        let url = root.appendingPathComponent("Docs/Plan.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// ``InPlaceAnswerer/answer(_:from:serverGone:timeBudget:sizeBudget:backoff:)``, with what the answer stands for, run on a thread of its own, as the hook runs it on its process's main thread.
    ///
    /// The answerer waits on a semaphore for work it hands to the concurrency pool, which is right for the hook and would starve a pool whose threads a whole suite of async tests is holding — so a test never calls it from one of those threads.
    static func answer(
        _ call: InPlaceCall,
        from directory: String?,
        serverGone: Bool = false,
        wholeCommand: Bool = true,
        timeBudget: TimeInterval = roomy,
        sizeBudget: Int = InPlaceAnswer.sizeBudget,
        backoff: InPlaceBackoff? = nil
    ) async throws -> InPlaceAnswerer.Outcome {
        // One of its own unless the test brought one — made here, on the test's task, where its scope is.
        let backoff = try backoff ?? Self.backoff()
        return await onItsOwnThread {
            InPlaceAnswerer.answer(
                call,
                from: directory,
                serverGone: serverGone,
                wholeCommand: wholeCommand,
                timeBudget: timeBudget,
                sizeBudget: sizeBudget,
                backoff: backoff
            )
        }
    }

    /// `body` run on a thread outside the concurrency pool, for code that blocks waiting on the pool.
    ///
    /// The registry the calling scope bound for a `RunIndexState` (``RunIndexState/scopedRegistry``) is carried onto the thread, which a task-local does not reach on its own.
    static func onItsOwnThread<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
        let registry = RunIndexState.scopedRegistry
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: RunIndexState.$scopedRegistry.withValue(registry, operation: body))
            }
        }
    }

    /// What the hook does with `command` run from `root`: the shape it reads, answered or withheld.
    static func outcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let shaped = try #require(InPlaceShape.match(forShell: command, in: root.path), "\(command) is not a candidate", sourceLocation: sourceLocation)
        return try await Self.answer(shaped.call, from: shaped.directory, wholeCommand: shaped.isWholeCommand)
    }

    /// The answer `command` got, or a recorded issue.
    static func answered(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Answered? {
        let result = try await outcome(command, in: root, sourceLocation: sourceLocation)
        guard case let .answered(answered) = result else {
            Issue.record("expected \(command) answered, got \(result)", sourceLocation: sourceLocation)
            return nil
        }
        return answered
    }

    /// The opening line names the calls and says what the re-run is for; the answer sits whole between it and the closing line, which states its size against the source.
    @Test
    func aRefusalThatCarriesItsAnswerReadsBackAsOne() throws {
        let answer = "tree: App  head: 0000000  dirty: 0  parse_errors: 0\nSources/App/Depot.swift — module: App\n\nstruct Depot — 40 members  :2-201"
        let reason = InPlaceAnswer.reason(calls: ["digest Sources/App/Depot.swift"], answer: answer, source: 20000, standsIn: "")
        let opening = try #require(reason.text.split(separator: "\n").first)
        let several = InPlaceAnswer.openingLine(calls: ["digest Screen.body", "digest Row.body"])

        #expect(opening == "sift answered this with `digest Sources/App/Depot.swift` instead of running it — re-run the identical command if you wanted its raw output.")
        #expect(InPlaceAnswer.calls(inOpeningLine: opening) == ["digest Sources/App/Depot.swift"])
        #expect(InPlaceAnswer.calls(inOpeningLine: several) == ["digest Screen.body", "digest Row.body"])
        #expect(InPlaceAnswer.answer(inReason: reason.text) == answer)
        #expect(reason.served == reason.text.utf8.count)
        #expect(reason.text.hasSuffix("\n20 kB of source → \(ByteSize.short(reason.served)) served (\((20000 - reason.served) * 100 / 20000)% smaller)."))
        #expect(InPlaceAnswer.calls(inOpeningLine: IndexSuggestion.lookupOffer) == nil)
        #expect(InPlaceAnswer.answer(inReason: TranscriptFixture.refusal()) == nil)
    }

    /// A lookup that was one statement of a command is answered, and its opening line names the lookup rather than the command, so the statements that did not run are not read as covered.
    @Test
    func aLookupBesideOtherStatementsIsAnsweredAndSaysWhatItAnswered() async throws {
        let root = try await Self.indexedRepository()

        let answered = try await Self.answered("echo start; cat Sources/App/Depot.swift", in: root)

        let opening = try #require(answered?.reason.split(separator: "\n").first)

        #expect(opening.hasPrefix("sift answered the lookup in this command with `digest Sources/App/Depot.swift`"))
        #expect(InPlaceAnswer.calls(inOpeningLine: opening) == ["digest Sources/App/Depot.swift"])
        #expect(answered?.reason.contains("struct Depot — 40 members") == true)
        #expect(answered?.calls.first?.tool == "digest")
    }

    /// A size is stated against its source where the answer weighed itself, as no saving where it served no less, and as unclaimed where it had nothing to weigh against.
    @Test
    func theClosingLineClaimsNoMoreThanWasMeasured() {
        let short = InPlaceAnswer.reason(calls: ["digest Sources/App/Alpha.swift"], answer: "tree: App\nstruct Alpha {}", source: 60, standsIn: "").text
        let unweighed = InPlaceAnswer.reason(calls: ["where Alpha --refs"], answer: "tree: App\nwhere Alpha", source: nil, standsIn: "a `where` answer stands in for a search's output").text

        #expect(short.hasSuffix("No saving: \(ByteSize.short(short.utf8.count)) served for 60 B of source."))
        #expect(unweighed.hasSuffix("No saving is claimed: a `where` answer stands in for a search's output, so there is nothing measured to set it against."))
    }

    /// A whole read is answered with the file's digest, header first, with the source it stands in for measured.
    @Test
    func aWholeReadIsAnsweredWithTheFilesDigest() async throws {
        let root = try await Self.indexedRepository()

        let outcome = try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: root.path, timeBudget: Self.roomy, backoff: Self.backoff())

        guard case let .answered(answered) = outcome, let call = answered.calls.first else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.count == 1)
        #expect(call.tool == "digest")
        #expect(call.target == "Sources/App/Depot.swift")
        #expect(CanonicalPath.of(answered.root) == CanonicalPath.of(root.path))
        #expect(answered.reason.hasPrefix("sift answered this with `digest Sources/App/Depot.swift` instead of running it"))
        #expect(InPlaceAnswer.answer(inReason: answered.reason)?.hasPrefix("tree: ") == true)
        #expect(answered.reason.contains("struct Depot — 40 members"))
        #expect(call.bytes.served == answered.reason.utf8.count)
        #expect((call.bytes.source ?? 0) > call.bytes.served)
    }

    /// A whole read of a file that is not there is never answered with a file of the same name somewhere else, in either spelling.
    @Test
    func aReadOfAFileThatIsNotThereIsNeverAnsweredWithAnother() async throws {
        let root = try await Self.reviewedRepository()

        #expect(try await Self.outcome("cat Store.swift", in: root) == .withheld(.notExact))
        let read = try #require(InPlaceShape.call(forRead: root.appendingPathComponent("Store.swift").path))
        #expect(try await Self.answer(read, from: root.path, timeBudget: Self.roomy, backoff: Self.backoff()) == .withheld(.notExact))
        #expect(try await Self.answered("cat Sources/App/Store.swift", in: root)?.calls.first?.target == "Sources/App/Store.swift")
    }

    /// A whole read of a Markdown document is answered with the document's heading outline — the `digest` answer as the tool renders it, read live from disk, with no freshness header over it, since no index was consulted for it.
    @Test
    func aWholeReadOfADocumentIsAnsweredWithItsOutline() async throws {
        let root = try await Self.indexedRepository()
        try Self.document(in: root)

        let read = try #require(InPlaceShape.call(forRead: root.appendingPathComponent("Docs/Plan.md").path))
        let outcome = try await Self.answer(read, from: root.path, timeBudget: Self.roomy, backoff: Self.backoff())

        guard case let .answered(answered) = outcome, let call = answered.calls.first else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.count == 1)
        #expect(call.tool == "digest")
        #expect(call.target == "Docs/Plan.md")
        #expect(CanonicalPath.of(answered.root) == CanonicalPath.of(root.path))
        #expect(answered.reason.hasPrefix("sift answered this with `digest Docs/Plan.md` instead of running it"))
        let answer = try #require(InPlaceAnswer.answer(inReason: answered.reason))
        #expect(answer.hasPrefix("Docs/Plan.md — "))
        #expect(answer.contains("read live from disk"))
        #expect(!answer.hasPrefix("tree: "))
        #expect(answered.reason.contains("Open questions"))
        #expect(call.bytes.served == answered.reason.utf8.count)
        #expect((call.bytes.source ?? 0) > call.bytes.served)
    }

    /// A document that is not at the path the read named is never answered with another, and a read with no repository behind it is not answered at all.
    @Test
    func aReadOfADocumentThatIsNotThereIsWithheld() async throws {
        let root = try await Self.indexedRepository()
        try Self.document(in: root)

        let missing = try #require(InPlaceShape.call(forRead: root.appendingPathComponent("Docs/Missing.md").path))
        #expect(try await Self.answer(missing, from: root.path, timeBudget: Self.roomy, backoff: Self.backoff()) == .withheld(.notExact))
        let relative = try #require(InPlaceShape.call(forRead: "Plan.md"))
        #expect(try await Self.answer(relative, from: nil, timeBudget: Self.roomy, backoff: Self.backoff()) == .withheld(.noRepository))
    }

    /// A document in another repository is left to the read, and no store is opened there: the outline consults no index, but the engine that renders it opens one, and a `.sift/` directory is never made in a checkout the caller does not stand in.
    @Test
    func aDocumentInAnotherRepositoryIsNotAnsweredAndOpensNoStoreThere() async throws {
        let root = try await Self.indexedRepository()
        let other = try MCPTestRepo.make(declaring: "Alpha")
        let document = try Self.document(in: other)
        let store = other.appendingPathComponent(".sift")

        let read = try #require(InPlaceShape.call(forRead: document.path))

        #expect(try await Self.answer(read, from: root.path, timeBudget: Self.roomy, backoff: Self.backoff()) == .withheld(.outsideRoot))
        #expect(!FileManager.default.fileExists(atPath: store.path))
        // From its own repository the same document is answered.
        #expect(try await Self.answer(read, from: other.path, timeBudget: Self.roomy, backoff: Self.backoff()) != .withheld(.outsideRoot))
    }

    /// A document above the floor with no ATX heading — prose under Setext `===`/`---` underlines, which the outline does not count as headings — locates nothing to outline, so the read runs rather than being denied "no headings — a plain Read is the way to see this one".
    @Test
    func aDocumentWithNoHeadingsIsNotAnswered() async throws {
        let root = try await Self.indexedRepository()
        var lines: [String] = []
        for section in 1 ... 9 {
            lines.append("Section \(section)")
            lines.append(String(repeating: "=", count: 9))
            lines += (1 ... 9).map { "Paragraph \($0) of section \(section), written at a length a real note would run to." }
        }
        let url = root.appendingPathComponent("Docs/Bare.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let read = try #require(InPlaceShape.call(forRead: url.path))

        #expect(try await Self.answer(read, from: root.path, timeBudget: Self.roomy, backoff: Self.backoff()) == .withheld(.notExact))
    }

    /// A heading-dense document the renderer passes through — every section short enough that the outline is not smaller than the source — locates nothing worth a denial either, whatever headings it has.
    @Test
    func aDocumentWhoseOutlineIsNotSmallerIsNotAnswered() async throws {
        let root = try await Self.indexedRepository()
        var lines: [String] = []
        for heading in 1 ... 30 {
            lines.append("## Heading \(heading)")
            lines.append("Short line \(heading).")
        }
        let url = root.appendingPathComponent("Docs/Dense.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let read = try #require(InPlaceShape.call(forRead: url.path))

        #expect(try await Self.answer(read, from: root.path, timeBudget: Self.roomy, backoff: Self.backoff()) == .withheld(.notExact))
    }

    /// An outline is answered in a repository no build has indexed — it consults no index, so there is nothing for one to hold — and under a shape of its own, so it leaves the whole read's answers alone.
    @Test
    func anOutlineNeedsNoIndexAndBacksOffOnItsOwnShape() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try Self.document(in: root)
        let backoff = try Self.backoff()

        #expect(!ReadOnlyIndex.hasIndexStore(atRoot: root.path))
        let read = try #require(InPlaceShape.call(forRead: root.appendingPathComponent("Docs/Plan.md").path))
        #expect(read.shape == .outline)

        guard case .answered = try await Self.answer(read, from: root.path, timeBudget: Self.roomy, backoff: backoff) else {
            Issue.record("expected a document answered where no build has indexed the tree")
            return
        }

        // An outline that ran long is held off on its own shape; the Swift read's — the cheapest and commonest
        // answer there is — is never touched by it.
        #expect(try await Self.answer(read, from: root.path, timeBudget: 0, backoff: backoff) == .withheld(.overTime))
        #expect(backoff.isBackingOff(root: CanonicalPath.of(root.path), shape: .outline))
        #expect(!backoff.isBackingOff(root: CanonicalPath.of(root.path), shape: .read))
    }

    /// A member grep whose matches include a line that declares nothing — a string literal inside a body — is refused, though every member it names would be served.
    @Test
    func aMatchThatDeclaresNothingRefusesTheMemberAnswer() async throws {
        let root = try await Self.reviewedRepository()

        #expect(try await Self.outcome("grep -n 'func save' Sources/App/Store.swift", in: root) == .withheld(.notExact))
        // A static and a local of one name: the local is inside a body no match declares.
        #expect(try await Self.outcome("grep -n 'let now' Sources/App/Store.swift", in: root) == .withheld(.notExact))
    }

    /// A `tail -1` keeps the last match, and the answer is that member: the one the grep would have printed, and no other.
    @Test
    func theCutDecidesWhichMemberIsAnswered() async throws {
        let root = try await Self.reviewedRepository()

        let answered = try #require(try await Self.answered("grep -n 'func save' Sources/App/Store.swift | tail -1", in: root))

        #expect(answered.calls.map(\.target) == ["Other.save()"])
        #expect(answered.reason.hasPrefix("sift answered this with `digest Other.save()` instead of running it"))
        #expect(!answered.reason.contains("Store.save"))
    }

    /// Two views in one file both have a `body`, and a grep for it is answered with both, since it prints both.
    @Test
    func everyMatchedMemberIsServed() async throws {
        let root = try await Self.reviewedRepository()

        let answered = try #require(try await Self.answered("grep -n 'var body' Sources/App/Screens.swift", in: root))

        #expect(answered.calls.map(\.target) == ["Screen.body", "Row.body"])
        #expect(answered.reason.hasPrefix("sift answered this with `digest Screen.body`, `digest Row.body` instead of running it"))
        #expect(answered.reason.contains("        1\n") && answered.reason.contains("        2\n"))
        #expect(answered.calls.reduce(0) { $0 + $1.bytes.served } == answered.reason.utf8.count)
    }

    /// A declaration grep is answered with the digest only where every line it prints is a declaration the digest numbers — never a local, a switch case, a member collapsed into a nested type's summary, or a member past a truncation.
    @Test(arguments: [
        "grep -n 'let ' Sources/App/Store.swift",
        "grep -n 'case' Sources/App/Store.swift",
        #"grep -n 'static\|var ' Sources/App/Store.swift"#,
        "grep -n 'func ' Sources/App/Store.swift | head -5",
        "grep -n 'func ' Sources/App/Store.swift | tail -3",
        "grep -n 'struct' Sources/App/Store.swift",
    ])
    func aDeclarationGrepPrintingALineTheDigestDoesNotNumberIsRefused(command: String) async throws {
        let root = try await Self.reviewedRepository()

        #expect(try await Self.outcome(command, in: root) == .withheld(.notExact))
    }

    /// Where every line printed is a declaration the digest numbers, or a line of the source it serves, the digest is the answer — cut or not.
    @Test(arguments: [
        "grep -n 'public ' Sources/App/Store.swift",
        "grep -n 'public ' Sources/App/Store.swift | head -2",
        "grep -n 'func' Sources/App/Alpha.swift",
    ])
    func aDeclarationGrepTheDigestAccountsForIsAnswered(command: String) async throws {
        let root = try await Self.reviewedRepository()

        let answered = try await Self.answered(command, in: root)

        #expect(answered?.calls.first?.tool == "digest")
    }

    /// A sweep is answered only from the repository its operands name: another repository's files are never answered from the caller's index, a worktree's never from its parent's, and operands in two repositories not at all.
    @Test
    func aSweepIsAnsweredOnlyFromTheRepositoryItsOperandsName() async throws {
        let root = try await Self.indexedRepository()
        let other = try MCPTestRepo.make(declaring: "Alpha")
        let worktree = try MCPTestRepo.worktree(of: root, named: "sweep-\(UUID().uuidString.prefix(6))")

        // Neither carries a build's index store, and that is what a sweep's references come from — so neither
        // is answered from the caller's, whatever indexing on demand would do for a digest there.
        #expect(try await Self.outcome("grep -rnw Alpha \(other.path)/Sources", in: root) == .withheld(.noStore))
        #expect(try await Self.outcome("grep -rnw Alpha \(worktree.path)/Sources", in: root) == .withheld(.noStore))
        #expect(try await Self.outcome("grep -rnw Alpha Sources \(other.path)/Sources", in: root) == .withheld(.outsideRoot))
    }

    /// Every doubt resolves to the refusal: no repository, a sweep with no index store to list references from, a search that cannot be reproduced, a query past the time budget, an answer past the size budget.
    @Test
    func everyDoubtResolvesToTheRefusal() async throws {
        let root = try await Self.indexedRepository()
        let unindexed = try MCPTestRepo.make(declaring: "Alpha")
        let outside = try TemporaryDirectory.make("outside")
        let digest = InPlaceCall.fileDigest(path: "Sources/App/Depot.swift")

        #expect(try await Self.outcome("grep -rnw Alpha Sources", in: outside) == .withheld(.noRepository))
        // A sweep is refused before the engine opens, so nothing is built to find that out — the one place
        // indexing on demand still buys nothing, since no `where` answer would list a reference anyway.
        #expect(try await Self.outcome("grep -rnw Alpha Sources", in: unindexed) == .withheld(.noStore))
        #expect(!FileManager.default.fileExists(atPath: unindexed.appendingPathComponent(".sift").path))
        // A `$` before an alternation is an anchor to some implementations and a literal to others.
        #expect(try await Self.outcome(#"grep -n 'func$\|case' Sources/App/Depot.swift"#, in: root) == .withheld(.unchecked))
        #expect(try await Self.answer(digest, from: root.path, timeBudget: 0, backoff: Self.backoff()) == .withheld(.overTime))
        #expect(try await Self.answer(digest, from: root.path, timeBudget: Self.roomy, sizeBudget: 100, backoff: Self.backoff()) == .withheld(.overSize))
    }

    /// After an answer runs out of time in a repository, the next is withheld there without being tried, until the window passes.
    @Test
    func anOverrunBacksTheRepositoryOffForAWindow() async throws {
        let root = try await Self.indexedRepository()
        let clock = Clock()
        let backoff = try InPlaceBackoff(
            directory: TemporaryDirectory.make("backoff").appendingPathComponent("backoff"),
            now: { clock.now }
        )
        let digest = InPlaceCall.fileDigest(path: "Sources/App/Depot.swift")

        #expect(try await Self.answer(digest, from: root.path, timeBudget: 0, backoff: backoff) == .withheld(.overTime))
        #expect(try await Self.answer(digest, from: root.path, timeBudget: Self.roomy, backoff: backoff) == .withheld(.backingOff))
        clock.advance(by: InPlaceBackoff.window + 1)
        guard case .answered = try await Self.answer(digest, from: root.path, timeBudget: Self.roomy, backoff: backoff) else {
            Issue.record("expected the repository answered again once the window passed")
            return
        }
        #expect(InPlaceBackoff.window == 300)
    }

    /// The back-off is kept by shape as well as repository: a declaration grep that ran out of time leaves declaration greps alone there for the window, and a whole read — a different cost altogether — is still answered.
    @Test
    func anOverrunBacksOffOnlyTheShapeThatRanOut() async throws {
        let root = try await Self.indexedRepository()
        let backoff = try Self.backoff()
        let search = try #require(ShellGrep(arguments: ["-n", "func ", "Sources/App/Depot.swift"]))
        let declarations = InPlaceCall.declarations(file: "Sources/App/Depot.swift", search: search)

        #expect(try await Self.answer(declarations, from: root.path, timeBudget: 0, backoff: backoff) == .withheld(.overTime))
        #expect(try await Self.answer(declarations, from: root.path, timeBudget: Self.roomy, backoff: backoff) == .withheld(.backingOff))
        guard case .answered = try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: root.path, timeBudget: Self.roomy, backoff: backoff) else {
            Issue.record("expected a whole read answered while declaration greps back off")
            return
        }
    }

    /// Whatever can be refused without the engine is refused before it is opened: a sweep where there is no index store, a search that cannot be reproduced, and one that prints nothing all leave the index exactly as they found it, where an answer brings it up to date.
    @Test
    func aRefusalTheCheapChecksDecideNeverOpensTheEngine() async throws {
        let root = try await Self.indexedRepository()
        // A file the index has not seen yet: opening the engine brings the index up to date, and counts it.
        try "struct Newcomer {}\n".write(to: root.appendingPathComponent("Sources/App/Newcomer.swift"), atomically: true, encoding: .utf8)
        let before = try #require(ReadOnlyIndex.snapshot(atRoot: root.path)).files

        #expect(try await Self.outcome("grep -rnw Alpha Sources", in: root) == .withheld(.noStore))
        #expect(try await Self.outcome(#"grep -n 'func$\|case' Sources/App/Depot.swift"#, in: root) == .withheld(.unchecked))
        #expect(try await Self.outcome("grep -n 'func absent' Sources/App/Depot.swift", in: root) == .withheld(.notExact))
        #expect(ReadOnlyIndex.snapshot(atRoot: root.path)?.files == before)

        _ = try await Self.answered("cat Sources/App/Depot.swift", in: root)
        #expect(ReadOnlyIndex.snapshot(atRoot: root.path)?.files == before + 1)
    }

    /// Once the transcript records the server gone, the call the opening line names is spelled for Bash, as a refusal's is.
    @Test
    func onceTheServerIsGoneTheCallIsNamedForBash() async throws {
        let root = try await Self.indexedRepository()

        let outcome = try await Self.answer(
            .fileDigest(path: "Sources/App/Depot.swift"), from: root.path, serverGone: true, timeBudget: Self.roomy, backoff: Self.backoff()
        )

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.reason.hasPrefix("sift answered this with `sift digest Sources/App/Depot.swift` instead of running it"))
        #expect(InPlaceAnswer.calls(inOpeningLine: answered.reason.prefix { $0 != "\n" }) == ["sift digest Sources/App/Depot.swift"])
    }

    /// The budgets are the ones the design states, and a refusal at the size budget still fits the harness's inline limit.
    @Test
    func theBudgetsAreTheStatedOnes() {
        #expect(InPlaceAnswer.timeBudget == 3)
        #expect(InPlaceAnswer.sizeBudget == 10000)
    }
}

private extension InPlaceAnswerTests {
    /// A clock a test moves by hand.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()

        var now: Date {
            lock.withLock { current }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(interval) }
        }
    }
}

/// A read behind a move into a symbolic link, kept apart from the suite body it would push past its length.
extension InPlaceAnswerTests {
    /// A `..` operand behind a `cd` into a symbolic link is answered with the file the link reaches, as the file system reads it, never with the digest of the file the path names as written beside the link.
    @Test
    func aClimbingReadBehindACdIntoALinkIsAnsweredWithTheFileTheLinkReaches() async throws {
        let root = try await Self.indexedRepository()
        let reached = root.appendingPathComponent("Other/Sources/App")
        try FileManager.default.createDirectory(at: reached, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Other/Deep"), withIntermediateDirectories: true)
        let members = (1 ... 40).map { "    func crossing\($0)() -> Int {\n        let count = \($0)\n        let doubled = count * 2\n        return doubled + count\n    }" }
        try ("/// A crossing.\nstruct Crossing {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: reached.appendingPathComponent("Depot.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: root.appendingPathComponent("Other/Deep"))
        try await SiftEngine(directory: root).ensureFresh()

        let match = try #require(InPlaceShape.match(forShell: "cd Link && cat ../Sources/App/Depot.swift", in: root.path))
        guard case let .answered(answered) = try await Self.answer(match.call, from: match.directory) else {
            Issue.record("expected the file the link reaches answered")
            return
        }

        #expect(answered.reason.contains("struct Crossing"), "\(answered.reason)")
        #expect(!answered.reason.contains("struct Depot"), "\(answered.reason)")
    }
}

/// A read behind a move that cannot happen, kept apart from the suite body it would push past its length.
extension InPlaceAnswerTests {
    /// A `cd` to a dangling link, a link that loops, or a path that is not there fails in the real shell — nothing after an `&&` runs, and after a `;` a relative read runs in the directory the line started in — so a window behind one is never answered in place, while the same window behind a `cd` into a directory that is there still is.
    @Test(arguments: ["Dang", "Loop", "Missing"], [
        "cd TARGET && sed -n 1,40p ../Sources/App/Depot.swift",
        "cd TARGET; sed -n 1,40p ../Sources/App/Depot.swift",
        "cd TARGET && sed -n 1,40p ../Sources/App/Depot.swift || echo gone",
    ])
    func aWindowBehindACdThatCannotMoveIsNotAnsweredInPlace(target: String, template: String) throws {
        let root = try TemporaryDirectory.make("cd-nowhere")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Dang").path, withDestinationPath: "Gone")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Loop").path, withDestinationPath: "Loop")

        #expect(InPlaceShape.match(forShell: template.replacingOccurrences(of: "TARGET", with: "Real"), in: root.path) != nil)
        #expect(InPlaceShape.match(forShell: template.replacingOccurrences(of: "TARGET", with: target), in: root.path) == nil)
    }
}

/// How the opening line names a call, kept apart from the suite body it would push past its length.
extension InPlaceAnswerTests {
    /// A target with a space in it is named quoted in the opening line, so the call it names is one target when re-typed, while the usage log keeps the target as it is.
    @Test
    func aTargetWithASpaceIsNamedQuoted() async throws {
        let root = try await Self.indexedRepository()
        let written = try Self.document(in: root)
        let spaced = root.appendingPathComponent("Docs/My Plan.md")
        try FileManager.default.moveItem(at: written, to: spaced)

        let read = try #require(InPlaceShape.call(forRead: spaced.path))
        guard case let .answered(answered) = try await Self.answer(read, from: root.path, backoff: Self.backoff()) else {
            Issue.record("expected an answer")
            return
        }

        #expect(answered.reason.hasPrefix("sift answered this with `digest 'Docs/My Plan.md'` instead of running it"))
        #expect(answered.calls.map(\.target) == ["Docs/My Plan.md"])
    }
}
