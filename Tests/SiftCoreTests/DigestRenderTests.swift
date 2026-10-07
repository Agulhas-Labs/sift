//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers digest rendering: completeness, determinism, packing, budgeting, and the honest edge answers.
@Suite(.temporaryDirectories)
struct DigestRenderTests {
    /// The fixture store together with the directory its sources really occupy — the member-body path slices the file on disk, so these cannot be phantom paths.
    private static func seededFixture() throws -> (store: IndexStore, root: URL) {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        // Members carry real bodies deliberately. A digest only earns its keep once the source it stands in
        // for is substantially larger than the summary (`SourcePassthrough`), so a fixture of empty stubs
        // would be served as source and never reach the rendering these tests are about.
        let widget = try TestSources.parsed(
            """
            import Foundation

            /// A widget with layers.
            public struct Widget: Equatable {
                /// The display name.
                public var name: String
                private let created: Date = Date()

                public func reload() {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return
                    }
                    for index in 0 ..< trimmed.count {
                        let layer = String(trimmed.prefix(index + 1))
                        _ = String("reloading layer \\(index) as \\(layer)")
                    }
                }

                public func rename(to proposed: String) -> Bool {
                    let candidate = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty, candidate != name else {
                        return false
                    }
                    guard candidate.count <= 64 else {
                        return false
                    }
                    name = candidate
                    return true
                }

                public func age(now: Date = Date()) -> TimeInterval {
                    let elapsed = now.timeIntervalSince(created)
                    guard elapsed > 0 else {
                        return 0
                    }
                    return elapsed.rounded(.down)
                }

                struct Inner { let flag: Bool }

                enum Slot: Int {
                    case a, b, c, d, e, f, g, h, i, j, k, l, m, n
                }
            }
            """,
            path: "Sources/Alpha/Widget.swift",
            in: root
        )
        let extras = try TestSources.parsed(
            """
            extension Widget: CustomStringConvertible {
                public var description: String {
                    let suffix = created.timeIntervalSinceNow < -60 ? " (stale)" : ""
                    return name + suffix
                }

                @discardableResult @Fancy
                func polish(level: Int) -> Bool {
                    guard level > 0 else {
                        return false
                    }
                    for pass in 0 ..< level {
                        _ = String("polishing pass \\(pass) of \\(level)")
                    }
                    return true
                }
            }
            """,
            path: "Sources/Alpha/Widget+Extras.swift",
            in: root
        )
        let betaWidget = try TestSources.parsed(
            "struct Widget { let other = true }",
            path: "Sources/Beta/Widget.swift",
            in: root
        )
        let fuel = try TestSources.parsed(
            """
            enum Fuel: String, CaseIterable {
                case wood, coal, oil, gas, hydrogen

                var renewable: Bool {
                    switch self {
                    case .wood: true
                    case .coal, .oil, .gas: false
                    case .hydrogen: true
                    }
                }

                var carbonPerJoule: Double {
                    switch self {
                    case .wood: 0.39
                    case .coal: 0.34
                    case .oil: 0.27
                    case .gas: 0.20
                    case .hydrogen: 0.0
                    }
                }

                var storable: Bool {
                    switch self {
                    case .wood, .coal, .oil: true
                    case .gas, .hydrogen: false
                    }
                }

                var megajoulesPerKilogram: Double {
                    switch self {
                    case .wood: 16.0
                    case .coal: 24.0
                    case .oil: 42.0
                    case .gas: 55.0
                    case .hydrogen: 120.0
                    }
                }

                func outranks(_ other: Fuel) -> Bool {
                    guard self != other else {
                        return false
                    }
                    if renewable != other.renewable {
                        return renewable
                    }
                    return megajoulesPerKilogram > other.megajoulesPerKilogram
                }
            }
            """,
            path: "Sources/Alpha/Fuel.swift",
            in: root
        )
        let colorExtras = try TestSources.parsed(
            """
            extension Color {
                static var brand: Color { Color() }
            }
            """,
            path: "Sources/Alpha/Color+Brand.swift",
            in: root
        )
        // A second module extending the same external type — the monorepo shape module-qualified digests must scope to.
        let betaColorExtras = try TestSources.parsed(
            """
            extension Color {
                static var accent: Color { Color() }
            }
            """,
            path: "Sources/Beta/Color+Accent.swift",
            in: root
        )
        // A module with no Color extension at all, so a qualifier naming it has a real miss to report.
        let gammaHelper = try TestSources.parsed(
            "struct GammaHelper { let flag: Bool }",
            path: "Sources/Gamma/GammaHelper.swift",
            in: root
        )
        // Bodies the member-body path can actually slice, kept apart from the fixtures above whose exact line numbers are pinned by other tests.
        let engine = try TestSources.parsed(
            """
            struct Engine {
                func start(mode: String) -> Bool {
                    guard !mode.isEmpty else { return false }
                    return true
                }

                func start() -> Bool {
                    start(mode: "default")
                }
            }
            """,
            path: "Sources/Alpha/Engine.swift",
            in: root
        )
        try store.replaceFiles([widget, extras, betaWidget, fuel, colorExtras, betaColorExtras, gammaHelper, engine]) { path in
            if path.hasPrefix("Sources/Beta") {
                return ("Beta", false)
            }
            if path.hasPrefix("Sources/Gamma") {
                return ("Gamma", false)
            }
            return ("Alpha", false)
        }
        return (store, root)
    }

