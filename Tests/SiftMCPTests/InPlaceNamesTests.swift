//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The one shape answered without a proof: a tree search for a name or an alternation of names, answered with the `where` calls the refusal would have named — the same call from a shell and from the `Grep` tool, bounded by the same size budget and the same back-off.
@Suite(.temporaryDirectories)
struct InPlaceNamesTests {
    /// A package declaring two types and using them, built with an index store so a `where` has callers to list.
    private static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "public struct Depot {\n    public init() {}\n}\n",
            "Sources/App/Gizmo.swift": "public struct Gizmo {\n    public init() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    var depot = Depot()\n    var second = Gizmo()\n}\n",
            // A subtree of `Sources` holding sites of `Crate` and `Gizmo` and none of `Depot`.
            "Sources/App/Shelf/Crate.swift": "struct Crate {\n    var gizmo = Gizmo()\n}\n",
            // Declared where `Sources` does not reach, so a search of `Sources` for it prints nothing.
            "Tests/AppTests/Orchard.swift": "struct Orchard {\n    var depot = Depot()\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The same package with a line no `where --refs` answer can account for: a comment naming `Depot`, which is text the index holds no site of, so the anchored sweep's proof fails there.
    private static func packageWithAnUnprovableLine() async throws -> URL {
        let root = try await builtPackage()
        try MCPTestRepo.add(["Sources/App/Notes.swift": "// Depot is built once per session\nstruct Notes {}\n"], to: root)
        return root
    }

