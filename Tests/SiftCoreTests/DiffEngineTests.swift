//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `sift diff` end to end: a real git repository, `SiftEngine.diff` driving the whole gathering step — range resolution, both sides read from git or disk, every touched file listed, the callers and tests sections, and the size line.
@Suite(.temporaryDirectories)
struct DiffEngineTests {
    static func manifest() -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    static func widget(body: String) -> String {
        """
        public struct Widget {
            public var count: Int

            public init(count: Int) {
                self.count = count
            }
        \(body)
        }
        """
    }

    static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write(
            widget(body: """
                public func polish() -> Int {
                    count
                }
            """),
            to: "Sources/Lib/Widget.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct WidgetTests {
                @Test func polishReturnsCount() {
                    #expect(Widget(count: 3).polish() == 3)
                }
            }
            """,
            to: "Tests/LibTests/WidgetTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    static func diff(_ root: URL, range: String? = nil, member: String? = nil, offset: Int = 0) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let resolvedRange = try DiffRange.resolve(range, git: GitContext(repoRoot: root))
        let options = DiffOptions(range: resolvedRange, member: member, offset: offset)
        return try await engine.diff(options: options, freshness: freshness)
    }

    static func polishReturningString() -> String {
        widget(body: """
            public func polish() -> String {
                "polished \\(count)"
            }
        """)
    }

    // MARK: Declarations

    @Test func aChangedSignatureShowsBeforeAndAfterWithTheAfterSideRange() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(
            Self.widget(body: """
                public func polish() -> String {
                    "polished \\(count)"
                }