    private static func render(_ target: String, options: DigestOptions = DigestOptions()) throws -> String {
        let fixture = try seededFixture()
        let renderer = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)
        return try renderer.render(target: target, options: options)
    }

    private static func render(targets: [String], options: DigestOptions = DigestOptions()) throws -> String {
        let fixture = try seededFixture()
        let renderer = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)
        return try renderer.render(targets: targets, options: options)
    }

    @Test
    func ambiguousNameListsCandidatesInsteadOfGuessing() throws {
        let output = try Self.render("Widget")

        #expect(output.contains("ambiguous"))
        #expect(output.contains("Alpha.Widget"))
        #expect(output.contains("Beta.Widget"))
        #expect(!output.contains("stored properties"))
    }

    @Test
    func moduleQualifiedTypeDigestIsCompleteAndAnnotated() throws {
        let output = try Self.render("Alpha.Widget")

        #expect(output.contains("Widget — Alpha — Sources/Alpha/Widget.swift:4-45"))
        #expect(output.contains("(+1 extension"))
        #expect(output.contains("stored properties:"))
        #expect(output.contains("public var name: String"))
        #expect(output.contains("private let created: Date"))
        #expect(output.contains("public func reload()"))
        #expect(output.contains("struct Inner — 1 members"))
        #expect(output.contains("extension Widget"))
        #expect(output.contains("polish(level:)") || output.contains("func polish(level: Int) -> Bool"))
        #expect(output.contains("/// The display name."))
        #expect(output.contains("synthesized members"))
    }

    @Test
    func renderingIsDeterministic() throws {
        let first = try Self.render("Alpha.Widget")

        let second = try Self.render("Alpha.Widget")

        #expect(first == second)
    }

    @Test
    func enumCasesRenderPackedNotAsRows() throws {
        let output = try Self.render("Fuel")

        #expect(output.contains("cases (5): wood coal oil gas hydrogen"))
        #expect(!output.contains("case wood,"))
    }

    @Test
    func externalTypeAnswersWithLocalExtensions() throws {
        let output = try Self.render("Color")

        #expect(output.contains("declared outside this repo"))
        #expect(output.contains("2 local extensions"))
        #expect(output.contains("static var brand: Color"))
        #expect(output.contains("static var accent: Color"))
    }

    /// Five modules extending one dependency type is the monorepo norm — `digest DesignKit.Theme` asks for one module's extensions, and a qualifier silently dropped serves every module's extensions whichever module was named.
    @Test
    func aModuleQualifierScopesAnExternalTypesExtensions() throws {
        let alpha = try Self.render("Alpha.Color")
        let beta = try Self.render("Beta.Color")

        #expect(alpha.contains("1 local extension in Alpha"))
        #expect(alpha.contains("static var brand: Color"))
        #expect(!alpha.contains("static var accent: Color"))
        #expect(alpha.contains("(+1 extension in other modules — digest Color serves them all)"))
        #expect(beta.contains("1 local extension in Beta"))
        #expect(beta.contains("static var accent: Color"))
        #expect(!beta.contains("static var brand: Color"))
    }

    /// A module with no extension of the type gets told who has one — not every module's extensions under a header that ignored the question.
    @Test
    func aModuleWithoutTheExtensionListsWhoHasIt() throws {
        let output = try Self.render("Gamma.Color")

        #expect(output.contains("no Color extension in Gamma"))
        #expect(output.contains("Alpha (1)"))
        #expect(output.contains("Beta (1)"))
        #expect(!output.contains("static var brand: Color"))
    }

    @Test
    func unknownNameFallsBackToNearestSymbols() throws {
        let output = try Self.render("Wid")

        #expect(output.contains("nearest symbols"))
        #expect(output.contains("Widget"))
    }

    @Test
    func signaturesOnlyStripsAttributesAndDocs() throws {
        let full = try Self.render("Alpha.Widget")
        let stripped = try Self.render("Alpha.Widget", options: DigestOptions(signaturesOnly: true))

        #expect(full.contains("@discardableResult"))
        #expect(!stripped.contains("@discardableResult"))
        #expect(!stripped.contains("/// The display name."))
    }

    @Test
    func fileDigestOpensWithImports() throws {
        let output = try Self.render("Sources/Alpha/Widget.swift")

        #expect(output.hasPrefix("Sources/Alpha/Widget.swift — module: Alpha"))
        #expect(output.contains("imports: Foundation"))
        #expect(output.contains("public struct Widget"))
    }

    @Test
    func moduleDigestGroupsByFile() throws {
        let output = try Self.render("Alpha")

        #expect(output.contains("module Alpha"))
        #expect(output.contains("Sources/Alpha/Fuel.swift:"))
        #expect(output.contains("Sources/Alpha/Widget.swift:"))
    }

    @Test
    func negativeOffsetIsClampedNotFatal() throws {
        let members = (0 ..< 75).map { "    public func member\($0)() {}" }.joined(separator: "\n")
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed("public struct Big {\n\(members)\n}", path: "Sources/Alpha/Big.swift")]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: TestSources.makeTempDirectory())

        let negative = try renderer.render(target: "Big", options: DigestOptions(offset: -2))
        let zero = try renderer.render(target: "Big", options: DigestOptions())

        #expect(negative == zero)
    }

    @Test
    func fileResolutionRequiresAComponentBoundary() throws {
        let output = try Self.render("View.swift")

        #expect(output.contains("no indexed file matches View.swift"))
    }

    @Test
    func docSummaryEndingInColonStaysBudgeted() throws {
        let members = (0 ..< 75).map { "    /// - Parameters:\n    public func member\($0)() {}" }.joined(separator: "\n")
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed("public struct Big {\n\(members)\n}", path: "Sources/Alpha/Big.swift")]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: TestSources.makeTempDirectory())

        let firstPage = try renderer.render(target: "Big", options: DigestOptions())
        let secondPage = try renderer.render(target: "Big", options: DigestOptions(offset: 60))

        #expect(firstPage.contains("truncated: 15 more member lines — pass --offset 60"))
        #expect(!firstPage.contains("member60()"))
        #expect(secondPage.contains("member60()"))
        #expect(secondPage.contains("member74()"))
    }

    @Test
    func capTruncatesAndOffsetResumes() throws {
        let members = (0 ..< 75).map { "    public func member\($0)() {}" }.joined(separator: "\n")
        let bigSource = "public struct Big {\n\(members)\n}"
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed(bigSource, path: "Sources/Alpha/Big.swift")]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: TestSources.makeTempDirectory())

        let firstPage = try renderer.render(target: "Big", options: DigestOptions())
        let secondPage = try renderer.render(target: "Big", options: DigestOptions(offset: 60))

        #expect(firstPage.contains("truncated: 15 more member lines — pass --offset 60"))
        #expect(!firstPage.contains("member70()"))
        #expect(secondPage.contains("(…60 member lines skipped)"))
        #expect(secondPage.contains("member70()"))
    }

    /// The truncation line's resume cursor is spelled for whichever face asked, the same as a member block's resume target already is — not always the CLI's `--offset`, which an MCP caller cannot paste into a tool call's `offset` argument.
    @Test
    func theTruncationCursorIsSpelledForTheFaceThatAsked() throws {
        let members = (0 ..< 75).map { "    public func member\($0)() {}" }.joined(separator: "\n")
        let bigSource = "public struct Big {\n\(members)\n}"
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed(bigSource, path: "Sources/Alpha/Big.swift")]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: TestSources.makeTempDirectory())

        let cliPage = try renderer.render(target: "Big", options: DigestOptions(spelling: .commandLine))
        let toolPage = try renderer.render(target: "Big", options: DigestOptions(spelling: .toolCall))

        #expect(cliPage.contains("truncated: 15 more member lines — pass --offset 60"))
        #expect(toolPage.contains("truncated: 15 more member lines — pass offset: 60"))
    }

    /// A module listing pages its top-level declarations, and its markers say so: "member lines" under a header that counts declarations is a correct number a reader stops believing.
    @Test
    func aModuleListingPagesInDeclarationLines() throws {
        let source = (0 ..< 75).map { "public struct Piece\($0) {}" }.joined(separator: "\n")
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed(source, path: "Sources/Alpha/Pieces.swift")]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: TestSources.makeTempDirectory())

        let firstPage = try renderer.render(target: "Alpha", options: DigestOptions())
        let secondPage = try renderer.render(target: "Alpha", options: DigestOptions(offset: 60))
        let pastTheEnd = try renderer.render(target: "Alpha", options: DigestOptions(offset: 200))

        #expect(firstPage.contains("module Alpha — 75 top-level declarations"))
        #expect(firstPage.contains("truncated: 15 more declaration lines — pass --offset 60"))
        #expect(secondPage.contains("(…60 declaration lines skipped)"))
        #expect(pastTheEnd.contains("(offset 200 is past the end — 75 declaration lines total)"))
        #expect(!(firstPage + secondPage + pastTheEnd).contains("member lines"))
    }

    @Test
    func dotTargetServesTheRepoOverview() throws {
        let output = try Self.render(".")

        // The cold-start view: every module with its size, and the pointer to go one level deeper.
        // Alpha holds 5 files (Widget, Widget+Extras, Fuel, Color+Brand, Engine) with 5 top-level
        // declarations (Widget, both extensions, Fuel, Engine); Beta its Widget and Color extension;
        // Gamma its one helper.
        #expect(output.contains("repo — 3 modules, 8 files"))
        #expect(output.contains("Alpha — 5 files, 5 top-level declarations"))
        #expect(output.contains("Beta — 2 files, 2 top-level declarations"))
        #expect(output.contains("Gamma — 1 file, 1 top-level declaration"))
        #expect(output.contains("config: none (defaults)"))
        #expect(output.contains("digest <Module> lists one module's declarations"))
    }
}

// MARK: Member targets and their source

/// What a qualified target resolves to, and what comes back when it resolves to a member.
///
/// One subject seen from both ends: `Type.member` serves that member's *current* source read off disk, an over-long body pages, and a mistyped or overloaded label answers with candidates rather than a guess — while a qualified name that is **not** a member (an extension row, a nested type) must never be served as source, which is the failure that hijacked the external-type answer.
extension DigestRenderTests {
    @Test
    func qualifiedMemberTargetServesItsSource() throws {
        let output = try Self.render("Engine.start(mode:)")

        #expect(output.hasPrefix("Alpha.Engine.start(mode:) — func — Sources/Alpha/Engine.swift:2-5"))
        #expect(output.contains("guard !mode.isEmpty else { return false }"))
        #expect(!output.contains("struct Engine"))
    }

    @Test
    func severalTargetsEachAnswerInOneCall() throws {
        let output = try Self.render(targets: ["Engine.start(mode:)", "Engine.start()"])

        #expect(output.contains("Alpha.Engine.start(mode:) — func — Sources/Alpha/Engine.swift:2-5"))
        #expect(output.contains("Alpha.Engine.start() — func — Sources/Alpha/Engine.swift:7-9"))
        // Two answers, not one run-on: the join is what separates them, since nothing else marks a boundary.
        #expect(output.contains("\n\n"))
    }

    @Test
    func aMixOfShapesEachAnswerInTheOrderGiven() throws {
        let output = try Self.render(targets: ["Engine.start(mode:)", "Fuel"])

        let memberRange = try #require(output.range(of: "Alpha.Engine.start(mode:)"))
        let typeRange = try #require(output.range(of: "Fuel — Alpha —"))

        #expect(memberRange.lowerBound < typeRange.lowerBound)
        #expect(output.contains("cases (5): wood coal oil gas hydrogen"))
    }

    /// One target that names nothing is answered inline, in its place, and the rest are served: a miss is an answer like any other, not a failure of the whole call.
    @Test
    func aMissAmongSeveralTargetsIsNamedInPlaceAndTheOthersServed() throws {
        let output = try Self.render(targets: ["Engine.start(mode:)", "Zeppelin", "Fuel"])

        let member = try #require(output.range(of: "Alpha.Engine.start(mode:) — func"))
        let miss = try #require(output.range(of: "named Zeppelin"))
        let type = try #require(output.range(of: "Fuel — Alpha —"))

        #expect(member.lowerBound < miss.lowerBound)
        #expect(miss.lowerBound < type.lowerBound)
    }

    /// A miss says so to the face, which knows what the caller typed; an answer about something that is there does not.
    @Test
    func aMissIsMarkedAsOneAndAnAnswerIsNot() throws {
        let fixture = try Self.seededFixture()
        let renderer = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)

