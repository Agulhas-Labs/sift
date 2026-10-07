//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers Docs/Design.md §7: a file that did not parse cleanly is *named*, and every answer sourced from one says so inline.
///
/// The premise these all rest on is `brokenFileStillYieldsSymbols`: a parse error truncates a file's symbols rather than discarding them, so the answer looks complete and correct. That is why a repo-wide count cannot discharge the duty — a reader holding a digest cannot tell from it whether their file is one of the four.
@Suite(.temporaryDirectories)
struct ParseErrorAttributionTests {
    /// A file whose later declarations are lost to a syntax error, and whose earlier ones survive into the index.
    private static var brokenSource: String {
        """
        struct Broken {
            let kept = 1
            func alsoKept() {}
            func truncated(
        }
        """
    }

    private static var cleanSource: String {
        """
        struct Clean {
            let fine = 1
            func alsoFine() {}
        }
        """
    }

    /// Two top-level declarations, of which one unclosed brace leaves exactly one in the index.
    ///
    /// The shape every count property here is measured against: the file is not rejected and the answer is not empty, so what a total loses to it is arithmetic and nothing a reader can see.
    private static var swallowingSource: String {
        """
        struct Widget {
            func alpha() {
                if true {
        }

        struct Gadget {
            var beta: Int { 1 }
        }
        """
    }

    private static func seededStore() throws -> IndexStore {
        let store = try TestSources.makeStore()
        let broken = try TestSources.parsed(brokenSource, path: "Sources/Alpha/Broken.swift")
        let clean = try TestSources.parsed(cleanSource, path: "Sources/Alpha/Clean.swift")
        try store.replaceFiles([broken, clean]) { _ in ("Alpha", false) }
        return store
    }

