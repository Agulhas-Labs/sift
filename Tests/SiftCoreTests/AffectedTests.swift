//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` against a *really built* index store whose units cover the test target: the resolved walk, its depth bound, the two runner spellings, and — the ones that matter most — that the answer states its own incompleteness and that a stale store never produces a confident list.
///
/// **Serialized, frugal with builds, and building off the concurrency pool.** Each fixture that needs resolved references pays a `swift build --build-tests`, and one per test is too many: eight of them starve the pool enough to miss the ten-second deadline in `ProcessStreamsTests` about one run in five, with nothing about the code under test having changed. Assertions that can share a fixture do, the two that need no store at all build nothing, and what is left is awaited through `TestSources.swiftBuildSuspending` rather than blocking a worker for the length of a build. A suite whose cost lands on *other* suites' timing is a suite that has to be measured, not just written.
@Suite(.serialized, .temporaryDirectories)
struct AffectedTests {
    private static func manifest() -> String {
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

    private static func core(extra: String) -> String {
        """
        public struct Widget {
            public init() {}
            public func polish() {}
        \(extra)
        }
        """
    }

    /// The package: a type, a library helper that is the only thing one suite names, and two suites reaching the type at different distances.
    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write(core(extra: ""), to: "Sources/Lib/Core.swift", in: root)
        // The helper is the *only* thing IndirectTests names, so the changed type is genuinely two hops away rather than one hop wearing a wrapper.
        try TestSources.write(
            """
            public func polishedLabel() -> String {
                let widget = Widget()
                widget.polish()
                return "polished"
            }
            """,
            to: "Sources/Lib/Helper.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct DirectTests {
                @Test func usesWidgetDirectly() {
                    Widget().polish()
                }
            }
            """,
            to: "Tests/LibTests/DirectTests.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct IndirectTests {
                @Test func reachesWidgetThroughTheHelper() {
                    #expect(polishedLabel() == "polished")
                }
            }
            """,
            to: "Tests/LibTests/IndirectTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        // The change under test, left uncommitted so the working tree has something to report.
        try TestSources.write(core(extra: "    public func shine() {}"), to: "Sources/Lib/Core.swift", in: root)
        return root
    }