        #expect(try renderer.measured(target: "Zeppelin", options: DigestOptions()).missed)
        #expect(try renderer.measured(target: "Sources/Alpha/Nowhere.swift", options: DigestOptions()).missed)
        #expect(try !renderer.measured(target: "Fuel", options: DigestOptions()).missed)
        #expect(try !renderer.measured(target: "Engine.start(mode:)", options: DigestOptions()).missed)
    }

    /// Naming a module with no extension of the type serves nothing for that module — only where else to look — so it is a miss too.
    @Test
    func aModuleWithoutTheExtensionIsMarkedAsAMiss() throws {
        let fixture = try Self.seededFixture()
        let renderer = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)

        let answer = try renderer.measured(target: "Gamma.Color", options: DigestOptions())

        #expect(answer.text.contains("no Color extension in Gamma"))
        #expect(answer.missed)
    }

    /// An offset is a cursor into one answer, so several targets with one are refused rather than each skipped by it.
    @Test
    func anOffsetWithSeveralTargetsIsRefused() throws {
        #expect(throws: EngineError.self) {
            try Self.render(targets: ["Engine.start(mode:)", "Fuel"], options: DigestOptions(offset: 10))
        }
    }

    @Test
    func aSingleElementTargetsArrayAnswersExactlyAsTheSingleTargetForm() throws {
        let asSingle = try Self.render("Engine.start(mode:)")
        let asArray = try Self.render(targets: ["Engine.start(mode:)"])

        #expect(asSingle == asArray)
    }

    @Test
    func aLineRangeSuffixServesTheInnermostDeclarationItIntersects() throws {
        let output = try Self.render("Sources/Alpha/Engine.swift:2-5")

        #expect(output.hasPrefix("Alpha.Engine.start(mode:) — func — Sources/Alpha/Engine.swift:2-5"))
        #expect(!output.contains("struct Engine"))
    }

    @Test
    func aSingleLineSuffixResolvesTheDeclarationThatContainsIt() throws {
        let output = try Self.render("Sources/Alpha/Engine.swift:3")

        #expect(output.hasPrefix("Alpha.Engine.start(mode:) — func — Sources/Alpha/Engine.swift:2-5"))
    }

    @Test
    func aColumnSuffixIsReadAndDiscarded() throws {
        let withColumn = try Self.render("Sources/Alpha/Engine.swift:3:5")
        let lineOnly = try Self.render("Sources/Alpha/Engine.swift:3")

        #expect(withColumn == lineOnly)
    }

    @Test
    func aRangeSpanningTwoSiblingsServesBoth() throws {
        let output = try Self.render("Sources/Alpha/Engine.swift:4-8")

        #expect(output.contains("Alpha.Engine.start(mode:) — func — Sources/Alpha/Engine.swift:2-5"))
        #expect(output.contains("Alpha.Engine.start() — func — Sources/Alpha/Engine.swift:7-9"))
    }

    /// The verdict leads (Docs/AnswerContract.md §2): a reader who stops after the first line already knows nothing here spans the lines asked for, before ever reaching the file digest served beneath it.
    @Test
    func aLineNoDeclarationSpansServesTheFileDigestWithANote() throws {
        let output = try Self.render("Sources/Alpha/Engine.swift:50")

        #expect(output.hasPrefix("(no declaration spans line 50 in Sources/Alpha/Engine.swift)"))
    }

    @Test
    func anAmbiguousFileSuffixListsCandidatesInsteadOfGuessing() throws {
        let output = try Self.render("Widget.swift:1")

        #expect(output.contains("is ambiguous"))
        // The lines asked for ride on every suggestion, or following one answers a different question.
        #expect(output.contains("digest Sources/Alpha/Widget.swift:1\n"))
        #expect(output.hasSuffix("digest Sources/Beta/Widget.swift:1"))
    }

    @Test
    func aReversedRangeIsReadTheRightWayRound() throws {
        let reversed = try Self.render("Sources/Alpha/Engine.swift:5-2")
        let forward = try Self.render("Sources/Alpha/Engine.swift:2-5")

        #expect(reversed == forward)
    }

    /// A compiler diagnostic prints `File.swift:3:5:` — the trailing colon is read past like the column before it.
    @Test
    func aDiagnosticsTrailingColonIsReadPast() throws {
        let diagnostic = try Self.render("Sources/Alpha/Engine.swift:3:5:")
        let lineOnly = try Self.render("Sources/Alpha/Engine.swift:3")

        #expect(diagnostic == lineOnly)
    }

    /// Cases packed on one line are one line of source, served once rather than once per case.
    @Test
    func packedCasesOnOneLineAreServedOnce() throws {
        let output = try Self.render("Sources/Alpha/Fuel.swift:2")

        #expect(output.hasPrefix("Alpha.Fuel.wood — case — Sources/Alpha/Fuel.swift:2"))
        #expect(output.components(separatedBy: "case wood, coal, oil, gas, hydrogen").count == 2)
    }

    /// An offset pages one declaration's source, so a range resolving to several refuses one; a range resolving to one pages it.
    @Test
    func anOffsetPagesARangeOnlyWhenItResolvesToOneDeclaration() throws {
        #expect(throws: EngineError.self) {
            try Self.render("Sources/Alpha/Engine.swift:4-8", options: DigestOptions(offset: 1))
        }
        let paged = try Self.render("Sources/Alpha/Engine.swift:2-5", options: DigestOptions(offset: 1))

        #expect(paged.contains("(…1 body lines skipped)"))
    }

    @Test
    func memberSourceIsReadFromDiskNotTheIndex() throws {
        let fixture = try Self.seededFixture()
        let renderer = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)
        // Same line count, so the indexed range still describes the edit — the engine reparses dirty files before any digest, and a range that no longer fits its file is a different (freshness) concern than "is the source read from disk".
        try TestSources.write(
            """
            struct Engine {
                func start(mode: String) -> Bool {
                    let edited = !mode.isEmpty
                    return edited
                }

                func start() -> Bool {
                    start(mode: "default")
                }
            }
            """,
            to: "Sources/Alpha/Engine.swift",
            in: fixture.root
        )

        let output = try renderer.render(target: "Engine.start(mode:)", options: DigestOptions())

        // The exact slice, so a range that drifts by even one line fails here instead of passing on a substring.
        #expect(output.hasSuffix("""
        Alpha.Engine.start(mode:) — func — Sources/Alpha/Engine.swift:2-5

            func start(mode: String) -> Bool {
                let edited = !mode.isEmpty
                return edited
            }
        """))
    }

    @Test
    func moduleQualifiedExternalTypeStillAnswersWithExtensions() throws {
        // Alpha.Color resolves to an extension row, which is not a member: serving its source hijacked the
        // external-type answer, and with two extensions the ambiguity list suggested the query itself.
        let output = try Self.render("Alpha.Color")

        #expect(output.contains("declared outside this repo"))
        #expect(output.contains("static var brand: Color"))
        #expect(!output.contains("is ambiguous"))
    }

    @Test
    func nestedTypeTargetsNeverServeExtensionSource() throws {
        let output = try Self.render("Alpha.Widget")

        #expect(output.contains("stored properties:"))
        #expect(output.contains("(+1 extension"))
    }

    @Test
    func memberBodyOffsetResumesWhereTruncationStopped() throws {
        let root = try TestSources.makeTempDirectory()
        let store = try TestSources.makeStore()
        let body = (0 ..< 250).map { "        let value\($0) = \($0)" }.joined(separator: "\n")
        let parsed = try TestSources.parsed(
            "struct Long {\n    func run() {\n\(body)\n    }\n}",
            path: "Sources/Alpha/Long.swift",
            in: root
        )
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let firstPage = try renderer.render(target: "Long.run", options: DigestOptions())
        let secondPage = try renderer.render(target: "Long.run", options: DigestOptions(offset: 200))

        #expect(firstPage.contains("pass --offset 200"))
        #expect(!firstPage.contains("let value240 = 240"))
        #expect(secondPage.contains("(…200 body lines skipped)"))
        #expect(secondPage.contains("let value240 = 240"))
        #expect(!secondPage.contains("let value0 = 0"))
    }

    @Test
    func aMistypedArgumentLabelStillSuggestsCandidates() throws {
        // The FTS sanitizer strips parens and colons, so the labeled form searched as an unmatchable token.
        let output = try Self.render("Engine.start(mod:)")

        #expect(output.contains("nearest symbols"))
        #expect(output.contains("start(mode:)"))
        #expect(!output.contains("no symbol named"))
    }

    @Test
    func ambiguousMemberListsLabeledTargetsInsteadOfGuessing() throws {
        // An offset names a place in one body, so it keeps the list where the two small overloads would otherwise be served.
        let output = try Self.render("Engine.start", options: DigestOptions(offset: 1))

        #expect(output.contains("ambiguous"))
        #expect(output.contains("Alpha.Engine.start(mode:)"))
        #expect(output.contains("Alpha.Engine.start()"))
        #expect(!output.contains("guard !mode.isEmpty"))
    }

    @Test
    func typeTargetsAreAnsweredByTheTypePathEvenWhenItServesSource() throws {
        // This guards the routing rather than "a type target never serves source", a rule that would keep
        // the member-body path from being handed a container — the bug where `Module.ExternalType`
        // resolved to an extension row and returned raw extension source. A one-line nested type is
        // *deliberately* served as source, because summarising it costs more than printing it.
        //
        // What must still hold is the routing, so that is what this asserts: the answer comes from the type
        // path, evidenced by the passthrough note and the type header that only that path emits. The
        // extension-row bug keeps its own guard in `moduleQualifiedExternalTypeStillAnswersWithExtensions`.
        let output = try Self.render("Alpha.Widget.Inner")

        #expect(output.contains("Inner — Alpha — Sources/Alpha/Widget.swift:40"))
        #expect(output.contains("so the source itself follows"))
        #expect(output.contains("struct Inner { let flag: Bool }"))
        #expect(!output.contains("is ambiguous"))
    }

    @Test
    func longMemberBodyTruncatesWithTheRangedReadThatFinishesIt() throws {
        let root = try TestSources.makeTempDirectory()
        let store = try TestSources.makeStore()
        let body = (0 ..< 250).map { "        let value\($0) = \($0)" }.joined(separator: "\n")
        let parsed = try TestSources.parsed(
            "struct Long {\n    func run() {\n\(body)\n    }\n}",
            path: "Sources/Alpha/Long.swift",
            in: root
        )
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "Long.run", options: DigestOptions())

        #expect(output.contains("let value0 = 0"))
        #expect(!output.contains("let value240 = 240"))
        // run() spans lines 2-253 (252 lines); 200 shown end at line 201, so 52 remain from line 202.
        #expect(output.contains("… truncated: 52 more lines — pass --offset 200, or Read Sources/Alpha/Long.swift from line 202"))
    }
}

// MARK: Module digest footer

extension DigestRenderTests {
    /// A nested type rendered as a bare count leaves any question about its shape answerable only by opening the file.
    ///
    /// A targeted read that follows a digest often lands on exactly such a type — `enum Strings — 2 cases/members` and friends, where the names are the entire content.
    @Test
    func aNestedTypeNamesItsChildrenRatherThanOnlyCountingThem() throws {
        let output = try Self.render("Alpha.Widget")

        #expect(output.contains("struct Inner — 1 members: flag"))
    }

    /// Naming them cannot cost what naming them was meant to save, so a wide nested type stops at the cap and counts the rest.
    @Test
    func aWideNestedTypeStopsAtTheCapAndCountsTheRemainder() throws {
        let output = try Self.render("Alpha.Widget")

        #expect(output.contains("enum Slot: Int — 14 cases/members: a b c d e f g h i j k l +2 more"))
    }

    /// A module and a type sharing a name is common — every SwiftPM executable target with an eponymous entry-point type — and the module digest must name the type it shadows rather than winning silently.
    @Test
    func aModuleDigestNamesTheSameNamedTypeItShadows() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let main = try TestSources.parsed("struct Warden { let mode: String }", path: "Sources/Warden/Warden.swift", in: root)
        try store.replaceFiles([main]) { _ in ("Warden", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "Warden", options: DigestOptions())

        #expect(output.contains("module Warden"))
        #expect(output.contains("a type named Warden also exists — `digest Warden.Warden` serves it"))
    }

    /// A module shadowing nothing keeps its digest footer-free.
    @Test
    func aModuleDigestWithoutAnEponymousTypeCarriesNoFooter() throws {
        let output = try Self.render("Alpha")

        #expect(!output.contains("also exists"))
    }
}

// MARK: Completeness

/// The shape a lint-rule package is written in: many files each declaring their own same-named nested visitor inside a private extension.
///
/// It is the shape that exposed all four defects below at once, and one that is otherwise read whole in preference to its own digest.
extension DigestRenderTests {
    /// Bodies are real for the reason `seededFixture` gives.
    ///
    /// A fixture of stubs is served as source by `SourcePassthrough` and never reaches the rendering these tests are about — which would silently let these tests pass against the raw text of the file. The *file* digest of this fixture is a digest; a type digest of one of its nested visitors is still small enough to be served as source, so the tests that target one assert on something the two answers spell differently.
    private static func rulesFixture() throws -> DigestRenderer {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let first = try TestSources.parsed(
            """
            public struct AlphaRule: LintRule {
                public let id = "alpha"

                public func check(_ lines: [String]) -> [String] {
                    let visitor = Visitor()
                    for (offset, line) in lines.enumerated() where !line.isEmpty {
                        visitor.note(offset)
                    }
                    return visitor.violations
                }
            }

            private extension AlphaRule {
                final class Visitor: SyntaxVisitor {
                    private var seen: [Int] = []

                    var violations: [String] {
                        seen.map { offset in
                            "alpha violation at line \\(offset + 1)"
                        }
                    }

                    func note(_ line: Int) {
                        guard !seen.contains(line) else {
                            return
                        }
                        seen.append(line)
                        seen.sort()
                    }
                }
            }

            private extension AlphaRule.Visitor {
                struct Note {
                    let line: Int

                    var description: String {
                        "note at line \\(line)"
                    }
                }
            }
            """,
            path: "Sources/Alpha/AlphaRule.swift",
            in: root
        )
        // A second rule whose visitor shares the bare name, and whose extension declares a differently-named child —
        // so a grafted member is unmistakable in either direction.
        let second = try TestSources.parsed(
            """
            public struct BetaRule: LintRule {
                public let id = "beta"

                public func check(_ lines: [String]) -> [String] {
                    let visitor = Visitor()
                    for line in lines where line.hasPrefix("beta") {
                        visitor.record(line)
                    }
                    return visitor.violations
                }
            }

            private extension BetaRule {
                final class Visitor: SyntaxVisitor {
                    private var matches: [String] = []

                    var violations: [String] {
                        matches.map { match in
                            "beta violation for \\(match)"
                        }
                    }

                    func record(_ line: String) {
                        guard matches.count < 32 else {
                            return
                        }
                        matches.append(line)
                    }
                }
            }

            private extension BetaRule.Visitor {
                struct Scanner {
                    let depth: Int

                    func deeper() -> Scanner {
                        Scanner(depth: depth + 1)
                    }
                }
            }
            """,
            path: "Sources/Alpha/BetaRule.swift",
            in: root
        )
        try store.replaceFiles([first, second]) { _ in ("Alpha", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    /// `private` is scoped to the file, so a file's private declarations are the file.
    ///
    /// Hiding them answers a different question, and answers it silently — so a digest omitting a third of the file reads as a complete one, and the file is read whole straight after.
    @Test
    func aFileDigestShowsTheFilesPrivateDeclarations() throws {
        let output = try Self.rulesFixture().render(target: "Sources/Alpha/AlphaRule.swift", options: DigestOptions())

        #expect(output.contains("extension AlphaRule"))
        #expect(output.contains("final class Visitor: SyntaxVisitor"))
    }

    /// The suppression that is right at the top level, where children are enumerated directly beneath, left a container one level down as a bare signature — neither naming its members nor counting them.
    @Test
    func aNestedContainerInAFileDigestNamesItsChildren() throws {
        let output = try Self.rulesFixture().render(target: "Sources/Alpha/AlphaRule.swift", options: DigestOptions())

        #expect(output.contains("final class Visitor: SyntaxVisitor — 3 members: seen violations note(_:)"))
    }

    /// Extensions were gathered by bare name, so every same-named nested type in the module donated its members to every other one's answer — a wrong answer rather than a missing one, and believed because a digest is.
    @Test
    func aNestedTypesDigestExcludesASameNamedTypesExtensions() throws {
        let output = try Self.rulesFixture().render(target: "AlphaRule.Visitor", options: DigestOptions())

        #expect(output.contains("extension AlphaRule.Visitor"))
        #expect(output.contains("struct Note"))
        #expect(!output.contains("BetaRule.Visitor"))
        #expect(!output.contains("struct Scanner"))
        #expect(output.contains("(+1 extension)"))
    }

    /// A chain element is a *written* name, so `extension A.B` spelled two names in one.
    ///
    /// Unflattened, no three-part qualifier could match anything declared inside it, and the refusal then listed the declaration it had just refused.
    @Test
    func aTypeDeclaredInsideANestedTypesExtensionResolves() throws {
        let output = try Self.rulesFixture().render(target: "BetaRule.Visitor.Scanner", options: DigestOptions())

        #expect(output.contains("struct Scanner"))
        #expect(!output.contains("no type or member named"))
    }

    /// A module and a top-level type sharing a name is the SwiftPM norm, and the extension of a type nested inside that type is spelled with the shared name leading.
    ///
    /// Dropping any leading component that merely names a module amputated the enclosing type here, so the nested type lost its whole extension — with the header count agreeing it had none, and no spelling that recovered it.
    @Test
    func anExtensionSurvivesAnEnclosingTypeNamedAfterItsModule() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let source = try TestSources.parsed(
            """
            public struct Widget {
                public struct Options {
                    public let raw: Int
                }
            }

            extension Widget.Options {
                public var summary: String {
                    "options \\(raw)"
                }

                public func doubled() -> Int {
                    raw * 2
                }
            }
            """,
            path: "Sources/Widget/Widget.swift",
            in: root
        )
        try store.replaceFiles([source]) { _ in ("Widget", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "Widget.Options", options: DigestOptions())

        #expect(output.contains("summary"))
        #expect(output.contains("doubled"))
    }

    /// A module qualifier is written to disambiguate, so discarding it and matching anyway serves the very type the caller ruled out.
    @Test
    func aForeignModulesQualifiedExtensionIsNotAdopted() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let alpha = try TestSources.parsed(
            """
            public struct Solo {
                public let alphaOnly = 1
            }

            extension ModA.Solo {
                public var qualifiedFromA: Int {
                    alphaOnly
                }
            }
            """,
            path: "Sources/ModA/Solo.swift",
            in: root
        )
        let beta = try TestSources.parsed(
            """
            public struct Solo {
                public let betaOnly = 2
            }
            """,
            path: "Sources/ModB/Solo.swift",
            in: root
        )
        try store.replaceFiles([alpha, beta]) { path in
            path.hasPrefix("Sources/ModA") ? ("ModA", false) : ("ModB", false)
        }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let betaDigest = try renderer.render(target: "ModB.Solo", options: DigestOptions())
        let alphaDigest = try renderer.render(target: "ModA.Solo", options: DigestOptions())

        #expect(!betaDigest.contains("qualifiedFromA"))
        #expect(alphaDigest.contains("qualifiedFromA"))
    }

    /// A nested qualifier scopes an external type's extension list exactly as a module one does — `digest URLSession.Configuration` was answered with `Locale.Configuration` alongside it.
    @Test
    func aNestedQualifierScopesAnExternalTypesExtensions() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let source = try TestSources.parsed(
            """
            extension URLSession.Configuration {
                var retries: Int { 3 }
            }

            extension Locale.Configuration {
                var fallback: String { "en" }
            }
            """,
            path: "Sources/Alpha/Configurations.swift",
            in: root
        )
        try store.replaceFiles([source]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "URLSession.Configuration", options: DigestOptions())

        #expect(output.contains("retries"))
        #expect(!output.contains("Locale.Configuration"))
        #expect(output.contains("1 local extension"))
    }

    /// A framework qualifier is not a repo module, so it arrives as a nested one — while the extension it names is written bare, matching nothing.
    ///
    /// Filtering unconditionally turned `digest SwiftUI.Color` into "no type or member named Color" followed by the very extensions it had just refused. The same shape holds for a real module name wherever module resolution is guessing.
    @Test
    func aFrameworkQualifiedTargetStillFindsItsBareExtensions() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let source = try TestSources.parsed(
            """
            import SwiftUI

            extension Color {
                static var brandPrimary: Color { Color() }
            }
            """,
            path: "Sources/Alpha/Color+Brand.swift",
            in: root
        )
        try store.replaceFiles([source]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "SwiftUI.Color", options: DigestOptions())

        #expect(output.contains("brandPrimary"))
        #expect(!output.contains("no type or member named"))
        // The qualifier bought nothing, and a wider answer must not read as a scoped one.
        #expect(output.contains("no extension is written `SwiftUI.Color`"))
    }

    /// A module qualifier must not suppress the note that the *nested* qualifier bought nothing — hanging the two off one `??` makes the wider answer read as more scoped, not less.
    @Test
    func aModuleQualifierDoesNotSwallowTheWideningNote() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let source = try TestSources.parsed(
            """
            extension Locale.Configuration {
                var coreBit: Int { 1 }
            }
            """,
            path: "Sources/Alpha/Configurations.swift",
            in: root
        )
        try store.replaceFiles([source]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "Alpha.URLSession.Configuration", options: DigestOptions())

        #expect(output.contains(" in Alpha"))
        #expect(output.contains("no extension is written `URLSession.Configuration`"))
    }

    /// The "extended in" tally on the no-extension-in-this-module branch counts the same fallback set, so it has to say so — otherwise it reads as a count of the qualified type while counting every same-leaf-named extension there is.
    @Test
    func theExtendedInTallySaysWhenItIsCountingTheWiderSet() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let source = try TestSources.parsed(
            """
            extension Locale.Configuration {
                var coreBit: Int { 1 }
            }
            """,
            path: "Sources/Alpha/Configurations.swift",
            in: root
        )
        let gamma = try TestSources.parsed("struct GammaHelper { let flag: Bool }", path: "Sources/Gamma/GammaHelper.swift", in: root)
        try store.replaceFiles([source, gamma]) { path in
            path.hasPrefix("Sources/Gamma") ? ("Gamma", false) : ("Alpha", false)
        }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "Gamma.URLSession.Configuration", options: DigestOptions())

        #expect(output.contains("no Configuration extension in Gamma"))
        #expect(output.contains("no extension is written `URLSession.Configuration`"))
        #expect(output.contains("digest URLSession.Configuration serves every module's extensions"))
    }

    /// The partial case prints `… outline truncated`; a wholly-dropped outline that printed nothing would make a view member read as having no structure worth showing rather than one whose structure did not fit.
    @Test
    func anOutlineDroppedForBudgetSaysSoRatherThanLookingStructureless() throws {
        let views = (0 ..< 40).map { index in
            """
                var view\(index): some View {
                    VStack {
                        if flag {
                            Text("a")
                        }
                        ForEach(items) { item in
                            Text(item)
                        }
                    }
                }
            """
        }.joined(separator: "\n\n")
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let source = try TestSources.parsed(
            "struct Screen: View {\n    let flag = true\n    let items: [String] = []\n\n\(views)\n}",
            path: "Sources/Alpha/Screen.swift",
            in: root
        )
        try store.replaceFiles([source]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "Screen", options: DigestOptions())

        #expect(output.contains("VStack"))
        #expect(output.contains("[outline omitted — budget spent]"))
    }

    /// A module digest legitimately shows a surface rather than a file, so it still hides private declarations.
    ///
    /// An answer that looks complete, though, is the one nobody thinks to re-ask with `--all`.
    @Test
    func aModuleDigestSaysHowMuchItWithheld() throws {
        let renderer = try Self.rulesFixture()

        let surface = try renderer.render(target: "Alpha", options: DigestOptions())
        let all = try renderer.render(target: "Alpha", options: DigestOptions(includeAllAccess: true))

        #expect(surface.contains("4 private/fileprivate declarations not shown — `--all`"))
        #expect(!all.contains("not shown"))
    }
}

// MARK: A test suite's own digest

/// A digest of a detected suite — its file's or the suite's own, by name — carries what a plain declaration surface cannot: a small helper's own source, and where the next test goes.
///
/// Detection is structural, the same shape `TestSymbolReader` already recognises a suite by, so an ordinary file (no `Testing`/`XCTest` import) takes none of this.
extension DigestRenderTests {
    private static func suiteFixture(_ source: String) throws -> DigestRenderer {
        try suiteFixture(files: ["Tests/GizmoTests.swift": source])
    }

    private static func suiteFixture(files: [String: String]) throws -> DigestRenderer {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try files.keys.sorted().map { try TestSources.parsed(files[$0] ?? "", path: $0, in: root) }
        try store.replaceFiles(parsed) { _ in ("Gizmo", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    /// A helper whose body is `lines` lines long, each distinguishable by its own marker.
    private static func helper(named name: String, lines: Int) -> String {
        let body = (0 ..< lines).map { "        _ = \"\(name)-\($0)\"" }.joined(separator: "\n")
        return "    private static func \(name)() {\n\(body)\n    }"
    }

    /// Padding so a fixture clears the compression floor and is answered as a digest rather than as its own source (`SourcePassthrough`) — below it, every assertion here would hold trivially, whatever this feature did or did not do, because the "digest" is just the file verbatim.
    private static func bulkTests(prefixed prefix: String, count: Int = 8) -> String {
        (0 ..< count).map { index in
            """
                @Test
                func \(prefix)\(index)() throws {
                    var total = 0
                    for step in 0 ..< 6 {
                        total += step
                    }
                    #expect(Self.call("go") == "GO")
                    #expect(total == 15)
                }
            """
        }.joined(separator: "\n\n")
    }

    /// The non-suite twin of `bulkTests`, for the fixture that carries no `@Test` or `Testing` import at all.
    private static func bulkFunctions(prefixed prefix: String, count: Int = 8) -> String {
        (0 ..< count).map { index in
            """
                func \(prefix)\(index)() {
                    var total = 0
                    for step in 0 ..< 6 {
                        total += step
                    }
                    _ = total
                }
            """
        }.joined(separator: "\n\n")
    }

    @Test
    func aSmallHelperInASuiteCarriesItsOwnSourceBesideItsSignature() throws {
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            private static func call(_ command: String) -> String {
                command.uppercased()
            }

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        // Confirms the fixture actually cleared the floor: otherwise the assertion below would hold for
        // the wrong reason — the raw source contains this line too.
        #expect(!output.contains("source itself follows"))
        #expect(output.contains("command.uppercased()"))
    }

    /// A trailing comment on the signature's own opening brace, and a nested block inside the body, used to fool the text scan into opening the body at the nested `if` instead — serving `return base` / `}` / `return 0` and dropping `let base = 1` with an unbalanced brace.
    ///
    /// The body is read from the parse now, not the text.
    @Test
    func aHelperWithATrailingCommentOnItsOpeningBraceInlinesItsRealBody() throws {
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            private static func build() -> Int { // builds the value
                let base = 1
                if base > 0 {
                    return base
                }
                return 0
            }

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        #expect(output.contains("let base = 1"))
        #expect(output.contains("if base > 0 {"))
        #expect(output.contains("return base"))
        #expect(output.contains("return 0"))
    }

    /// Code sharing a line with either of the body's braces is part of the body: sliced by whole lines between the brace lines, `let x = 7` after the `{` went missing (leaving `_ = x` naming nothing), and a body whose last statement shared the `}` line inlined nothing at all and was not even counted as withheld.
    @Test
    func codeOnABracesOwnLineIsInlinedWithTheRestOfTheBody() throws {
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            private static func opener() { let x = 7
                _ = x
            }

            private static func closer() {
                _ = 8 }

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        let lines = output.components(separatedBy: "\n")
        let opener = try #require(lines.firstIndex { $0.contains("func opener()") })
        let closer = try #require(lines.firstIndex { $0.contains("func closer()") })
        // Both of the opener's statements, at one indentation — the one on the brace's line stands where it belongs.
        #expect(Array(lines[opener + 1 ... opener + 2]) == ["        let x = 7", "        _ = x"], "\(output)")
        #expect(lines[closer + 1] == "        _ = 8", "\(output)")
        #expect(!output.contains("named by signature and range only"))
    }

    /// A helper whose body cannot be read — its file gone from disk since it was indexed — is counted among those named by signature and range only, never left out of the tally in silence.
    @Test
    func aHelperWhoseBodyCannotBeReadIsCountedAsWithheld() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed("""
        import Testing

        struct GizmoTests {
            private static func call(_ command: String) -> String {
                command.uppercased()
            }

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """, path: "Tests/GizmoTests.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Gizmo", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Tests/GizmoTests.swift"))

        let output = try renderer.render(target: "GizmoTests", options: DigestOptions())

        #expect(output.contains("func call(_ command: String) -> String"), "\(output)")
        #expect(output.contains("(1 helper named by signature and range only"), "\(output)")
    }

    @Test
    func aHelperOverTheLineCapKeepsOnlyItsSignature() throws {
        let longBody = (0 ..< 25).map { "            _ = \($0)" }.joined(separator: "\n")
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            private static func call(_ command: String) -> String {
        \(longBody)
                return command
            }

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        #expect(output.contains("func call(_ command: String) -> String"))
        #expect(!output.contains("_ = 0"))
    }

    /// The line names the suite, its last test, and the exact line a new test goes after.
    ///
    /// Rewritten from its first form, which named no suite: a file of two suites now gets one line each, so the line has to say which suite it is about.
    @Test
    func theLastTestsLineRangeIsNamedAsWhereANewOneGoes() throws {
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            private static func call(_ command: String) -> String {
                command.uppercased()
            }

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        // Eight nine-line tests from line 8, a blank line apart: the last spans 78-86.
        #expect(output.contains("last test in GizmoTests: bulk7() — Tests/GizmoTests.swift:78-86 — a new test goes after line 86"))
        #expect(!output.contains("bulk0() — Tests/GizmoTests.swift"))
    }

    /// A file holding two suites names each one's last test, rather than the last suite's last test for both.
    @Test
    func aFileOfTwoSuitesNamesEachSuitesLastTest() throws {
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            private static func call(_ command: String) -> String {
                command.uppercased()
            }

        \(Self.bulkTests(prefixed: "gizmo", count: 4))
        }

        struct WidgetTests {
            private static func call(_ command: String) -> String {
                command.lowercased()
            }

        \(Self.bulkTests(prefixed: "widget", count: 4))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        #expect(output.contains("last test in GizmoTests: gizmo3()"))
        #expect(output.contains("last test in WidgetTests: widget3()"))
    }

    /// A helper `offset` pages past never touches the budget or the withheld count: both are charged only against the members a page actually serves, so a helper on a page not shown cannot crowd out one that is.
    @Test
    func aHelperOffThePageNeverSpendsTheBudgetOfOneOnIt() throws {
        let helpers = ["alpha", "beta", "gamma"].map { Self.helper(named: $0, lines: 8) }.joined(separator: "\n\n")
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
        \(helpers)

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        // A file digest's first counted line is the struct's own summary, so offset 2 skips that and
        // alpha — the first helper — leaving beta and gamma on the page. Skipping alpha must not spend
        // any of its 8 lines against the 20-line budget beta and gamma still have to share — 16 of it,
        // well inside the cap.
        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions(offset: 2))

        #expect(output.contains("(…2 member lines skipped)"))
        #expect(!output.contains("\"alpha-7\""))
        #expect(output.contains("\"beta-7\""))
        #expect(output.contains("\"gamma-7\""))
        #expect(!output.contains("helper named by signature and range only"))
    }

    /// The inlined source is bounded across the whole digest as well as per helper: past the budget, helpers are named by signature and range only, and the answer says how many.
    @Test
    func helperSourceIsBoundedAcrossTheWholeDigest() throws {
        let helpers = ["alpha", "beta", "gamma", "delta"].map { Self.helper(named: $0, lines: 8) }.joined(separator: "\n\n")
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
        \(helpers)

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        // Eight lines each against a twenty-line budget: the first two fit, the next two do not.
        #expect(output.contains("\"alpha-7\""))
        #expect(output.contains("\"beta-7\""))
        #expect(!output.contains("\"gamma-0\""))
        #expect(!output.contains("\"delta-0\""))
        #expect(output.contains("func gamma()"))
        #expect(output.contains("(2 helpers named by signature and range only — helper source is inlined up to 10 lines each and 20 in all)"))
    }

    /// A helper's body sits one level beneath its signature whatever depth it was written at, a blank line in it stays empty, and a signature wrapped over several lines — or an attribute above it — is not served again as though it were the body.
    @Test
    func aHelpersBodyIsReindentedAndItsSignatureIsNotRepeated() throws {
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            @discardableResult
            private static func call(
                _ command: String
            ) -> String {
                let shouted = command.uppercased()

                return shouted
            }

        \(Self.bulkTests(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(!output.contains("source itself follows"))
        #expect(lines.contains("        let shouted = command.uppercased()"))
        #expect(lines.contains("        return shouted"))
        #expect(!lines.contains { !$0.isEmpty && $0.allSatisfy(\.isWhitespace) })
        #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces) == "_ command: String" })
        #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces) == "@discardableResult" })
    }

    /// Naming the suite as a type is the natural call, and gets both features: helpers inlined, including one declared in an extension in another file, and the last test named.
    @Test
    func aSuitesTypeDigestCarriesItsHelpersAndItsLastTest() throws {
        let renderer = try Self.suiteFixture(files: [
            "Tests/GizmoTests.swift": """
            import Testing

            struct GizmoTests {
                private static func call(_ command: String) -> String {
                    command.uppercased()
                }

            \(Self.bulkTests(prefixed: "bulk"))
            }
            """,
            "Tests/GizmoTests+Fixtures.swift": """
            import Testing

            extension GizmoTests {
                static func fixture() -> [String] {
                    ["go", "stop"]
                }

                @Test
                func finale() {
                    #expect(Self.fixture().count == 2)
                }
            }
            """,
        ])

        let output = try renderer.render(target: "GizmoTests", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        #expect(output.contains("command.uppercased()"))
        #expect(output.contains("[\"go\", \"stop\"]"))
        #expect(output.contains("last test in GizmoTests: finale() — Tests/GizmoTests+Fixtures.swift:8-11 — a new test goes after line 11"))
    }

    /// An XCTest suite is read the same way, on both digests, and a test method in an extension of the `XCTestCase` subclass is a test though the extension restates no inheritance.
    @Test
    func anXCTestSuiteIsReadTheSameWay() throws {
        let tests = (0 ..< 8).map { index in
            """
                func testDoubling\(index)() {
                    var total = 0
                    for step in 0 ..< 6 {
                        total += step
                    }
                    XCTAssertEqual(Self.call("go"), "GO")
                    XCTAssertEqual(total, 15)
                }
            """
        }.joined(separator: "\n\n")
        let renderer = try Self.suiteFixture(files: [
            "Tests/GizmoTests.swift": """
            import XCTest

            final class GizmoTests: XCTestCase {
                private static func call(_ command: String) -> String {
                    command.uppercased()
                }

            \(tests)
            }

            extension GizmoTests {
                func testThree() {
                    XCTAssertEqual(Self.call("a"), "A")
                }
            }
            """,
        ])

        let file = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())
        let type = try renderer.render(target: "GizmoTests", options: DigestOptions())

        for output in [file, type] {
            #expect(!output.contains("source itself follows"))
            #expect(output.contains("command.uppercased()"))
            #expect(output.contains("last test in GizmoTests: testThree()"))
        }
    }

    /// A file mixing both libraries still annotates its XCTest class as a suite, since a test method's own shape, not the file's imports, decides its style.
    @Test
    func aMixedFilesXCTestClassIsAnnotatedAsASuiteToo() throws {
        let tests = (0 ..< 8).map { index in
            """
                func testDoubling\(index)() {
                    var total = 0
                    for step in 0 ..< 6 {
                        total += step
                    }
                    XCTAssertEqual(Self.call("go"), "GO")
                    XCTAssertEqual(total, 15)
                }
            """
        }.joined(separator: "\n\n")
        let renderer = try Self.suiteFixture("""
        import Testing
        import XCTest

        @Suite
        struct GizmoTests {
            @Test
            func first() {}
        }

        final class WidgetTests: XCTestCase {
            private static func call(_ command: String) -> String {
                command.uppercased()
            }

        \(tests)
        }

        extension WidgetTests {
            func testThree() {
                XCTAssertEqual(Self.call("a"), "A")
            }
        }
        """)

        let file = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(file.contains("last test in WidgetTests: testThree()"))
    }

    @Test
    func signaturesOnlyDropsTheHelpersSourceButKeepsTheLastTestNote() throws {
        let renderer = try Self.suiteFixture("""
        import Testing

        struct GizmoTests {
            private static func call(_ command: String) -> String {
                command.uppercased()
            }

            @Test
            func first() throws {
                #expect(Self.call("go") == "GO")
            }
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions(signaturesOnly: true))

        #expect(!output.contains("command.uppercased()"))
        #expect(output.contains("a new test goes after line"))
    }

    @Test
    func aFileWithNoTestingImportIsNotReadAsASuite() throws {
        let renderer = try Self.suiteFixture("""
        struct GizmoTests {
            private static func call(_ command: String) -> String {
                command.uppercased()
            }

        \(Self.bulkFunctions(prefixed: "bulk"))
        }
        """)

        let output = try renderer.render(target: "Tests/GizmoTests.swift", options: DigestOptions())

        #expect(!output.contains("source itself follows"))
        #expect(output.contains("func call(_ command: String) -> String"))
        #expect(!output.contains("command.uppercased()"))
        #expect(!output.contains("last test"))
    }
}