    private static func digest(_ target: String, store: IndexStore, root: URL = URL(fileURLWithPath: "/tmp")) throws -> String {
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    @Test
    func brokenFileStillYieldsSymbols() throws {
        let parsed = try TestSources.parsed(Self.brokenSource, path: "Sources/Alpha/Broken.swift")

        #expect(parsed.parseErrorCount > 0)
        #expect(parsed.symbols.contains { $0.name == "Broken" })
    }

    @Test
    func typeDigestNamesTheBrokenFileItDrewFrom() throws {
        let store = try Self.seededStore()

        let rendered = try Self.digest("Broken", store: store)

        #expect(rendered.contains("⚠ parse errors"))
        #expect(rendered.contains("Sources/Alpha/Broken.swift"))
        #expect(rendered.hasPrefix("⚠ parse errors"))
    }

    /// The banner only means something if a clean answer never carries it — an unconditional warning is the decorative counter again, one line lower.
    ///
    /// The extension-count note is the one deliberate exception, and it is asserted here rather than left to be met by surprise: that figure has no scope to *be* answer-scoped to, because an extension may be declared in any file, so the file that would have raised the count is never among the ones cited. ``ParseErrorCountTests`` owns that property; what matters here is that a clean type in a repository holding a broken file carries that one line and nothing else — the broken path is not named and the banner's own words do not appear.
    ///
    /// Asserted against those words rather than against the substring `parse errors`: the note says "a parse error" in the singular and would slip through a substring check silently, leaving the test green over a property it had stopped covering.
    @Test
    func cleanTypeDigestCarriesNoBanner() throws {
        let store = try Self.seededStore()

        let rendered = try Self.digest("Clean", store: store)

        #expect(!rendered.contains("declarations may be missing"))
        #expect(!rendered.contains("Sources/Alpha/Broken.swift"))
        #expect(rendered.contains("⚠ this type's extension count is a floor"))
    }

    @Test
    func fileDigestNamesTheBrokenFile() throws {
        let store = try Self.seededStore()

        let rendered = try Self.digest("Sources/Alpha/Broken.swift", store: store)

        #expect(rendered.hasPrefix("⚠ parse errors"))
        #expect(rendered.contains("Sources/Alpha/Broken.swift"))
    }

    /// A type declared cleanly but *extended* in a broken file is the case a single-path check would miss: the members shown come from both files, so both must be checked.
    @Test
    func typeDigestNamesABrokenExtensionFile() throws {
        let store = try TestSources.makeStore()
        let clean = try TestSources.parsed(Self.cleanSource, path: "Sources/Alpha/Clean.swift")
        let brokenExtension = try TestSources.parsed(
            """
            extension Clean {
                func fromExtension() {}
                func truncated(
            }
            """,
            path: "Sources/Alpha/Clean+Extras.swift"
        )
        try store.replaceFiles([clean, brokenExtension]) { _ in ("Alpha", false) }

        let rendered = try Self.digest("Clean", store: store)

        #expect(rendered.hasPrefix("⚠ parse errors"))
        #expect(rendered.contains("Sources/Alpha/Clean+Extras.swift"))
        #expect(!rendered.contains("Sources/Alpha/Clean.swift —"))
    }

    @Test
    func moduleDigestNamesBrokenFilesInThatModuleOnly() throws {
        let store = try TestSources.makeStore()
        let broken = try TestSources.parsed(Self.brokenSource, path: "Sources/Alpha/Broken.swift")
        let otherModule = try TestSources.parsed(
            """
            struct AlsoBroken {
                func truncated(
            }
            """,
            path: "Sources/Beta/AlsoBroken.swift"
        )
        try store.replaceFiles([broken, otherModule]) { ($0.hasPrefix("Sources/Alpha") ? "Alpha" : "Beta", false) }

        // Asserted against the banner line alone: a module digest lists every file it covers as a section heading, so checking the whole answer for the path would pass with no banner at all.
        let rendered = try Self.digest("Alpha", store: store)
        let banner = try #require(rendered.split(separator: "\n").first).description

        #expect(banner.hasPrefix("⚠ parse errors"))
        #expect(banner.contains("Sources/Alpha/Broken.swift"))
        #expect(!banner.contains("Sources/Beta/AlsoBroken.swift"))
    }

    @Test
    func whereNamesTheBrokenFileAmongItsDeclarations() async throws {
        let store = try Self.seededStore()
        let renderer = WhereRenderer(store: store)

        let rendered = try await renderer.render(query: "Broken", semantic: .inactive(note: "test run")).body

        #expect(rendered.contains("⚠ parse errors"))
        #expect(rendered.contains("Sources/Alpha/Broken.swift"))
    }

    /// The banner sits above the declarations it qualifies, not below them — the placement lesson refusals already taught, since a caveat printed after the content is read after the decision.
    @Test
    func whereBannerPrecedesTheDeclarationsItQualifies() async throws {
        let store = try Self.seededStore()
        let renderer = WhereRenderer(store: store)

        let rendered = try await renderer.render(query: "Broken", semantic: .inactive(note: "test run")).body
        let bannerIndex = try #require(rendered.range(of: "⚠ parse errors")).lowerBound
        let declarationsIndex = try #require(rendered.range(of: "declarations (")).lowerBound

        #expect(bannerIndex < declarationsIndex)
    }

    /// Answer-scoped, deliberately: a `where` about a clean symbol stays clean even while the repo holds a broken file, because warning on every answer is what taught the reader to skip the warning.
    @Test
    func whereCarriesNoBannerWhenTheBrokenFileIsNotCited() async throws {
        let store = try Self.seededStore()
        let renderer = WhereRenderer(store: store)

        let rendered = try await renderer.render(query: "Clean", semantic: .inactive(note: "test run")).body

        #expect(!rendered.contains("parse errors"))
    }

    /// The inversion: an answer that claims a declaration is *absent* names the broken files it never drew on.
    ///
    /// Every other banner here is answer-scoped, and rightly — what a reader needs is whether the files this answer came from parsed. An absence claim turns that around: the file that would disprove it is by definition not cited, so scoping the notice makes it go quiet in the one case it exists for. One unclosed brace swallows everything below it in the file, which is how `no symbol named Gadget` comes to be said about a struct written in plain sight.
    @Test
    func anAbsenceAnswerNamesBrokenFilesItNeverDrewOn() async throws {
        let store = try TestSources.makeStore()
        let swallowing = try TestSources.parsed(Self.swallowingSource, path: "Sources/Alpha/Swallowing.swift")
        try store.replaceFiles([swallowing]) { _ in ("Alpha", false) }
        let renderer = WhereRenderer(store: store)

        let missingType = try Self.digest("Gadget", store: store)
        let missingMember = try await renderer.render(query: "Gadget.beta", semantic: .inactive(note: "test run")).body
        let nearestFromDigest = try Self.digest("Widge", store: store)
        let nearestFromWhere = try await renderer.render(query: "Widge", semantic: .inactive(note: "test run")).body

        #expect(missingType.contains("no symbol named Gadget in the index"))
        #expect(missingType.contains("parse errors elsewhere in this repo"))
        #expect(missingType.contains("Sources/Alpha/Swallowing.swift"))
        #expect(missingMember.contains("no declarations found"))
        #expect(missingMember.contains("parse errors elsewhere in this repo"))
        // A near-miss list leads with an absence too, so it is in the class rather than an exception to it.
        #expect(nearestFromDigest.contains("nearest symbols"))
        #expect(nearestFromDigest.contains("parse errors elsewhere in this repo"))
        #expect(nearestFromWhere.contains("nearest symbols"))
        #expect(nearestFromWhere.contains("parse errors elsewhere in this repo"))
    }

    /// Same glyph, two scopes, so the sentences have to differ — a reader told to open the named files is being told the wrong thing by half of them.
    @Test
    func theTwoBannerScopesAreDistinguishableOnSight() async throws {
        let store = try Self.seededStore()
        let renderer = WhereRenderer(store: store)

        let drawnFrom = try await renderer.render(query: "Broken", semantic: .inactive(note: "test run")).body
        let absent = try await renderer.render(query: "NothingLikeThis", semantic: .inactive(note: "test run")).body

        #expect(drawnFrom.contains("⚠ parse errors — declarations may be missing from:"))
        #expect(!drawnFrom.contains("elsewhere in this repo"))
        #expect(absent.contains("parse errors elsewhere in this repo"))
        #expect(absent.contains("Not files this answer drew on"))
    }

    /// The cap is what makes the difference actionable: eight paths are named and the rest are counted, and the file that decides the reader's question can sit inside the count.
    @Test
    func aTruncatedAbsenceBannerNamesTheCommandThatListsTheRest() {
        let justFits = ParseErrorNotice(paths: (1 ... 8).map { "Sources/Alpha/Broken\($0).swift" })
        let overflows = ParseErrorNotice(paths: (1 ... 13).map { "Sources/Alpha/Broken\($0).swift" })

        #expect(justFits.absenceBanner?.contains("more)") == false)
        #expect(justFits.absenceBanner?.contains("sift status") == false)
        #expect(overflows.absenceBanner?.contains("(+5 more)") == true)
        #expect(overflows.absenceBanner?.contains("`sift status` lists them all") == true)
    }

    @Test
    func statusNamesEveryFileWithParseErrors() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.brokenSource, to: "Sources/App/Broken.swift", in: root)
        try TestSources.write(Self.cleanSource, to: "Sources/App/Clean.swift", in: root)
        try TestSources.commitAll(in: root, message: "add sources")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("1 file(s) have parse errors"))
        // Scoped to the parse-error listing rather than the whole of `status`: a fixture repo has no build
        // file, so the guessed-module listing below it names every file including the clean one — correctly.
        let afterHeading = status.components(separatedBy: "have parse errors").last ?? ""
        let listing = afterHeading.components(separatedBy: "⚠").first ?? afterHeading
        #expect(listing.contains("Sources/App/Broken.swift"))
        #expect(!listing.contains("Sources/App/Clean.swift"))
    }

    /// Module resolution's fallback needs an in-band warning of its own: those files answer about a module that does not exist, and nothing else in the answer says so.
    @Test
    func statusNamesEveryFileWhoseModuleWasGuessed() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.cleanSource, to: "Sources/App/Clean.swift", in: root)
        try TestSources.commitAll(in: root, message: "add sources")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("have a guessed module"))
        #expect(status.contains("Sources/App/Clean.swift (guessed: Sources)"))
    }

    /// Beside the guessed files, `status` says which build files actually named a module — the question the count on its own never answered.
    ///
    /// A module-resolution defect shows here as "100% guessed" and is not diagnosable from that alone: an unreadable build system, a missing generated project and a spec named after its product all render identically. It counts *contributions*, so a repository that resolves nothing cannot print the same line as one that resolves everything, and a real spec declaring sources that name nothing on disk is called out as the near miss it is.
    @Test
    func statusSaysWhichBuildFilesNamedAModule() async throws {
        let root = try TestSources.makeTempRepo()
        for index in 0 ..< 12 {
            try TestSources.write("struct Clean\(index) {}\n", to: "Sources/App/Clean\(index).swift", in: root)
        }
        try TestSources.write("name: CI\non: [push]\njobs:\n  build:\n    runs-on: macos-latest\n", to: "ci.yml", in: root)
        try TestSources.write(
            """
            name: Ghost
            targets:
              GhostKit:
                type: framework
                sources: Missing
            """,
            to: "Modules/Ghost/Ghost.yml",
            in: root
        )
        try TestSources.commitAll(in: root, message: "add sources")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("build files that named a module: 0 SwiftPM manifest(s), 0 XcodeGen spec(s), 0 .xcodeproj"))
        // The CI workflow is not a spec, so it is not a near miss; the spec that resolves nothing is.
        #expect(status.contains("1 spec(s) whose targets declare no source path found on disk"))
    }

    /// A repository that resolves cleanly does not carry the line, because a survey nobody needs is noise on every status.
    @Test
    func aResolvedRepositoryGetsNoSurveyLine() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.2\n", to: "Package.swift", in: root)
        try TestSources.write(Self.cleanSource, to: "Sources/App/Clean.swift", in: root)
        try TestSources.commitAll(in: root, message: "add sources")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let status = try engine.statusText(freshness: freshness)

        #expect(!status.contains("build files that named a module"))
    }

    /// A repository with a few loose files outside any manifest gets no survey line, on the same proportional rule every other module-health surface uses.
    ///
    /// Gating it on a single guessed file would print a total-failure-shaped line on a healthy repo's every `status`, which is what `aHandfulOfLooseFilesIsNotWorthAWarning` exists to prevent one surface over.
    @Test
    func aHandfulOfLooseFilesGetsNoSurveyLine() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.2\n", to: "Package.swift", in: root)
        for index in 0 ..< 20 {
            try TestSources.write("struct Clean\(index) {}\n", to: "Sources/App/Clean\(index).swift", in: root)
        }
        try TestSources.write("struct Loose {}\n", to: "Scripts/Loose.swift", in: root)
        try TestSources.commitAll(in: root, message: "add sources")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("have a guessed module"))
        #expect(!status.contains("build files that named a module"))
    }

    /// And a digest of such a file says so where the decision is made, not only in a command nobody runs.
    @Test
    func aDigestOfAGuessedModuleFileCarriesTheBanner() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.cleanSource, to: "Sources/App/Clean.swift", in: root)
        try TestSources.commitAll(in: root, message: "add sources")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let digest = try engine.digest(target: "Sources/App/Clean.swift", options: DigestOptions())

        #expect(digest.contains("⚠ module guessed"))
        #expect(digest.contains("sift init"))
    }
}