    /// The same package, built after the change so the store covers it.
    ///
    /// The order is the point. A working tree's dirty files are normally newer than the last build and therefore refused — a real state with its own test below — and this is the other real state, the one a gate is in, where the build already covers the change. It is the only state in which the resolved walk can be observed at all.
    ///
    /// `includingTests` is what makes a *resolved* answer possible, and it is also the expensive half, so a test that only needs the store to predate an edit passes `false` and pays for the library alone.
    private static func makeBuiltRepo(includingTests: Bool = true) async throws -> URL {
        let root = try makeRepo()
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: includingTests)
        return root
    }

    private static func affected(_ root: URL, depth: Int = AffectedOptions.defaultDepth, range: AffectedOptions.CommitRange? = nil) async throws -> String {
        let engine = try SiftEngine(directory: root)
        // The store is read here, never while it loads: a cold open that overruns the query's budget answers `warming`,
        // which under load reached these assertions as a failure that had nothing to do with the tree.
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: range, depth: depth), freshness: freshness)
    }

    /// The resolved walk, and the bound on it — one fixture, because the depth assertion is the same query asked one hop shorter and a second `--build-tests` for it is the suite's most expensive line.
    @Test
    func aResolvedWalkReachesTheHelperCaseAtTwoHopsAndStopsWhereItIsToldTo() async throws {
        let root = try await Self.makeBuiltRepo()

        let output = try await Self.affected(root)
        let shallow = try await Self.affected(root, depth: 1)

        #expect(output.contains("mode: syntactic + semantic (index store via .build)"))
        #expect(output.contains("semantic: fresh"))
        #expect(output.contains("Sources/Lib/Core.swift — added or modified"))
        #expect(output.contains("LibTests.DirectTests/usesWidgetDirectly() — 1 hop"))
        // The transitive case, and the reason the default depth is two: nothing in IndirectTests spells `Widget`.
        #expect(output.contains("LibTests.IndirectTests/reachesWidgetThroughTheHelper() — 2 hops"))
        #expect(output.contains("-only-testing:LibTests/DirectTests/usesWidgetDirectly()"))
        #expect(output.contains("-only-testing:LibTests/IndirectTests/reachesWidgetThroughTheHelper()"))
        #expect(output.contains(#"swift test --filter 'LibTests\.DirectTests/usesWidgetDirectly\(\)'"#))
        // The limits ride the strongest answer this command can produce, which is where over-trust starts.
        #expect(output.contains(AffectedBlindSpots.heading))
        #expect(output.contains("it reports, it does not run, and it never decides what to leave out"))
        #expect(!output.contains("xcodebuild test"))

        // A bounded walk is bounded, and the bound is visible in the answer rather than only in the depth this run happened to use.
        #expect(shallow.contains("depth: 1 reference hop from the changed declarations"))
        #expect(shallow.contains("the reference walk stops at 1 hop"))
        #expect(shallow.contains("LibTests.DirectTests/usesWidgetDirectly()"))
        #expect(!shallow.contains("reachesWidgetThroughTheHelper"))
    }

    /// The load-bearing negative: the answer says what it could not determine, in the answer, by default, above the list.
    ///
    /// Asserted on the *weakest* answer — no store at all — because that is where the list is least trustworthy and the block most needed; the strongest answer carries it too, which the resolved-walk test above pins.
    @Test
    func everyAnswerStatesItsOwnIncompletenessBeforeItListsAnything() async throws {
        let output = try await Self.affected(Self.makeRepo())

        #expect(output.contains("what this cannot see — read before trusting the list below:"))
        #expect(output.contains("#selector"))
        #expect(output.contains("macro-generated code is invisible to the parser"))
        #expect(output.contains("resources, fixtures and golden files loaded by name"))
        #expect(output.contains("comments and string literals are not indexed"))
        #expect(output.contains("this is a lower bound, not a safe-to-skip set"))
        #expect(output.contains("A green run of only these tests is not a green suite."))

        let limits = try #require(output.range(of: "what this cannot see"))
        let list = try #require(output.range(of: "affected tests ("))
        // Placement is the point: a caveat below the content is a caveat read after the decision.
        #expect(limits.lowerBound < list.lowerBound)
    }

    /// The other load-bearing negative: a store that predates the edit must refuse, not answer.
    @Test
    func aStoreOlderThanTheEditRefusesRatherThanListingConfidently() async throws {
        // No test units needed: the refusal is about the *changed* file's own declarations, and what answers instead is a name match over the working tree.
        let root = try await Self.makeBuiltRepo(includingTests: false)
        // Written after the build, which is the ordinary state of a working tree mid-edit.
        try TestSources.write(Self.core(extra: "    public func buff() {}"), to: "Sources/Lib/Core.swift", in: root)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("was changed since the last build; rebuild with `sift run -- swift build`, then retry"))
        #expect(output.contains("semantic: stale (1 file changed since last build)"))
        #expect(!output.contains("semantic: fresh"))
        // What it offers instead is spelled as a different kind of claim, never as a weaker version of the same one.
        #expect(output.contains("**A name is not a symbol**"))
        #expect(output.contains("name match"))
    }

    /// With no store the answer must not look resolved — an empty, clean-looking list is the one way this command does harm.
    @Test
    func withNoIndexStoreTheAnswerRefusesToLookResolvedAtAll() async throws {
        let output = try await Self.affected(Self.makeRepo())

        #expect(output.contains("resolved references: UNAVAILABLE"))
        #expect(output.contains("NAME MATCH ONLY"))
        #expect(output.contains("semantic: none (no index store — see note)"))
        #expect(output.contains("no index store for this tree yet — build one:"))
        // The where-worded tail ("declarations still answer... callers, overrides... do not") is off-topic
        // for affected, which answers with tests, not declarations — "resolved references: UNAVAILABLE"
        // above already says what affected itself cannot do.
        #expect(!output.contains("declarations still answer from syntax"))
        #expect(!output.contains("semantic: fresh"))
        // A name match still finds the suite that spells `Widget`, and it is labelled as one.
        #expect(output.contains("LibTests.DirectTests/usesWidgetDirectly()"))
        #expect(output.contains("name match"))
    }

    /// The "N ways of being wrong" the empty answer cites is counted from the block, not written into the sentence.
    ///
    /// A literal "six ways" — the length of the permanent list — would be wrong wherever the block it points at prints between seven and ten, the extra ones being exactly the limits that apply to *this* answer. A number a reader can check by counting is the one number that must never be a literal.
    @Test
    func theWaysTheEmptyAnswerCanBeWrongAreCountedFromTheBlockItself() async throws {
        let output = try await Self.affected(Self.makeConfiguredRepo(
            config: #"{"exclude":["Legacy/"]}"#,
            seeding: ["Sources/Legacy/Old.swift"],
            changing: ["Sources/Legacy/Old.swift"]
        ))

        let bullets = output.split(separator: "\n").count { $0.hasPrefix("  · ") }
        // Six permanent, the depth clause, and the configuration narrowing this fixture triggers.
        #expect(bullets == 8)
        #expect(output.contains("the limits above list \(bullets) ways of being wrong about"))
    }

    /// The name-match count covers every test the arguments select, including the ones a coarsened target never printed.
    ///
    /// A target past the per-test list cap is named whole, so its members are not listed — and the count was taken inside the printed list. That put "25 of the tests listed above rest on a name match" directly above a single `-only-testing:` selecting thirty of them.
    @Test
    func theNameMatchCountCoversEveryTestTheArgumentsSelect() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let tests = (0 ..< 30).map { "    @Test func uses\($0)() { _ = Widget() }" }.joined(separator: "\n")
        try TestSources.write(
            "import Testing\n@testable import Lib\n\nstruct ManyTests {\n\(tests)\n}\n",
            to: "Tests/LibTests/ManyTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)

        let output = try await Self.affected(root)

        #expect(output.contains("30 tests affected — more than this list prints"))
        #expect(output.contains("30 of the tests these select rest on a name match rather than a resolved reference"))
    }

    /// A change whose first hop widens past the name frontier: one changed type, mentioned once inside each of `count` differently-named functions.
    private static func makeWideningRepo(mentions count: Int) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        // Each mention sits in a differently-named function, so hop one hands the next hop one name per
        // function — past the 200 the frontier carries, which is the bound under test.
        let mentions = (0 ..< count).map { "func mention\($0)() { _ = Widget() }" }.joined(separator: "\n")
        try TestSources.write(mentions + "\n", to: "Sources/Lib/Mentions.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        return root
    }

    /// A cap that fires names itself, above the block that tells the reader to look up for it.
    ///
    /// "A size cap stopped the walk … the notes above say which cap" was true of exactly one of the three caps. The other two wrote nothing, and the fallback's own notes were appended *below* the block that points at them — so a change trips a bound, the answer says a cap fired, names none, and points at nothing. Tripped here through the name frontier with the declaration cap untouched, which is the combination that says least.
    @Test
    func aCapOtherThanTheDeclarationCapStillNamesItselfAboveTheLimitsBlock() async throws {
        let root = try Self.makeWideningRepo(mentions: 250)

        let output = try await Self.affected(root)

        #expect(output.contains("a size cap stopped the walk"))
        #expect(output.contains("note: the name-matched fallback carried only 200 names into the next hop"))
        // The cap that fired is not the one that already wrote a note, which is the whole point of the case.
        #expect(!output.contains("only the first 500 declarations were followed"))
        let note = try #require(output.range(of: "note: the name-matched fallback"))
        let block = try #require(output.range(of: AffectedBlindSpots.heading))
        #expect(note.lowerBound < block.lowerBound)
    }

    /// A walk with no next hop to take was not stopped by a cap, and must not report that it was.
    ///
    /// The truncation ran on every hop including the last, over a set the loop discards on the very next line. So `--depth 1` — and any run whose final hop widens — printed "the ones it dropped were not scanned" and a blind spot saying a size cap stopped the walk, about a walk that finished at the depth it was asked for. That bullet is also one of the "N ways of being wrong" the empty answer invites the reader to count, so a limit that never fired inflated a number the block is supposed to make checkable.
    @Test
    func aCapOnTheFinalHopIsNotATruncationBecauseNothingCarriesTheNamesOnward() async throws {
        let root = try Self.makeWideningRepo(mentions: 250)

        let output = try await Self.affected(root, depth: 1)

        #expect(!output.contains("a size cap stopped the walk"))
        #expect(!output.contains("note: the name-matched fallback carried only 200 names"))
        // The walk still ran — this is a hop that completed, not one that never started.
        #expect(output.contains("name-matched fallback: 3 written names were scanned"))
        // Six permanent limits and the depth clause: a false cap bullet would make it eight.
        let bullets = output.split(separator: "\n").count { $0.hasPrefix("  · ") }
        #expect(bullets == 7)
        #expect(output.contains("the limits above list 7 ways of being wrong about"))
    }

    /// The fallback counts the names it actually scanned, not the ones it started with.
    ///
    /// `scannedNames` was captured once from the seed set while `tooCommon` accumulated over every hop, so the two numbers printed one line apart were over different populations — "3 written names … were scanned" above "10 names in that scan … were dropped". A command whose contract is that the reader can check its arithmetic against the limits block cannot print a subset larger than its superset.
    @Test
    func theFallbackCountsEveryNameItCarriedIntoAScan() async throws {
        let root = try Self.makeWideningRepo(mentions: 250)

        let output = try await Self.affected(root)

        // Three seed names — the changed type, its initializer and its new method — then the 200 the frontier carried into hop two.
        #expect(output.contains("name-matched fallback: 203 written names were scanned"))
        #expect(output.contains("note: the name-matched fallback carried only 200 names into the next hop"))
    }

    /// An operator's base name can never match an identifier token, on hop two exactly as in the seed set.
    ///
    /// The seed set has been filtered for this since it was written — `==` is not an identifier, so the visitor comparing against `.identifier(text)` never matches it, while the `source.contains("==")` pre-filter matches nearly every Swift file and buys a full parse of each. The names taken from the declarations hop one landed *in* were checked only for being non-empty, so a changed type declaring a custom `==` carried `"=="` into the next hop and paid for a whole-tree parse that returns nothing.
    @Test
    func anOperatorReachedOnALaterHopIsDroppedExactlyAsOneInTheSeedSetIs() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write(
            """
            public struct Box {}

            public func == (lhs: Box, rhs: Box) -> Bool {
                _ = Widget()
                return true
            }
            """,
            to: "Sources/Lib/Box.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)

        let output = try await Self.affected(root)

        // The three seed names and nothing else: `==` is the only thing hop one turned up, and it never joins them.
        #expect(output.contains("name-matched fallback: 3 written names were scanned"))
    }

    /// The declaring site printed beside a test is decided by the answer, not by a Dictionary's hash seed.
    ///
    /// `mentions` comes back as a dictionary and the first account recorded keeps its `path`/`line`, so one suite reached through twenty names from twenty files took whichever site hash order happened to hand over first — a `— path:line` that changes between runs of the same query on the same tree, with nothing about the tree having changed. The sites *within* one name are sorted for exactly this reason; the loop over the names was not.
    @Test
    func theSitePrintedBesideATestDoesNotDependOnDictionaryOrder() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(), to: "Package.swift", in: root)
        let letters = (0 ..< 20).map { String(UnicodeScalar(UInt8(65 + $0))) }
        try TestSources.write(
            letters.map { "public struct Type\($0) {}" }.joined(separator: "\n") + "\n",
            to: "Sources/Lib/Types.swift",
            in: root
        )
        // One suite, twenty extensions of it, each in its own file and each naming exactly one changed type.
        for letter in letters {
            try TestSources.write(
                """
                import Testing
                @testable import Lib

                extension WidgetTests {
                    @Test func check\(letter)() {}
                    func make\(letter)() { _ = Type\(letter)() }
                }
                """,
                to: "Tests/LibTests/WidgetTests+\(letter).swift",
                in: root
            )
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(
            letters.map { "public struct Type\($0) { public func added() {} }" }.joined(separator: "\n") + "\n",
            to: "Sources/Lib/Types.swift",
            in: root
        )

        let output = try await Self.affected(root)

        // `TypeA` sorts first, so its file is the account that is kept — one answer, not one of twenty.
        #expect(output.contains("LibTests.WidgetTests — 1 hop, name match — Tests/LibTests/WidgetTests+A.swift:"))
    }

    /// The declaration the expansion cap stopped on is handed to the fallback, not lost by both walks.
    ///
    /// The `for … where visited.insert(row.id).inserted` clause has already marked the row visited by the time the guard fires, so a `break` left it expanded by neither walk and asked about by neither — and then did the same to the first row of every remaining hop. `nameWalk` is fed only `semanticWalk.unanswered`, which the two *refusal* branches populate, so a declaration the store could not be asked about **because the cap stopped it** never reached the name-matched fallback that exists for exactly that case. The only trace was the generic cap note, which says the rest of the frontier was not followed and nothing about the row taken off it.
    ///
    /// The store is built *after* the change, so no declaration is refused for staleness: `unanswered` can hold nothing here except what the cap stopped.
    @Test
    func theDeclarationTheExpansionCapStoppedOnReachesTheFallback() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func polish() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        // Past the 1500 declarations the walk expands in total: hop one takes the changed file's own rows and
        // hop two takes one per function here, so the bound fires part-way through the second hop.
        let mentions = (0 ..< 1600).map { "public func mention\($0)() { Widget().polish() }" }.joined(separator: "\n")
        try TestSources.write(mentions + "\n", to: "Sources/Lib/Mentions.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func polish() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let output = try await Self.affected(root)

        #expect(output.contains("note: the resolved walk stopped after expanding 1500 declarations"))
        #expect(output.contains("name-matched fallback: 1 written name was scanned"))
    }

    /// A file that declares nothing is not a file that is gone, and only one of them is missing from the working tree.
    ///
    /// The blind-spot line was fed by "no declaration rows after dropping extensions", which is true of a deleted file *and* of a `main.swift` holding only top-level code. So one answer listed the same path as "added or modified" and then, two lines below, as one of the "changed files not in the working tree" — about a file sitting on disk. The index knows the difference: it has a file row for one and none for the other.
    @Test
    func aFileThatDeclaresNothingIsNotReportedAsMissingFromTheWorkingTree() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("import Foundation\n", to: "Sources/Lib/Imports.swift", in: root)
        try TestSources.write("public struct Gone {}\n", to: "Sources/Lib/Gone.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("import Foundation\n// touched\n", to: "Sources/Lib/Imports.swift", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Gone.swift"))

        let output = try await Self.affected(root)

        #expect(output.contains("Sources/Lib/Imports.swift — added or modified, no declarations in the index"))
        let missing = try #require(output.split(separator: "\n").first { $0.contains("not in the working tree") })
        #expect(missing.contains("1 changed file is not in the working tree"))
        #expect(missing.contains("Sources/Lib/Gone.swift"))
        #expect(!missing.contains("Sources/Lib/Imports.swift"))
    }

    /// An answer that prints `-only-testing:` says where those identifiers can be wrong, and one that prints none does not.
    ///
    /// The caveat ``TestSymbolReader`` promises — "the cost of that choice is stated where it is felt … see `AffectedBlindSpots`" — was promised and never printed. It matters because this is the line the reader *acts* on: an Xcode target named `SampleUITests` built as `SampleUITestsModule` yields an identifier `xcodebuild` rejects by failing the whole invocation, so a selection nobody checked does not run a subset, it runs nothing.
    @Test
    func anAnswerThatPrintsRunnerArgumentsSaysWhereTheirIdentifiersCanBeWrong() async throws {
        let listing = try await Self.affected(Self.makeRepo())
        let nothing = try await Self.affected(Self.makeConfiguredRepo(
            config: #"{"exclude":["Legacy/"]}"#,
            seeding: ["Sources/Legacy/Old.swift"],
            changing: ["Sources/Legacy/Old.swift"]
        ))

        #expect(listing.contains("-only-testing:"))
        #expect(listing.contains("PRODUCT_MODULE_NAME"))
        #expect(listing.contains("it fails the whole invocation rather than skipping that selection"))
        // Answer-scoped, like every other conditional caveat here: an answer selecting nothing has no
        // identifier to be wrong about, and a block padded with inapplicable warnings stops being read.
        #expect(!nothing.contains("-only-testing:"))
        #expect(!nothing.contains("PRODUCT_MODULE_NAME"))
    }

    /// A repository that narrows what it indexes, with `body` written into every path in `changing` after the seed commit.
    ///
    /// No manifest and no build: what these fixtures test happens before any of that, in the filter between the diff and the walk.
    private static func makeConfiguredRepo(config: String, seeding paths: [String], changing changed: [String]) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(config, to: ".sift.json", in: root)
        for path in paths {
            try TestSources.write("public struct \(path.split(separator: "/").last.map { $0.dropLast(6) } ?? "Thing") {}\n", to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        for path in changed {
            try TestSources.write("public struct Changed\(changed.firstIndex(of: path) ?? 0) { public func added() {} }\n", to: path, in: root)
        }
        return root
    }

    /// A change this repository's own `exclude` dropped is named, not counted as nothing.
    ///
    /// "Nothing changed — no .swift file differs" is a statement about the working tree, and it was false: the filter that keeps `.build` out of the question also applies `exclude` and `roots`, and it ran before the count was taken, so the paths it removed left no trace in the answer at all. `git diff --name-only HEAD` said otherwise.
    @Test
    func aChangeTheConfigExcludedIsNamedRatherThanCountedAsNothing() async throws {
        let root = try Self.makeConfiguredRepo(
            config: #"{"exclude":["Legacy/"]}"#,
            seeding: ["Sources/Lib/Kept.swift", "Sources/Legacy/Old.swift"],
            changing: ["Sources/Legacy/Old.swift"]
        )

        let output = try await Self.affected(root)

        #expect(!output.contains("nothing changed — no .swift file differs"))
        #expect(output.contains("1 changed .swift file is outside the indexed roots or excluded by `.sift.json` and was not examined: Sources/Legacy/Old.swift"))
        // The blind spot has to be readable *before* the empty list it explains, like every other one.
        let limits = try #require(output.range(of: "outside the indexed roots"))
        let list = try #require(output.range(of: "no test references found"))
        #expect(limits.lowerBound < list.lowerBound)
    }

    /// The case this command exists for: a monorepo indexing one surface still says what it did not look at on the other.
    ///
    /// `roots: ["app"]` on a two-surface product is the ordinary configuration, not a corner — and it made every edit under `web/` report "nothing changed". Asserted on a *mixed* change set, because the narrowing has to stay visible in an answer that also has something to say, which is where it is easiest to miss.
    @Test
    func aChangeOutsideTheConfiguredRootsIsNamedBesideTheOnesInside() async throws {
        let root = try Self.makeConfiguredRepo(
            config: #"{"roots":["app"]}"#,
            seeding: ["app/Sources/Screen.swift", "web/Sources/Page.swift"],
            changing: ["app/Sources/Screen.swift", "web/Sources/Page.swift"]
        )

        let output = try await Self.affected(root)

        #expect(output.contains("changed files (1)"))
        #expect(output.contains("app/Sources/Screen.swift — added or modified"))
        #expect(output.contains("1 changed .swift file is outside the indexed roots or excluded by `.sift.json` and was not examined: web/Sources/Page.swift"))
    }

    /// A commit range is the gate's change set and goes through the same walk; committing it then leaves the working tree with nothing to report, which is the answer most able to be misread.
    @Test
    func aCommitRangeIsReadThroughTheSameWalkAndAnEmptyResultSaysWhatItDoesNotMean() async throws {
        let root = try await Self.makeBuiltRepo()
        try TestSources.commitAll(in: root, message: "change Widget")

        let ranged = try await Self.affected(root, range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD"))
        let empty = try await Self.affected(root)

        #expect(ranged.contains("affected tests — changed: HEAD~1..HEAD"))
        #expect(ranged.contains("Sources/Lib/Core.swift — added or modified"))
        #expect(ranged.contains("LibTests.DirectTests/usesWidgetDirectly() — 1 hop"))

        #expect(empty.contains("(nothing changed — no .swift file differs)"))
        #expect(empty.contains("no test references found within 2 hops."))
        #expect(empty.contains("that is not evidence that no test is affected"))
        #expect(empty.contains("Run the full suite."))
    }
}