// MARK: Line ranges inside a type

/// Lines that fall in a type but not squarely in one member: a doc comment, a blank line, the whole type.
///
/// Each used to resolve to the enclosing type, since the type is the innermost declaration a line between its members intersects — so a blank line in a large type served the first two hundred lines of it.
extension DigestRenderTests {
    private static func rangeFixture(_ source: String) throws -> DigestRenderer {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(source, path: "Sources/Alpha/Gizmo.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    /// A struct of `count` documented six-line methods a blank line apart, from line 3: member `i` has its doc comment on line `4 + 8i`, spans `5 + 8i` to `10 + 8i`, and is followed by a blank line; the struct closes on line `3 + 8 × count`.
    private static func documentedStruct(count: Int) -> String {
        let members = (0 ..< count).map { index in
            """
                /// Step \(index) of the run.
                func step\(index)() -> Int {
                    var total = \(index)
                    total += 1
                    total *= 2
                    return total
                }
            """
        }.joined(separator: "\n\n")
        return "import Foundation\n\nstruct Gizmo {\n\(members)\n}\n"
    }

    @Test
    func aLineInAMembersDocCommentResolvesToThatMember() throws {
        let renderer = try Self.rangeFixture(Self.documentedStruct(count: 10))

        let output = try renderer.render(target: "Sources/Alpha/Gizmo.swift:12", options: DigestOptions())

        #expect(output.hasPrefix("Alpha.Gizmo.step1() — func — Sources/Alpha/Gizmo.swift:13-18"))
        #expect(!output.contains("struct Gizmo"))
    }

    /// A blank line between the members of a large type is answered with its neighbours, named with their ranges — not with the type's source.
    @Test
    func aLineBetweenMembersOfALargeTypeNamesTheNearestMembers() throws {
        let renderer = try Self.rangeFixture(Self.documentedStruct(count: 10))

        let output = try renderer.render(target: "Sources/Alpha/Gizmo.swift:11", options: DigestOptions())

        #expect(output.contains("line 11 is in Alpha.Gizmo — struct — Sources/Alpha/Gizmo.swift:3-83, but in none of its members"))
        #expect(output.contains("  before: digest Alpha.Gizmo.step0() — func — Sources/Alpha/Gizmo.swift:5-10"))
        #expect(output.contains("  after: digest Alpha.Gizmo.step1() — func — Sources/Alpha/Gizmo.swift:13-18"))
        #expect(!output.contains("var total"))
    }

    /// A range running past the container's own closing brace intersects it only in part — the claim names the lines actually inside it, not the whole of what was asked.
    @Test
    func aRangeRunningPastTheContainersCloseClaimsOnlyWhatIsInsideIt() throws {
        let renderer = try Self.rangeFixture(Self.documentedStruct(count: 10))

        // Gizmo closes on line 83; nothing in the file reaches lines 84-90 at all.
        let output = try renderer.render(target: "Sources/Alpha/Gizmo.swift:83-90", options: DigestOptions())

        #expect(output.contains("line 83 is in Alpha.Gizmo — struct — Sources/Alpha/Gizmo.swift:3-83, but in none of its members"))
        #expect(!output.contains("lines 83-90"))
    }

    /// A line in a large type's own doc comment is inside the type as the walk counts it, so the claim starts there — never at the type's first line, which would name a range that ends before it begins ("lines 10-8").
    @Test
    func aRangeInALargeTypesDocCommentClaimsOnlyLinesThatExist() throws {
        // The struct's doc comment on 7-9 and the struct itself on 10-90, the review's shape: a header, a
        // blank line, an import and another blank line above it.
        let source = Self.documentedStruct(count: 10).replacingOccurrences(
            of: "import Foundation\n\nstruct Gizmo {",
            with: "//\n// A header.\n//\n\nimport Foundation\n\n/// A gizmo.\n///\n/// Of many steps.\nstruct Gizmo {"
        )
        let renderer = try Self.rangeFixture(source)

        for (target, claim) in [
            ("Sources/Alpha/Gizmo.swift:8", "line 8 is in"),
            ("Sources/Alpha/Gizmo.swift:7-9", "lines 7-9 are in"),
            ("Sources/Alpha/Gizmo.swift:5-8", "lines 7-8 are in"),
        ] {
            let output = try renderer.render(target: target, options: DigestOptions())

            #expect(output.hasPrefix("Sources/Alpha/Gizmo.swift \(claim) Alpha.Gizmo — struct — Sources/Alpha/Gizmo.swift:10-90, but in none of its members"), "\(target): \(output)")
        }
    }

    /// A between-members answer is served with an offset it cannot use, and one line naming the offset as unused — never refused, never the offset dropped in silence.
    ///
    /// That answer is one page, a short list of neighbours, so an offset sent with it has nothing to skip.
    ///
    /// Rewritten from a test that expected a refusal, when the specified behaviour changed: one answer leaves no doubt what the offset was meant to page, where several blocks or several targets do.
    @Test
    func anOffsetOnABetweenMembersAnswerIsServedAndNamedAsUnused() throws {
        let renderer = try Self.rangeFixture(Self.documentedStruct(count: 10))

        let plain = try renderer.render(target: "Sources/Alpha/Gizmo.swift:11", options: DigestOptions())
        let offset = try renderer.render(target: "Sources/Alpha/Gizmo.swift:11", options: DigestOptions(offset: 3))

        #expect(offset == plain + "\n(offset 3 unused — this answer is a single page)")
        #expect(offset.hasPrefix("Sources/Alpha/Gizmo.swift line 11 is in Alpha.Gizmo"))
    }

    /// A type small enough for the compression floor is served whole for the same line, since its digest would have been its source anyway.
    @Test
    func aLineBetweenMembersOfASmallTypeServesTheType() throws {
        let renderer = try Self.rangeFixture(Self.documentedStruct(count: 2))

        let output = try renderer.render(target: "Sources/Alpha/Gizmo.swift:11", options: DigestOptions())

        #expect(output.hasPrefix("Alpha.Gizmo — struct — Sources/Alpha/Gizmo.swift:3-19"))
        #expect(output.contains("func step0()"))
        #expect(output.contains("func step1()"))
    }

    /// A range covering a whole type is that type, served as one block with its header and the comments between its members — not each member one by one.
    @Test
    func aRangeSpanningAWholeTypeServesItAsOneBlock() throws {
        let renderer = try Self.rangeFixture(Self.documentedStruct(count: 10))

        for target in ["Sources/Alpha/Gizmo.swift:3-83", "Sources/Alpha/Gizmo.swift:1-90"] {
            let output = try renderer.render(target: target, options: DigestOptions())

            #expect(output.hasPrefix("Alpha.Gizmo — struct — Sources/Alpha/Gizmo.swift:3-83"), "\(target)")
            #expect(output.contains("struct Gizmo {"))
            #expect(output.contains("/// Step 5 of the run."))
            #expect(!output.contains(" — func — "))
        }
    }

    /// A one-line type and the cases packed on its line share one range, and are served once, as the type.
    @Test
    func aOneLineEnumIsServedOnceAsTheEnum() throws {
        let renderer = try Self.rangeFixture("enum Gizmo { case wood, coal, oil }\n")

        let output = try renderer.render(target: "Sources/Alpha/Gizmo.swift:1", options: DigestOptions())

        #expect(output.hasPrefix("Alpha.Gizmo — enum — Sources/Alpha/Gizmo.swift:1"))
        #expect(output.components(separatedBy: "case wood, coal, oil").count == 2)
    }

    /// Two declarations too long to serve whole: a top-level function (a leaf) on 1-252, and a struct (a container) on 254-507 holding one long method.
    static func twoLongDeclarations() -> String {
        let body = (0 ..< 250).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        let nested = (0 ..< 250).map { "        let value\($0) = \($0)" }.joined(separator: "\n")
        return "func drain() {\n\(body)\n}\n\nstruct Long {\n    func run() {\n\(nested)\n    }\n}\n"
    }

    /// A truncated block served beside another names its own exact range with the offset as the call that pages it — and that call, followed verbatim, pages that one block, for a leaf and a container alike.
    ///
    /// The advice used to be a bare "pass --offset 200", which sent back with the range that produced several blocks is refused; and the refusal's own way out, the block's header name, serves a type's digest rather than the rest of its source.
    @Test
    func aTruncatedBlockBesideAnotherNamesTheCallThatPagesIt() throws {
        let renderer = try Self.rangeFixture(Self.twoLongDeclarations())

        let answer = try renderer.render(target: "Sources/Alpha/Gizmo.swift:1-600", options: DigestOptions())
        let advice = answer.matches(of: /digest (?<target>\S+) --offset (?<offset>\d+)/).map { match in
            (target: String(match.output.target), offset: Int(match.output.offset) ?? 0)
        }

        #expect(advice.map(\.target) == ["Sources/Alpha/Gizmo.swift:1-252", "Sources/Alpha/Gizmo.swift:254-507"])
        let headers = ["Alpha.drain() — func — Sources/Alpha/Gizmo.swift:1-252", "Alpha.Long — struct — Sources/Alpha/Gizmo.swift:254-507"]
        for (call, header) in zip(advice, headers) {
            let page = try renderer.render(target: call.target, options: DigestOptions(offset: call.offset))

            #expect(page.hasPrefix(header + "\n"), "\(call.target)")
            #expect(page.contains("(…200 body lines skipped)"))
            #expect(page.contains("let value249 = 249"))
            #expect(page.components(separatedBy: " — Sources/Alpha/Gizmo.swift:").count == 2, "\(call.target) served more than its one block")
        }
    }

    /// The same advice on the MCP face is spelled as the tool call, not as the command line: `target:` with the range, and `offset:` beside it.
    @Test
    func aTruncatedBlocksAdviceIsSpelledForTheFaceServingIt() throws {
        let renderer = try Self.rangeFixture(Self.twoLongDeclarations())

        let answer = try renderer.render(target: "Sources/Alpha/Gizmo.swift:1-600", options: DigestOptions(spelling: .toolCall))

        #expect(answer.contains("digest target:\"Sources/Alpha/Gizmo.swift:1-252\" offset:200, or Read Sources/Alpha/Gizmo.swift from line 201"))
        #expect(answer.contains("digest target:\"Sources/Alpha/Gizmo.swift:254-507\" offset:200, or Read Sources/Alpha/Gizmo.swift from line 454"))
        #expect(!answer.contains("--offset"))
    }

    /// A range resolving to one declaration keeps the plain advice, a bare offset with no target to repeat, spelled for the face serving it.
    @Test
    func aTruncatedSingleBlockKeepsItsPlainAdvice() throws {
        let renderer = try Self.rangeFixture(Self.twoLongDeclarations())

        let tool = try renderer.render(target: "Sources/Alpha/Gizmo.swift:1-252", options: DigestOptions(spelling: .toolCall))
        let command = try renderer.render(target: "Sources/Alpha/Gizmo.swift:1-252", options: DigestOptions(spelling: .commandLine))

        #expect(tool.contains("… truncated: 52 more lines — pass offset: 200, or Read Sources/Alpha/Gizmo.swift from line 201"))
        #expect(command.contains("… truncated: 52 more lines — pass --offset 200, or Read Sources/Alpha/Gizmo.swift from line 201"))
    }
}

// MARK: Long signatures

/// A member line never cuts inside a parameter list: a long signature wraps at its parameter boundaries, and one past the total bound is cut at a boundary with a count of the rest.
extension DigestRenderTests {
    /// A `Gizmo` of the given functions, each with a forty-line body so the type is answered as a digest rather than as its source; function `i` spans lines `2 + 43i` to `43 + 43i`.
    private static func signatureFixture(_ signatures: [String]) throws -> DigestRenderer {
        let body = (0 ..< 40).map { "        _ = \"value\($0)\"" }.joined(separator: "\n")
        let functions = signatures.map { "    \($0) {\n\(body)\n    }" }.joined(separator: "\n\n")
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed("struct Gizmo {\n\(functions)\n}\n", path: "Sources/Alpha/Gizmo.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    /// The lines of the member line opening with `opening`: its first line and every continuation indented beneath it.
    private static func memberLines(opening: String, in output: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let lines = output.components(separatedBy: "\n")
        let first = try #require(lines.firstIndex { $0.hasPrefix("  " + opening) }, sourceLocation: sourceLocation)
        let continuations = lines[(first + 1)...].prefix { $0.hasPrefix("   ") }
        return [lines[first]] + continuations
    }

    @Test func aLongSignatureWrapsAtItsParameterBoundariesWithEveryParameterShown() throws {
        let labels = ["path", "output", "build", "log", "settle", "appearance", "locale", "nonce", "timeout"]
        let parameters = labels.map { "\($0): String? = nil" }.joined(separator: ", ")
        let signature = "@MainActor @discardableResult public func walk(\(parameters)) async throws -> Bool"
        try #require(signature.count > 200)
        let output = try Self.signatureFixture([signature]).render(target: "Gizmo", options: DigestOptions())

        let member = try Self.memberLines(opening: "@MainActor @discardableResult public func walk(", in: output)
        // The range stays on the first line; what is left of each line is signature, and every one but the last ends between two parameters.
        #expect(member[0].contains("  :2-43"))
        let shown = member.map { $0.components(separatedBy: "  :")[0] }
        #expect(shown.count > 1)
        #expect(shown[0].count <= 202)
        #expect(!member.joined().contains("…"))
        for line in shown.dropLast() {
            #expect(line.hasSuffix(","))
        }
        #expect(shown.last?.hasSuffix("timeout: String? = nil) async throws -> Bool") == true)
        for label in labels {
            #expect(member.contains { $0.contains("\(label): String? = nil") }, "\(label) is missing")
        }
        #expect(member.contains { $0.contains("nonce: String? = nil,") })
        #expect(!output.contains("was cut at a parameter boundary"))
    }

    @Test func aSignaturePastTheTotalBoundEndsWithTheCountOfParametersLeftOff() throws {
        let parameters = (0 ..< 100).map { "value\($0): Int = 0" }.joined(separator: ", ")
        let signature = "public func walk(\(parameters)) -> Bool"
        try #require(signature.count > 800)
        let output = try Self.signatureFixture([signature]).render(target: "Gizmo", options: DigestOptions())

        let member = try Self.memberLines(opening: "public func walk(", in: output)
        let text = member.joined(separator: "\n")
        let shownCount = (0 ..< 100).count { text.contains("value\($0): Int = 0") }

        #expect(shownCount > 0)
        #expect(shownCount < 100)
        #expect(!text.contains("value\(shownCount): Int"))
        #expect(member.last?.hasSuffix("value\(shownCount - 1): Int = 0, … +\(100 - shownCount) params") == true)
        #expect(!text.contains("-> Bool"))
        #expect(output.contains("`digest <Type>.<member>` serves the member's whole source"))
    }

    @Test func aParameterListOpeningPastTheWidthContinuesBeneathItsGenericClause() throws {
        let constraint = "CustomStringConvertible & Sendable & Hashable"
        let generics = ["Alpha", "Beta", "Depot", "Orchard"].map { "\($0): \(constraint)" }.joined(separator: ", ")
        let signature = "@MainActor @discardableResult public func walk<\(generics)>(x: Int, y: Int) -> Bool where Alpha: Comparable"
        try #require(signature.prefix { $0 != "(" }.count > 200)
        let output = try Self.signatureFixture([signature]).render(target: "Gizmo", options: DigestOptions())

        let member = try Self.memberLines(opening: "@MainActor @discardableResult public func walk", in: output)

        #expect(member[0] == "  @MainActor @discardableResult public func walk  :2-43")
        #expect(member.dropFirst().allSatisfy { $0.count <= 202 })
        #expect(member.dropFirst().first?.hasPrefix("      <Alpha: \(constraint),") == true)
        #expect(member.contains { $0.contains("Orchard: \(constraint)>(x: Int,") })
        #expect(member.last?.hasSuffix("y: Int) -> Bool where Alpha: Comparable") == true)
        #expect(!member.joined().contains("…"))
        #expect(!output.contains("was cut at a parameter boundary"))
    }

    @Test func aDeclarationTooLongForTheFirstLineEndsWithTheCountOfEveryParameter() throws {
        let signature = "public func walk" + String(repeating: "Gizmo", count: 50) + "(x: Int, y: Int) -> Bool"
        let output = try Self.signatureFixture([signature]).render(target: "Gizmo", options: DigestOptions())

        let member = try Self.memberLines(opening: "public func walk", in: output)

        #expect(member.count == 2)
        #expect(member[0].components(separatedBy: "  :")[0].count == 202)
        #expect(member[1] == "      … +2 params")
        #expect(output.contains("`digest <Type>.<member>` serves the member's whole source"))
    }

    @Test func aSignatureWithinTheCapIsTheLineItAlwaysWas() throws {
        let signature = "public func walk(path: String? = nil, output: String? = nil) -> Bool"
        let output = try Self.signatureFixture([signature, signature.replacingOccurrences(of: "walk", with: "reload")])
            .render(target: "Gizmo", options: DigestOptions())

        #expect(output.components(separatedBy: "\n").contains("  public func walk(path: String? = nil, output: String? = nil) -> Bool  :2-43"))
        #expect(output.components(separatedBy: "\n").contains("  public func reload(path: String? = nil, output: String? = nil) -> Bool  :45-86"))
    }
}

// MARK: - A line range inside one long member

extension DigestRenderTests {
    /// `long()` is one line past the source floor (`:2-62`, 61 lines) and `short()` sits on it (`:64-123`, 60 lines), so the pair pins the floor itself; every body line carries its own marker, so line `L` of `long()` reads `long-(L-3)`.
    private static func ledgerRenderer() throws -> DigestRenderer {
        try suiteFixture(files: [
            "Sources/Gizmo/Ledger.swift": "struct Ledger {\n\(helper(named: "long", lines: 59))\n\n\(helper(named: "short", lines: 58))\n}\n",
        ])
    }

    /// The source lines `lines` of `long()`'s body, as the file carries them.
    private static func longLines(_ lines: ClosedRange<Int>) -> String {
        lines.map { "        _ = \"long-\($0 - 3)\"" }.joined(separator: "\n")
    }

    @Test
    func aRangeInsideALongMemberServesOnlyTheLinesAskedFor() throws {
        let output = try Self.ledgerRenderer().render(target: "Sources/Gizmo/Ledger.swift:20-30", options: DigestOptions())

        #expect(output.hasPrefix("Sources/Gizmo/Ledger.swift lines 20-30, in Gizmo.Ledger.long() — func — :2-62 (61 lines; digest Gizmo.Ledger.long() for all of it)\n\n"))
        #expect(output.hasSuffix("\n\n" + Self.longLines(20 ... 30)))
        #expect(!output.contains("\"long-16\""))
        #expect(!output.contains("\"long-28\""))
        #expect(output.utf8.count < 600)
    }

    @Test
    func aSingleLineInsideALongMemberServesAWindowClampedToTheMember() throws {
        let renderer = try Self.ledgerRenderer()
        let middle = try renderer.render(target: "Sources/Gizmo/Ledger.swift:30", options: DigestOptions())
        let nearTheTop = try renderer.render(target: "Sources/Gizmo/Ledger.swift:4", options: DigestOptions())

        #expect(middle.hasPrefix("Sources/Gizmo/Ledger.swift lines 27-33 (line 30 with up to 3 lines either side), in Gizmo.Ledger.long() — func — :2-62"))
        #expect(middle.hasSuffix("\n\n    private static func long()\n(…24 lines skipped)\n" + Self.longLines(27 ... 33) + "\nlines 2-62; read it by range"))
        #expect(nearTheTop.hasPrefix("Sources/Gizmo/Ledger.swift lines 2-7 (line 4 with up to 3 lines either side)"))
        #expect(nearTheTop.hasSuffix("\n\n    private static func long() {\n" + Self.longLines(3 ... 7) + "\nlines 2-62; read it by range"))
    }

    @Test
    func aRangeInsideAMemberOnTheSourceFloorServesItWhole() throws {
        let output = try Self.ledgerRenderer().render(target: "Sources/Gizmo/Ledger.swift:80-90", options: DigestOptions())

        #expect(output.hasPrefix("Gizmo.Ledger.short() — func — Sources/Gizmo/Ledger.swift:64-123\n\n    private static func short() {\n"))
        #expect(output.contains("\"short-0\""))
        #expect(output.hasSuffix("\"short-57\"\n    }"))
    }

    @Test
    func aRangeAcrossALongMemberAndItsNeighbourServesBothWhole() throws {
        let output = try Self.ledgerRenderer().render(target: "Sources/Gizmo/Ledger.swift:60-66", options: DigestOptions())

        #expect(!output.contains(", in Gizmo.Ledger.long()"))
        #expect(output.hasPrefix("Gizmo.Ledger.long() — func — Sources/Gizmo/Ledger.swift:2-62\n\n    private static func long() {\n"))
        #expect(output.contains("\"long-0\""))
        #expect(output.contains("Gizmo.Ledger.short() — func — Sources/Gizmo/Ledger.swift:64-123"))
        #expect(output.hasSuffix("\"short-57\"\n    }"))
    }
}