    /// The `Grep` payload a tree search for `pattern` under `path` is written as.
    private static func grepPayload(_ pattern: String, path: String) -> [String: Any] {
        ["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": pattern, "path": path]]
    }

    /// An unanchored name searched across a tree is one `where` for it, on the shell and through the `Grep` tool alike — the same call from the same reading, so a model refused at one surface and answered at the other is never taught a detour.
    @Test
    func aTreeSearchForOneNameIsTheSameCallOnBothSurfaces() {
        let shell = InPlaceShape.match(forShell: "grep -rn Depot Sources", in: "/repo")
        let tool = InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Depot", "path": "Sources"], in: "/repo")

        // Each surface carries the operands its own spelling gives: the shell's as written, the `Grep`'s resolved,
        // since that surface's directory is the path it searched.
        #expect(shell?.call == .symbols(names: ["Depot"], paths: ["Sources"]))
        #expect(tool?.call == .symbols(names: ["Depot"], paths: ["/repo/Sources"]))
        // The `Grep`'s own path is what roots its answer, as it is what roots the offer the answer stands in for.
        #expect(tool?.directory == "/repo/Sources")
        #expect(tool?.isWholeCommand == true)
        #expect(InPlaceShape.match(forSearchTool: "Glob", input: ["pattern": "Depot", "path": "Sources"], in: "/repo") == nil)
    }

    /// A `Grep` narrowed by a glob is not answered, since the glob bounds the search where the operands do not: a name declared only under `Tests/` would be handed back as found for a search of `Sources/**`, or of `!Tests/**`, that prints nothing.
    ///
    /// Only a glob that picks every Swift file leaves the search where its path put it, and that one keeps the shape.
    @Test(arguments: ["Sources/**/*.swift", "Sources/**", "!Tests/**", "!*Tests.swift", "*.md"])
    func aGrepNarrowedByAGlobIsNotAnswered(glob: String) {
        #expect(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Depot", "glob": glob], in: "/repo") == nil)
        #expect(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Depot", "path": "Sources", "glob": glob], in: "/repo") == nil)
    }

    /// A case-folded search is not the shape on either surface: it prints the sites of every casing, and a `where` for the name as written would list only one casing's — an answer that does not say what the search says.
    @Test
    func aCaseFoldedSearchIsNotAnswered() {
        #expect(InPlaceShape.match(forShell: "grep -rni gadget Sources", in: "/repo") == nil)
        #expect(InPlaceShape.match(forShell: "grep -rn --ignore-case gadget Sources", in: "/repo") == nil)
        #expect(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "gadget", "path": "Sources", "-i": true], in: "/repo") == nil)
        #expect(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "gadget", "path": "Sources", "-i": false], in: "/repo")?.call == .symbols(names: ["gadget"], paths: ["/repo/Sources"]))
    }

    /// A whole-line search (`-x`) is not the shape either: it prints only a line that is the name alone, which a declaration site almost never is, so the loose `where` would answer past what the search itself would print.
    @Test
    func aWholeLineSearchIsNotAnswered() {
        #expect(InPlaceShape.match(forShell: "grep -rnx Gadget Sources", in: "/repo") == nil)
        #expect(InPlaceShape.match(forShell: "grep -rn --line-regexp Gadget Sources", in: "/repo") == nil)
    }

    /// `Self` stands for whichever type is speaking, so a tree search for `Self.x` reads as `x` alone; `T.Type` and `T.self` read as `T`, since neither `.Type` nor `.self` is a member; all three carry the search as the proof their answer is held to.
    @Test
    func aBareDotReadsSelfAndMetatypeExpressionsThroughTheirType() {
        let readings = [("Self.pending", "pending"), (#"'Self\.pending'"#, "pending"), ("Depot.Type", "Depot"), ("Depot.self", "Depot"), (#"'Depot\.Type'"#, "Depot")]
        for (pattern, name) in readings {
            guard case let .symbols(names, paths, _, proof, _)? = InPlaceShape.match(forShell: "grep -rn \(pattern) Sources", in: "/repo")?.call else {
                Issue.record("expected \(pattern) read as a names search")
                continue
            }
            #expect(names == [name], "\(pattern)")
            #expect(paths == ["Sources"])
            #expect(proof != nil, "\(pattern)")
        }
    }

    /// A metatype or self-expression is answered only where every line its search prints is a reference of the type it reads as: spelled in a string literal it is a line no store records, so the search runs, and a `Grep`, which carries no search to prove, is no candidate at all.
    @Test
    func aMetatypeSearchIsAnsweredOnlyWhereItsLinesAreReferences() async throws {
        let root = try await Self.builtPackage()
        try MCPTestRepo.add([
            "Sources/App/Kinds.swift": "struct Kinds {\n    var kind: Gizmo.Type = Gizmo.self\n}\n",
            "Sources/App/Label.swift": "let label = \"Depot.Type and Depot.self\"\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()

        for command in ["grep -rn Depot.Type Sources", "grep -rn Depot.self Sources"] {
            #expect(try await InPlaceAnswerTests.outcome(command, in: root) == .withheld(.notExact), "\(command)")
        }
        for command in ["grep -rn Gizmo.Type Sources", "grep -rn 'Gizmo\\.self' Sources"] {
            let answered = try await InPlaceAnswerTests.answered(command, in: root)
            #expect(answered?.calls.map(\.target) == ["Gizmo"], "\(command)")
            #expect(answered?.reason.hasPrefix("sift answered this with `where Gizmo`") == true, "\(command)")
        }

        #expect(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Gizmo.Type", "path": "Sources"], in: root.path) == nil)
        // Named files are no candidate whatever their lines spell.
        #expect(InPlaceShape.match(forShell: "grep -n Depot.Type Sources/App/Depot.swift Sources/App/Label.swift", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -n Gizmo.Type Sources/App/Kinds.swift", in: root.path) == nil)
    }

    /// A member searched through `Self` is held to the same proof: spelled in a string literal it is a line no store records, so the search runs, while a search printing only its real references is still answered with the member's `where`.
    @Test
    func aSelfMemberSearchIsAnsweredOnlyWhereItsLinesAreReferences() async throws {
        let root = try await Self.builtPackage()
        try MCPTestRepo.add([
            "Sources/App/Tally.swift": "struct Tally {\n    static let ceiling = 3\n    func limit() -> Int { Self.ceiling }\n}\n",
            "Sources/App/Note.swift": "let note = \"Self.ceiling is read at launch\"\nlet other = \"self.ceiling and super.ceiling too\"\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()

        for command in [
            "grep -rn Self.ceiling Sources",
            "grep -rn self.ceiling Sources", "grep -rn super.ceiling Sources",
        ] {
            #expect(try await InPlaceAnswerTests.outcome(command, in: root) == .withheld(.notExact), "\(command)")
        }
        // Named files are no candidate whatever their lines spell.
        for command in ["grep -n Self.ceiling Sources/App/Tally.swift Sources/App/Note.swift", "grep -n Self.ceiling Sources/App/Tally.swift", "grep -rn 'Self\\.ceiling' Sources/App/Tally.swift"] {
            #expect(InPlaceShape.match(forShell: command, in: root.path) == nil, "\(command)")
        }

        #expect(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Self.ceiling", "path": "Sources"], in: root.path) == nil)
    }

    /// The glob that picks every Swift file narrows nothing, so the search is still the shape.
    @Test(arguments: ["*.swift", "**/*.swift", "*.{swift,md}"])
    func aGrepPickingEverySwiftFileIsStillAnswered(glob: String) {
        let tool = InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Depot", "path": "Sources", "glob": glob], in: "/repo")

        #expect(tool?.call == .symbols(names: ["Depot"], paths: ["/repo/Sources"]))
    }

    /// An alternation of names is one `where` per name, in the order the pattern wrote them, on either surface.
    @Test
    func anAlternationOfNamesIsOneCallPerName() {
        let shell = InPlaceShape.match(forShell: "grep -rnE 'Depot|Gizmo' Sources", in: "/repo")
        let tool = InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Depot|Gizmo", "path": "Sources"], in: "/repo")

        #expect(shell?.call == .symbols(names: ["Depot", "Gizmo"], paths: ["Sources"]))
        #expect(tool?.call == .symbols(names: ["Depot", "Gizmo"], paths: ["/repo/Sources"]))
    }

    /// An alternation of more names than the offer itself lists is not answered: past the cap the refusal names five calls and counts the rest, and an answer would serve names the offer never named.
    @Test
    func anAlternationPastTheOffersCapIsNotAnswered() {
        let names = (1 ... IndexSuggestion.callCap + 1).map { "Depot\($0)" }
        let capped = names.joined(separator: "|")
        let atCap = names.dropLast().joined(separator: "|")

        #expect(InPlaceShape.match(forShell: "grep -rnE '\(capped)' Sources", in: "/repo") == nil)
        #expect(InPlaceShape.match(forShell: "grep -rnE '\(atCap)' Sources", in: "/repo")?.call == .symbols(names: Array(names.dropLast()), paths: ["Sources"]))
    }

    /// The answer is one plain `where` per name, its opening line naming every call it is made of, under one freshness header.
    @Test
    func theAnswerIsThePlainWhereTheOfferNames() async throws {
        let root = try await Self.builtPackage()

        let one = try #require(try await InPlaceAnswerTests.answered("grep -rn Depot Sources", in: root))
        let both = try #require(try await InPlaceAnswerTests.answered("grep -rnE 'Depot|Gizmo' Sources", in: root))

        #expect(one.calls.map(\.tool) == ["where"])
        #expect(one.calls.map(\.target) == ["Depot"])
        #expect(one.reason.hasPrefix("sift answered this with `where Depot` instead of running it"))
        #expect(both.reason.hasPrefix("sift answered this with `where Depot`, `where Gizmo` instead of running it"))
        #expect(both.calls.map(\.target) == ["Depot", "Gizmo"])
        // One header over the lot, and each name's own answer under it.
        let answer = try #require(InPlaceAnswer.answer(inReason: both.reason))
        #expect(answer.split(separator: "\n").filter { $0.hasPrefix("tree: ") }.count == 1)
        #expect(answer.contains("where Depot"))
        #expect(answer.contains("where Gizmo"))
    }

    /// Past the size budget the refusal stands as it always did, so the caller's search runs rather than being denied for an answer nobody can afford.
    @Test
    func anAnswerPastTheSizeBudgetIsWithheld() async throws {
        let root = try await Self.builtPackage()
        let call = try #require(InPlaceShape.match(forShell: "grep -rn Depot Sources", in: root.path)?.call)

        let outcome = try await InPlaceAnswerTests.answer(call, from: root.path, sizeBudget: 200)

        #expect(outcome == .withheld(.overSize))
    }

    /// A `where` lists a symbol's callers out of the build's index store, so a repository with none withholds here exactly as the anchored sweep does rather than answering declarations alone.
    @Test
    func aRepositoryWithNoIndexStoreWithholds() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let call = try #require(InPlaceShape.match(forShell: "grep -rn Alpha Sources", in: root.path)?.call)

        let outcome = try await InPlaceAnswerTests.answer(call, from: root.path)

        #expect(outcome == .withheld(.noStore))
    }

    /// The hook answers a `Grep` in place, end to end: the lookup carries the shape, and the real answerer on a built fixture returns the in-place verdict naming the same call the refusal would have.
    @Test
    func theHookAnswersAGrepInPlace() async throws {
        let root = try await Self.builtPackage()
        let backoff = try InPlaceAnswerTests.backoff()
        let directory = try TemporaryDirectory.make("grep-verdict").appendingPathComponent("grep-verdict")
        let lookup = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: Self.grepPayload("Depot", path: root.path),
            in: root.path,
            noting: SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl")),
            couldAnswer: { _, _ in true }
        ))

        #expect(lookup.inPlace?.call == .symbols(names: ["Depot"], paths: [root.path]))

        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
                payload: ["agent_id": "a1"],
                cwd: root.path,
                ledger: AdviceLedger(directory: directory.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl")),
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

        #expect(outcome.verdict.token == "in-place")
        #expect(outcome.verdict.call == "where Depot")
        #expect(outcome.json?.contains("where Depot") == true)
    }

    /// The operands ride with the call and root the answer, so a search of another repository's files is never answered out of the caller's index — which would list this tree's sites for a search that would print none of them.
    @Test
    func aSearchOfAnotherRepositoryIsNotAnsweredFromTheCallersIndex() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let other = try MCPTestRepo.make(declaring: "Alpha")
        let match = try #require(InPlaceShape.match(forShell: "grep -rn Alpha \(other.path)/Sources", in: root.path))

        #expect(match.call == .symbols(names: ["Alpha"], paths: ["\(other.path)/Sources"]))
        #expect(match.directory == root.path)
        #expect(try await InPlaceAnswerTests.answer(match.call, from: match.directory) == .withheld(.outsideRoot))
    }

    /// A name the search's own paths hold no site of is not answered: the search would have printed nothing, and a `where` listing the declaration somewhere else answers "yes, here it is" to a question that asked about `Sources`.
    @Test
    func aSearchWhosePathsHoldNoSiteIsNotAnswered() async throws {
        let root = try await Self.builtPackage()
        let tool = try #require(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Orchard", "path": "Sources"], in: root.path))
        let narrow = try #require(InPlaceShape.match(forShell: "grep -rn Orchard Sources", in: root.path))

        #expect(narrow.call == .symbols(names: ["Orchard"], paths: ["Sources"]))
        #expect(try await InPlaceAnswerTests.answer(narrow.call, from: narrow.directory) == .withheld(.outsideSearch))
        #expect(try await InPlaceAnswerTests.answer(tool.call, from: tool.directory) == .withheld(.outsideSearch))
        // The whole repository is no bound at all, and the same name is answered there: the declaration the
        // narrow search never reaches is inside this one.
        #expect(try await InPlaceAnswerTests.answered("grep -rn Orchard .", in: root)?.calls.map(\.target) == ["Orchard"])
        // Named no path at all, the search walks the same directory, and is answered as the one given `.` is.
        #expect(try await InPlaceAnswerTests.answered("grep -rn Orchard", in: root)?.calls.map(\.target) == ["Orchard"])
        // A name the search's paths do hold is answered as it always was.
        #expect(try await InPlaceAnswerTests.answered("grep -rn Depot Sources", in: root)?.calls.map(\.target) == ["Depot"])
    }

    /// An alternation is bounded name by name: one name with a site inside the paths searched does not license another whose every site is outside them, since the answer would read as complete for a search that prints none of that name.
    @Test
    func anAlternationIsAnsweredOnlyWhereEveryNameHasASiteInside() async throws {
        let root = try await Self.builtPackage()
        let mixed = try #require(InPlaceShape.match(forShell: #"grep -rnE "Crate|Depot" Sources/App/Shelf"#, in: root.path))

        #expect(mixed.call == .symbols(names: ["Crate", "Depot"], paths: ["Sources/App/Shelf"]))
        #expect(try await InPlaceAnswerTests.answer(mixed.call, from: mixed.directory) == .withheld(.outsideSearch))
        // Both names inside, the alternation is answered as it always was.
        #expect(try await InPlaceAnswerTests.answered(#"grep -rnE "Crate|Gizmo" Sources/App/Shelf"#, in: root)?.calls.map(\.target) == ["Crate", "Gizmo"])
    }

    /// A word-anchored sweep whose proof fails is answered with the plain `where` the loose spelling gets, rather than let through: the precise spelling is never worth less than the vague one.
    @Test
    func anAnchoredSweepWhoseProofFailsIsAnsweredAsTheLooseOneIs() async throws {
        let root = try await Self.packageWithAnUnprovableLine()

        let anchored = try #require(try await InPlaceAnswerTests.answered("grep -rnw Depot Sources", in: root))
        let loose = try #require(try await InPlaceAnswerTests.answered("grep -rn Depot Sources", in: root))

        // The fallback's calls are the names shape's own: one plain `where`, with no `--refs` on it.
        #expect(anchored.calls.map(\.tool) == ["where"])
        #expect(anchored.calls.map(\.target) == ["Depot"])
        #expect(anchored.reason.hasPrefix("sift answered this with `where Depot` instead of running it"))
        #expect(!anchored.reason.contains("refs: true"))
        // Handed over unproven, so the closing line claims no saving, exactly as the loose spelling's does.
        #expect(anchored.reason.contains("a `where` answer stands in for a search's output, which was never produced"))
        // Both spellings land on the same answer, which is the whole point of the fallback.
        #expect(anchored.calls.map(\.target) == loose.calls.map(\.target))
        #expect(anchored.calls.map(\.tool) == loose.calls.map(\.tool))
    }

    /// The fallback is held to the names shape's own bounds, its own back-off and the same size budget: a search whose every site falls outside the paths it named is withheld, and a back-off recorded against that shape withholds the fallback while the anchored reading itself was never backed off.
    @Test
    func theFallbackKeepsTheSymbolsShapesBounds() async throws {
        let root = try await Self.packageWithAnUnprovableLine()
        let orchard = try #require(InPlaceShape.match(forShell: "grep -rnw Orchard Sources", in: root.path))

        // The anchored reading, whose own proof fails because the grep prints nothing; the fallback is then bounded
        // by the paths the search named, which hold no site of a type declared under `Tests/`.
        #expect(orchard.call.shape == .sweep)
        #expect(try await InPlaceAnswerTests.answer(orchard.call, from: orchard.directory) == .withheld(.outsideSearch))

        let call = try #require(InPlaceShape.match(forShell: "grep -rnw Depot Sources", in: root.path)?.call)
        #expect(call.shape == .sweep)
        // The budget the caller gave bounds the fallback too: a refusal nobody can afford is withheld, not served.
        #expect(try await InPlaceAnswerTests.answer(call, from: root.path, sizeBudget: 200) == .withheld(.overSize))

        let backoff = try InPlaceAnswerTests.backoff()
        backoff.noteOverrun(root: root.path, shape: .symbols)

        #expect(try await InPlaceAnswerTests.answer(call, from: root.path, backoff: backoff) == .withheld(.backingOff))
    }

    /// An alternation naming a symbol declared only under `Tests/` is withheld for the same reason a name entirely outside the paths searched is: the declaration is real, but nothing the search named prints it — never the "could not prove this" reason a name the index cannot resolve at all gets.
    @Test
    func anAlternationWithATestOnlyNameIsWithheldAsOutsideSearchNotUnproven() async throws {
        let root = try await Self.builtPackage()
        let mixed = try #require(InPlaceShape.match(forShell: #"grep -rnE "Depot|Orchard" Sources"#, in: root.path))

        #expect(mixed.call == .symbols(names: ["Depot", "Orchard"], paths: ["Sources"]))
        #expect(try await InPlaceAnswerTests.answer(mixed.call, from: mixed.directory) == .withheld(.outsideSearch))
    }

    /// Only the failed proof falls back: every other withholding of the anchored reading is the answer, each being a bound both shapes share or a budget already spent.
    ///
    /// A back-off against the sweep withholds before anything is searched at all, and a tree holding a file no two greps read alike leaves the search undecided rather than unproven — where a fallback taken on any withholding would have answered both out of the index.
    @Test
    func aWithholdingOtherThanAFailedProofDoesNotFallBack() async throws {
        let root = try await Self.packageWithAnUnprovableLine()
        let call = try #require(InPlaceShape.match(forShell: "grep -rnw Depot Sources", in: root.path)?.call)

        let backoff = try InPlaceAnswerTests.backoff()
        backoff.noteOverrun(root: root.path, shape: .sweep)

        #expect(try await InPlaceAnswerTests.answer(call, from: root.path, backoff: backoff) == .withheld(.backingOff))

        // Bytes that hold the pattern and a NUL: the system's grep reads that file as binary where `ugrep` reads
        // it as text, so what the search prints is not settled and no answer can be measured against it.
        try MCPTestRepo.add(["Sources/App/Notes.bin": "Depot\u{0}\n"], to: root)

        #expect(try await InPlaceAnswerTests.answer(call, from: root.path) == .withheld(.unchecked))
    }

    /// A name two unrelated types each declare is answered with every owner's call sites, as any other name is.
    ///
    /// The in-place answer stands in for the search's lines, so every site's path is shown; the declarations-only answer a bare name of several owners gets elsewhere would leave the search's bound unproven and a sweep naming no path answered without a single site.
    @Test
    func aNameOfSeveralOwnersIsAnsweredWithEverySite() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "public struct Depot {\n    public init() {}\n    public func load() {}\n}\n",
            "Sources/App/Gizmo.swift": "public struct Gizmo {\n    public init() {}\n    public func load() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    func run() {\n        Depot().load()\n        Gizmo().load()\n    }\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()

        let bounded = try #require(try await InPlaceAnswerTests.answered("grep -rn load Sources", in: root))
        let unbounded = try #require(try await InPlaceAnswerTests.answered("grep -rn load", in: root))

        #expect(bounded.calls.map(\.target) == ["load"])
        for answered in [bounded, unbounded] {
            let answer = try #require(InPlaceAnswer.answer(inReason: answered.reason))
            #expect(answer.contains("Sources/App/Uses.swift"))
            #expect(!answer.contains("under 2 owners"))
        }
    }
}