                public func shine() -> Int {
                    count * 2
                }
            """),
            to: "Sources/Lib/Widget.swift",
            in: root
        )
        let output = try await Self.diff(root)

        #expect(output.contains("diff: working tree vs HEAD"))
        #expect(output.contains("Sources/Lib/Widget.swift (modified, +6/-2):"))
        #expect(output.contains("~ func polish()"))
        #expect(output.contains("before: public func polish() -> Int"))
        #expect(output.contains("after:  public func polish() -> String"))
        #expect(output.contains("+ func shine()"))
    }

    /// A file's heading says which of the three it is — not "added or modified" for both.
    @Test func aFileHeadingSaysWhetherItWasAddedModifiedOrDeleted() async throws {
        let root = try Self.makeRepo()
        try TestSources.write("public struct Gadget {}\n", to: "Sources/Lib/Gadget.swift", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Tests/LibTests/WidgetTests.swift"))
        let output = try await Self.diff(root)

        #expect(output.contains("Sources/Lib/Gadget.swift (added, +1/-0):"))
        #expect(output.contains("Tests/LibTests/WidgetTests.swift (deleted, +0/-8):"))
    }

    /// The overriding rule: a Swift file whose change is outside every declaration is still listed, with what changed.
    @Test func aSwiftFileChangedOnlyOutsideItsDeclarationsIsListedWithWhatChanged() async throws {
        let root = try Self.makeRepo()
        let original = try String(contentsOf: root.appendingPathComponent("Sources/Lib/Widget.swift"), encoding: .utf8)
        try TestSources.write("import Foundation\n\n" + original, to: "Sources/Lib/Widget.swift", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("1 of 1 file changed only outside declarations"))
        #expect(output.contains("Sources/Lib/Widget.swift (modified, +2/-0):"))
        #expect(output.contains("outside declarations:"))
        #expect(output.contains("+ import Foundation  :1"))
    }

    @Test func aDeclarationUnderAConditionPrintsIt() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(
            Self.widget(body: """
                #if DEBUG
                public func polish() -> Int {
                    count
                }
                #endif
            """),
            to: "Sources/Lib/Widget.swift",
            in: root
        )
        let output = try await Self.diff(root)

        #expect(output.contains("~ func polish()  :8-10 [#if DEBUG]"))
        #expect(output.contains("condition: (none) → #if DEBUG"))
        #expect(output.contains("+ #if DEBUG  :7"))
    }

    // MARK: Files that are not broken down

    /// A manifest and a vendored source are Swift the index never holds: each is listed, with its counts and the rule, instead of vanishing.
    @Test func swiftFilesTheIndexNeverHoldsAreListedWithCountsAndTheReason() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(Self.manifest() + "\n// tools\n", to: "Package.swift", in: root)
        try TestSources.write("public struct Pod {}\n", to: "Vendor/Pods/Pod/Pod.swift", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("2 Swift files not broken down"))
        #expect(output.contains("Package.swift  +2/-1 — not indexed: it is a build manifest"))
        #expect(output.contains("Vendor/Pods/Pod/Pod.swift  +1/-0 — not indexed:"))
        #expect(!output.contains("nothing changed"))
    }

    @Test func aChangeTheConfigExcludedIsNamedRatherThanCountedAsNothing() async throws {
        let root = try Self.makeRepo()
        try TestSources.write("{\"exclude\": [\"Widget\"]}", to: ".sift.json", in: root)
        try TestSources.commitAll(in: root, message: "config")
        try TestSources.write(Self.polishReturningString(), to: "Sources/Lib/Widget.swift", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("Sources/Lib/Widget.swift  +2/-2 — not indexed: .sift.json excludes paths containing \"Widget\""))
    }

    /// Listed, said to be unreadable — and headed by what happened to it, which here is that it was added.
    @Test func aFileThatIsNotUTF8TextIsListedAndSaidToBeUnreadable() async throws {
        let root = try Self.makeRepo()
        try Data([0x2F, 0x2F, 0x20, 0xE9, 0x0A]).write(to: root.appendingPathComponent("Sources/Lib/Latin.swift"))
        let output = try await Self.diff(root)

        #expect(output.contains("Sources/Lib/Latin.swift (added"))
        #expect(output.contains("not UTF-8 text on the after side"))
        #expect(!output.contains("changed only outside declarations"))
    }

    // MARK: Non-Swift files

    @Test func nonSwiftFilesReportPathAndLineCounts() async throws {
        let root = try Self.makeRepo()
        try TestSources.write("seed\nchanged\n", to: "README.md", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("non-swift files (1):"))
        #expect(output.contains("README.md  +1/-0"))
    }

    /// `git diff --numstat` never lists an untracked file at all — the one gap that has, and the one case read straight off disk instead.
    @Test func anUntrackedNonSwiftFileIsCountedByReadingItDirectly() async throws {
        let root = try Self.makeRepo()
        try TestSources.write("one\ntwo\nthree\n", to: "config.json", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("config.json  +3/-0"))
    }

    @Test func anUntrackedBinaryFileIsSaidToBeBinary() async throws {
        let root = try Self.makeRepo()
        try Data([0x89, 0x50, 0x00, 0x01, 0x02]).write(to: root.appendingPathComponent("logo.png"))
        let output = try await Self.diff(root)

        #expect(output.contains("logo.png  (binary)"))
    }

    /// A rename with a one-line edit is counted for its edit, under its new path — not as a whole-file addition.
    @Test func aRenamedNonSwiftFileIsCountedForItsEdit() async throws {
        let root = try Self.makeRepo()
        let guide = (1 ... 40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try TestSources.write(guide, to: "docs/old.md", in: root)
        try TestSources.commitAll(in: root, message: "guide")
        try TestSources.runGit(["mv", "docs/old.md", "docs/new.md"], in: root)
        try TestSources.write(guide.replacingOccurrences(of: "line 20\n", with: "line twenty\n"), to: "docs/new.md", in: root)
        try TestSources.commitAll(in: root, message: "rename")
        let output = try await Self.diff(root, range: "HEAD")

        #expect(output.contains("docs/new.md  +1/-1 (renamed from docs/old.md)"))
    }

    // MARK: Ranges

    @Test func aRangeBetweenTwoCommitsDiffsExactlyThoseTwoRevisions() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(
            Self.widget(body: """
                public func polish() -> Int {
                    count
                }

                public func shine() -> Int {
                    count * 2
                }
            """),
            to: "Sources/Lib/Widget.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "add shine")
        let output = try await Self.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("diff: HEAD~1..HEAD"))
        #expect(output.contains("+ func shine()"))
        #expect(!output.contains("~ func polish()"))
    }

    @Test func aSingleCommitDiffsItsOwnChangeAgainstItsParent() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(Self.polishReturningString(), to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "polish a string")
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        let bare = try await Self.diff(root, range: head)
        let caretBang = try await Self.diff(root, range: "HEAD^!")

        #expect(bare.contains("diff: \(head) — that commit against its parent"))
        #expect(bare.contains("~ func polish()"))
        #expect(caretBang.contains("~ func polish()"))
        #expect(caretBang.contains("1 changed"))
    }

    /// Three dots are the branch against where it parted from `main` — a type only `main` added since is not the branch's, and never reads as removed by it.
    @Test func threeDotsReviewOnlyWhatTheRightSideDid() async throws {
        let root = try Self.makeRepo()
        try TestSources.runGit(["branch", "feature"], in: root)
        try TestSources.write("public struct Gadget {}\n", to: "Sources/Lib/Gadget.swift", in: root)
        try TestSources.commitAll(in: root, message: "main adds a type")
        try TestSources.runGit(["switch", "-q", "feature"], in: root)
        try TestSources.write(Self.polishReturningString(), to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "feature changes polish")

        let output = try await Self.diff(root, range: "main...feature")

        #expect(output.contains("diff: main...feature — feature against its merge-base with main"))
        #expect(output.contains("~ func polish()"))
        #expect(!output.contains("Gadget"))
    }

    @Test func aRootCommitReadsAsEverythingAdded() async throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.runGit(["init", "-q", "-b", "main"], in: root)
        try TestSources.runGit(["config", "user.email", "test@example.com"], in: root)
        try TestSources.runGit(["config", "user.name", "Tester"], in: root)
        try TestSources.write("public struct Widget {\n    public func polish() {}\n}\n", to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "root")

        let output = try await Self.diff(root.resolvingSymlinksInPath(), range: "HEAD")

        #expect(output.contains("a root commit, against the empty tree"))
        #expect(output.contains("Sources/Lib/Widget.swift (added, +3/-0):"))
        #expect(output.contains("+ struct Widget  :1-3 (1 member)"))
    }

    // MARK: Test names, callers and tests

    @Test func theTestFilesSectionListsAddedAndRemovedTestNames() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct WidgetTests {
                @Test func shineDoublesTheCount() {
                    #expect(Widget(count: 3).polish() == 3)
                }
            }
            """,
            to: "Tests/LibTests/WidgetTests.swift",
            in: root
        )
        let output = try await Self.diff(root)

        #expect(output.contains("test files — tests recognised by shape"))
        #expect(output.contains("- polishReturnsCount()"))
        #expect(output.contains("+ shineDoublesTheCount()"))
    }

    /// Callers of a changed signature are listed under that member — here name-matched, since a temporary repository has no index store, and labelled as exactly that.
    @Test func aChangedSignaturesCallersAreListedAndSayHowTheyWereFound() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(Self.polishReturningString(), to: "Sources/Lib/Widget.swift", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("callers of the 1 member this range removed or changed the signature of"))
        #expect(output.contains("~ Widget.polish() — name-matched on \"polish\" (no index store is in use): 1 call site"))
        #expect(output.contains("Tests/LibTests/WidgetTests.swift:6  in WidgetTests.polishReturnsCount()"))
        #expect(!output.contains("via `sift affected`"))
    }

    /// Files are compared concurrently and land in the order they finish; the capped callers list must still be the same list on every run.
    @Test func callersAreListedInPathOrderWhateverOrderTheyWereGatheredIn() throws {
        func report(_ path: String, _ label: String) -> DiffCallers.Report {
            let target = DiffCallers.Target(label: label, name: "polish()", kind: .function, path: path, line: 1, removed: true)
            return DiffCallers.Report(target: target, unresolvedBecause: "removed", searchedName: "polish", sites: [])
        }
        let range = DiffRange(from: "HEAD", to: .workingTree, described: "working tree vs HEAD")
        let output = DiffRenderer.render(DiffRenderer.Input(
            range: range,
            files: [],
            notBrokenDown: [],
            nonSwift: [],
            callers: [report("Sources/B.swift", "Second.polish()"), report("Sources/A.swift", "First.polish()")],
            workingTreeIsAfterSide: true,
            tests: nil,
            options: DiffOptions(range: range),
            rawDiffBytes: 0,
            axis: .syntacticOnly
        )).body
        let first = try #require(output.range(of: "First.polish()"))
        let second = try #require(output.range(of: "Second.polish()"))

        #expect(first.lowerBound < second.lowerBound)
    }

    /// The tests section is what it says: tests `affected` finds reaching the changed files, bounded, pointing at `affected` for its limits.
    @Test func theTestsSectionIsLabelledAsTestsReachingTheChangedFiles() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(Self.polishReturningString(), to: "Sources/Lib/Widget.swift", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("tests reaching the changed files (1 test in 1 target) — from `sift affected`"))
        #expect(output.contains("LibTests.WidgetTests"))
        #expect(output.contains("the runner arguments: `sift affected`"))
        #expect(!output.contains("what this cannot see — read before trusting the list below"))
    }

    // MARK: The member option

    @Test func memberShowsBeforeAndAfterBodyForOneChangedDeclaration() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(Self.polishReturningString(), to: "Sources/Lib/Widget.swift", in: root)
        let output = try await Self.diff(root, member: "Widget.polish")

        #expect(output.contains("Widget.polish() (func)"))
        #expect(output.contains("before (HEAD):"))
        #expect(output.contains("public func polish() -> Int {"))
        #expect(output.contains("after (working tree):"))
        #expect(output.contains("public func polish() -> String {"))
    }

    @Test func memberNamingSomethingThatDidNotChangeRefusesRatherThanGuessing() async throws {
        let root = try Self.makeRepo()
        let output = try await Self.diff(root, member: "Widget.count")

        #expect(output.contains("is not among the declarations changed by"))
    }

    /// Every address an ambiguity refusal lists is accepted back as written, so two overloads sharing a label can each be selected (Docs/AnswerContract.md §5).
    @Test func anAmbiguityRefusalsAddressesAreAcceptedBack() async throws {
        let root = try Self.makeRepo()
        try TestSources.write(
            Self.widget(body: """
                public func polish(_ x: Int) -> Int { x }
                public func polish(_ x: String) -> Int { 0 }
            """),
            to: "Sources/Lib/Widget.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "overloads")
        try TestSources.write(
            Self.widget(body: """
                public func polish(_ x: Int) -> Int { x + 1 }
                public func polish(_ x: String) -> Int { 1 }
            """),
            to: "Sources/Lib/Widget.swift",
            in: root
        )

        let refusal = try await Self.diff(root, member: "Widget.polish")
        let addresses = refusal.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  "), let end = line.range(of: " — ") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 2) ..< end.lowerBound])
        }

        #expect(refusal.contains("is ambiguous — 2 changed declarations match"))
        #expect(addresses.count == 2)
        for address in addresses {
            let answer = try await Self.diff(root, member: address)
            #expect(answer.contains("before (HEAD):"), "\(address) → \(answer)")
            #expect(!answer.contains("is ambiguous"))
        }
    }

    // MARK: Paging and pricing

    /// A large change pages its declarations on the codebase's own cursor, and says how many are left — nothing past the cap is dropped silently.
    @Test func theDeclarationsSectionPagesOnAnOffset() async throws {
        let root = try Self.makeRepo()
        let functions = (1 ... 130).map { "    public func step\($0)() -> Int { \($0) }" }.joined(separator: "\n")
        try TestSources.write("public struct Stepper {\n\(functions)\n}\n", to: "Sources/Lib/Stepper.swift", in: root)
        try TestSources.commitAll(in: root, message: "steps")
        try TestSources.write(
            "public struct Stepper {\n\(functions.replacingOccurrences(of: "{ ", with: "{ 0 + "))\n}\n",
            to: "Sources/Lib/Stepper.swift",
            in: root
        )

        let first = try await Self.diff(root)
        let second = try await Self.diff(root, offset: DiffRenderer.pageCap)

        #expect(first.contains("truncated: 30 more declaration entries across 1 file — pass --offset 100"))
        #expect(first.components(separatedBy: "(body changed; signature unchanged)").count - 1 == DiffRenderer.pageCap)
        #expect(second.components(separatedBy: "(body changed; signature unchanged)").count - 1 == 30)
        #expect(second.contains("drop --offset for them"))
    }

    /// Tokens, at the ratio every other surface uses, with the bytes both ways beside the estimate.
    @Test func theSizeLineStatesTokensSavedWithTheByteBasis() async throws {
        let root = try Self.makeRepo()
        let lines = (1 ... 400).map { "    public func step\($0)() -> Int { \($0) }" }.joined(separator: "\n")
        try TestSources.write("public struct Stepper {\n\(lines)\n}\n", to: "Sources/Lib/Stepper.swift", in: root)
        let output = try await Self.diff(root)
        let sizeLine = try #require(output.split(separator: "\n").last)

        #expect(sizeLine.hasPrefix("size: ~"))
        #expect(sizeLine.contains("tokens saved — raw `git diff` "))
        #expect(sizeLine.contains("% smaller), at 4 bytes a token"))
    }

    /// An untracked file is part of what the answer covers, so it is part of what the answer is priced against — at exactly what `git diff` prints for it once git knows of it.
    @Test func theWorkingTreeBaselineIncludesUntrackedFiles() async throws {
        let root = try Self.makeRepo()
        try TestSources.write((1 ... 200).map { "row \($0)" }.joined(separator: "\n"), to: "notes.txt", in: root)
        let range = try DiffRange.resolve(nil, git: GitContext(repoRoot: root))
        let engine = try SiftEngine(directory: root)
        let gatherer = DiffGatherer(git: GitContext(repoRoot: root), enumerator: FileEnumerator(repoRoot: root, config: SiftConfig()), store: engine.store, repoRoot: root, projectDirectories: [])

        let untracked = try await gatherer.diff(options: DiffOptions(range: range), semantic: .inactive(note: "")).rawDiffBytes
        try TestSources.runGit(["add", "--intent-to-add", "notes.txt"], in: root)
        let known = try GitContext(repoRoot: root).diffByteCount(from: "HEAD")

        #expect(untracked == known)
    }

    /// The figure counts the whole answer — header, notes, and the size line itself.
    @Test func theServedFigureIsTheWholeAnswer() throws {
        let answer = "tree: example\ndiff: something\n" + String(repeating: "x", count: 400)
        let priced = DiffRenderer.priced(answer, rawBytes: 50000)
        let served = try #require(priced.firstMatch(of: /this answer (\d+) B/)?.output.1)

        #expect(Int(served) == priced.utf8.count)
    }

    @Test func anAnswerLargerThanTheRawDiffSaysSoPlainly() {
        let priced = DiffRenderer.priced(String(repeating: "x", count: 800), rawBytes: 200)

        #expect(priced.contains("size: no saving at this size — raw `git diff` 200 B → this answer"))
        #expect(!priced.contains("smaller"))
    }
}

// MARK: - Callers of a changed subscript

extension DiffEngineTests {
    /// A subscript is used as `x[…]`, which spells no name, so with no store it has no name-matched stand-in: its line says so rather than counting no call sites of "subscript", which reads as dead code — and the disclaimer about name matches stays off an answer that made none.
    @Test func aChangedSubscriptWithNoStoreSaysItHasNoNameToMatch() async throws {
        func widget(returning type: String, _ value: String) -> String {
            Self.widget(body: """
                public func polish() -> Int {
                    count
                }

                public subscript(slot: Int) -> \(type) {
                    \(value)
                }
            """)
        }
        let root = try Self.makeRepo()
        try TestSources.write(widget(returning: "Int", "count + slot"), to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "subscript")
        try TestSources.write(widget(returning: "String", "\"\\(count + slot)\""), to: "Sources/Lib/Widget.swift", in: root)
        let output = try await Self.diff(root)

        #expect(output.contains("~ Widget.subscript(_:) — not resolved (no index store is in use), and no name to match: a subscript is used as x[…], which spells no name"))
        #expect(!output.contains("name-matched on \"subscript\""))
        #expect(!output.contains("a name match is not a symbol"))
    }
}
