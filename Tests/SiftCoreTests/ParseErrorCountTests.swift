//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the counts a truncated parse leaves *low* — the half of Docs/Design.md § "Parse errors are surfaced, never hidden" that is about arithmetic rather than about a listing.
///
/// Split from ``ParseErrorAttributionTests`` because the two ask different questions of the same mechanism. That suite asks whether the files an answer drew on are named; this one asks whether a number the answer publishes admits it can only be low. The distinction is the reason there are two phrasings for it at all: a listing shows a line that is not there, and a number looks identical at every value.
@Suite(.temporaryDirectories)
struct ParseErrorCountTests {
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

    private static func digest(_ target: String, store: IndexStore, root: URL = URL(fileURLWithPath: "/tmp")) throws -> String {
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    /// The same recovery on the count banner, because the cap is the same cap and a reader holding a floor still has to be able to see what it was taken from.
    @Test
    func aTruncatedCountBannerNamesTheCommandThatListsTheRest() {
        let justFits = ParseErrorNotice(paths: (1 ... 8).map { "Sources/Alpha/Broken\($0).swift" })
        let overflows = ParseErrorNotice(paths: (1 ... 13).map { "Sources/Alpha/Broken\($0).swift" })

        #expect(justFits.countBanner?.contains("sift status") == false)
        #expect(overflows.countBanner?.contains("(+5 more)") == true)
        #expect(overflows.countBanner?.contains("`sift status` lists them all") == true)
        // Its absence-scoped twin shares the tail, so the cap must reach that one too.
        #expect(justFits.absenceCountBanner?.contains("sift status") == false)
        #expect(overflows.absenceCountBanner?.contains("`sift status` lists them all") == true)
    }

    /// One glyph over several sentences, so each has to be distinguishable from the rest on sight.
    ///
    /// This one differs by what it says the reader is *holding* rather than by where the files came from: the scoped and absence banners hand back a listing and a file to check it against, and a count hands back a number, which looks the same at every value. ``theTwoCountBannersAreToldApartByWhatTheyClaimTheListedFilesAre()`` covers the other axis — of the two that list files, which kind of list it is.
    @Test
    func theCountBannerIsToldApartFromTheOtherTwoOnSight() {
        let notice = ParseErrorNotice(paths: ["Sources/Alpha/Broken.swift"])

        #expect(notice.countBanner?.contains("the counts here are a floor") == true)
        #expect(notice.countBanner?.contains("elsewhere in this repo") == false)
        #expect(notice.countBanner?.contains("Not files this answer drew on") == false)
        #expect(notice.banner?.contains("a floor") == false)
        #expect(notice.absenceBanner?.contains("a floor") == false)
    }

    /// A repository overview is nothing but totals, and a truncated parse leaves a total low rather than absent.
    ///
    /// The absence wording does not fit it: that wording is for a claim a reader can check against a named file, and `8 files, 12 top-level declarations` gives them nothing to check. What a truncated parse costs it is asserted here alongside the banner — the fixture holds two top-level declarations and the overview counts one, with `parse_errors: 1` in the header saying only that the risk exists somewhere.
    @Test
    func theRepoOverviewSaysItsCountsAreAFloorWhenAFileDidNotParse() throws {
        let store = try TestSources.makeStore()
        let swallowing = try TestSources.parsed(Self.swallowingSource, path: "Sources/Alpha/Swallowing.swift")
        try store.replaceFiles([swallowing]) { _ in ("Alpha", false) }

        let overview = try Self.digest(".", store: store)

        #expect(overview.hasPrefix("⚠ parse errors"))
        #expect(overview.contains("the counts here are a floor"))
        #expect(overview.contains("Sources/Alpha/Swallowing.swift"))
        #expect(overview.contains("Alpha — 1 file, 1 top-level declaration"))
    }

    /// And a clean repository's overview carries none of it — an unconditional warning is the decorative counter one line lower.
    @Test
    func aCleanRepoOverviewCarriesNoBanner() throws {
        let store = try TestSources.makeStore()
        let clean = try TestSources.parsed(Self.cleanSource, path: "Sources/Alpha/Clean.swift")
        try store.replaceFiles([clean]) { _ in ("Alpha", false) }

        let overview = try Self.digest(".", store: store)

        #expect(!overview.contains("parse errors"))
    }

    /// A type digest's extension count is the one figure in it that no scoping can cover, so the answer says the number is a floor.
    ///
    /// `extensions(ofTypeNamed:)` reads the whole index, because an extension may be declared in any file. A file truncated before its extension was reached contributes no row — and so is not among the paths the answer cites either, which is what makes this a scoping hole rather than a wording one: the answer-scoped banner goes quiet about precisely the file that would have changed the number. The fixture is that exact case, and the assertions pin all three halves of it: the extension is genuinely lost, the scoped banner says nothing, and the note fires anyway.
    ///
    /// It fires on a count of zero because zero is the worst case, not the exempt one. With no extension found the header says nothing about extensions at all, so there is no figure on screen for a reader to distrust.
    @Test
    func aTypeDigestSaysItsExtensionCountIsAFloorWhenAnUncitedFileDidNotParse() throws {
        let store = try TestSources.makeStore()
        let cited = try TestSources.parsed(
            """
            struct Widget {
                let kept = 1
            }
            """,
            path: "Sources/Alpha/Widget.swift"
        )
        // The extension sits below an unclosed brace, so it never reaches the index — and its file never
        // reaches the cited paths, because nothing in it was readable to cite.
        let losing = try TestSources.parsed(
            """
            struct Filler {
                func alpha() {
                    if true {
            }

            extension Widget {
                func beta() {}
            }
            """,
            path: "Sources/Alpha/Losing.swift"
        )
        try store.replaceFiles([cited, losing]) { _ in ("Alpha", false) }

        let rendered = try Self.digest("Widget", store: store)

        #expect(!rendered.contains("extension Widget"), "the fixture must actually lose the extension")
        #expect(!rendered.contains("declarations may be missing from:"), "the scoped banner cannot see the file that changed the count")
        #expect(rendered.contains("⚠ this type's extension count is a floor"))
        #expect(rendered.contains("1 file in this repo did not fully parse"))
    }

    /// And a type digest in a repository the parser read end to end carries none of it — the exposure is real, but it is not unconditional on the repository being broken.
    @Test
    func aTypeDigestInACleanRepoCarriesNoExtensionCountNote() throws {
        let store = try TestSources.makeStore()
        let clean = try TestSources.parsed(Self.cleanSource, path: "Sources/Alpha/Clean.swift")
        try store.replaceFiles([clean]) { _ in ("Alpha", false) }

        let rendered = try Self.digest("Clean", store: store)

        #expect(!rendered.contains("parse errors"))
        #expect(!rendered.contains("extension count is a floor"))
    }

    /// The note counts the broken files instead of naming them, which is what lets it stand beside the scoped banner without restating that banner's paths inside a longer list.
    ///
    /// That restatement is the failure it is written against: a reader who meets a repo-wide list where they expected an answer-scoped one opens what they can see, finds nothing of theirs, and concludes the warning was not about their question.
    @Test
    func theExtensionCountNoteCountsTheBrokenFilesRatherThanListingThem() {
        let one = ParseErrorNotice(paths: ["Sources/Alpha/Broken.swift"])
        let many = ParseErrorNotice(paths: (1 ... 13).map { "Sources/Alpha/Broken\($0).swift" })

        #expect(one.floorNote(about: .typeExtensions)?.contains("1 file in this repo did not fully parse") == true)
        #expect(one.floorNote(about: .typeExtensions)?.contains("Sources/Alpha/Broken.swift") == false)
        #expect(many.floorNote(about: .typeExtensions)?.contains("13 files in this repo did not fully parse") == true)
        #expect(many.floorNote(about: .typeExtensions)?.contains("Sources/Alpha/Broken1.swift") == false)
        #expect(many.floorNote(about: .typeExtensions)?.contains("`sift status` names them") == true)
        #expect(ParseErrorNotice(paths: []).floorNote(about: .typeExtensions) == nil)
    }

    /// A file whose truncation hides a second declaration of `name`, and whose own first declaration survives.
    private static func losing(_ name: String) -> String {
        """
        struct Filler {
            func alpha() {
                if true {
        }

        struct \(name) {
            let hidden = 1
        }
        """
    }

    /// The ambiguity answer counts declarations out of a repo-wide query, so a candidate lost to a truncated file leaves the count low and the list short.
    ///
    /// A shorter list of candidates is invisible in the way every count here is: a reader looking at two has no way to know it should have said three. `typeDeclarations(named:)` reads the whole index, and the file that would have supplied the third contributed no row — so it is not among the paths cited either, which is the absence banner's reasoning applied to a number.
    ///
    /// This answer takes a *listing* banner rather than the counted note, because it carries no other banner to nest inside: nothing here reads a file's contents, only names and ranges already resolved. The paths are also the one thing a reader choosing between candidates can act on, since a broken file is where the candidate they meant may be hiding.
    ///
    /// Which listing banner is the second half of the property, and it is asserted. The paths here are *not* files the candidates came from — they are where the missing candidate would have been — so beside a list of candidates the counted-from wording reads as "and here is where these came from" and sends the reader to open files with nothing to do with the question. The absence label is what stops that, and it is the one `absenceBanner` already trained readers on.
    @Test
    func theAmbiguityAnswerSaysItsDeclarationCountIsAFloor() throws {
        let store = try TestSources.makeStore()
        let one = try TestSources.parsed("struct Dual {\n    let a = 1\n}", path: "Sources/Alpha/One.swift")
        let two = try TestSources.parsed("struct Dual {\n    let b = 2\n}", path: "Sources/Beta/Two.swift")
        let losing = try TestSources.parsed(Self.losing("Dual"), path: "Sources/Alpha/Losing.swift")
        try store.replaceFiles([one, two, losing]) { ($0.contains("/Beta/") ? "Beta" : "Alpha", false) }

        let rendered = try Self.digest("Dual", store: store)

        // Self-checking: were the third declaration not actually lost, this would read three.
        #expect(rendered.contains("Dual is ambiguous — 2 declarations"))
        #expect(rendered.hasPrefix("⚠ parse errors elsewhere in this repo"))
        #expect(rendered.contains("this count is a floor"))
        #expect(rendered.contains("Not files this answer drew on:"))
        #expect(rendered.contains("Sources/Alpha/Losing.swift"))
        #expect(!rendered.contains("Counted from these"), "these are not files the candidates were counted from")
    }

    /// The member-target ambiguity answer is the type one's twin — same repo-wide lookup, same shape — and it carries the same notice.
    ///
    /// `declarations(for:)` resolves through `symbols(named:)`, so a member lost with the tail of a truncated file is missing from the number and from the list under it alike, and the file that would have carried it is not among the paths this answer names because nothing in it was readable to name.
    @Test
    func theMemberAmbiguityAnswerSaysItsDeclarationCountIsAFloor() throws {
        let store = try TestSources.makeStore()
        let holder = try TestSources.parsed(
            """
            struct Holder {
                func pick(from: Int) {}
                func pick(under: Int) {}
            }
            """,
            path: "Sources/Alpha/Holder.swift"
        )
        let losing = try TestSources.parsed(Self.losing("Spare"), path: "Sources/Alpha/Losing.swift")
        try store.replaceFiles([holder, losing]) { _ in ("Alpha", false) }

        let rendered = try Self.digest("Holder.pick", store: store)

        #expect(rendered.contains("Holder.pick is ambiguous — 2 declarations"))
        #expect(rendered.hasPrefix("⚠ parse errors elsewhere in this repo"))
        #expect(rendered.contains("this count is a floor"))
        #expect(rendered.contains("Sources/Alpha/Losing.swift"))
    }

    /// The two listing banners are told apart by what they say the paths *are*, which is the whole of the choice between them.
    ///
    /// One says the count was read from these files, so open them to see what it covers; the other says the count is low because of them, and that the answer never read them. Read as the first, a repo-wide list beside a candidate list is an invitation to open files that have nothing to do with the question.
    @Test
    func theTwoCountBannersAreToldApartByWhatTheyClaimTheListedFilesAre() {
        let notice = ParseErrorNotice(paths: ["Sources/Alpha/Broken.swift"])

        #expect(notice.countBanner?.contains("Counted from these, which did not fully parse:") == true)
        #expect(notice.countBanner?.contains("elsewhere in this repo") == false)
        #expect(notice.absenceCountBanner?.contains("Not files this answer drew on:") == true)
        #expect(notice.absenceCountBanner?.hasPrefix("⚠ parse errors elsewhere in this repo") == true)
        #expect(notice.absenceCountBanner?.contains("Counted from these") == false)
    }

    /// `where`'s `declarations (N)` is the same count in the other front end, and it takes the counted note rather than the listing banner.
    ///
    /// `resolveDeclarations` goes through `symbols(named:)`, which reads the whole index — so a declaration lost with the tail of a truncated file is missing from the number *and* from the cited paths, and the answer-scoped banner falls silent about the only file that could explain it.
    ///
    /// Counted rather than listed because this answer usually does carry that banner, and a wider list printed beside it nests one inside the other. Asserted in situ: the broken path appears nowhere in the answer, which is what "counts them" means when the scoped banner has nothing to say.
    @Test
    func whereSaysItsDeclarationCountIsAFloorWhenAnUncitedFileDidNotParse() async throws {
        let store = try TestSources.makeStore()
        let clean = try TestSources.parsed("struct Target {\n    let a = 1\n}", path: "Sources/Alpha/A.swift")
        let losing = try TestSources.parsed(Self.losing("Target"), path: "Sources/Alpha/Losing.swift")
        try store.replaceFiles([clean, losing]) { _ in ("Alpha", false) }
        let renderer = WhereRenderer(store: store)

        let body = try await renderer.render(query: "Target", semantic: .inactive(note: "test run")).body

        #expect(body.contains("declarations (1):"))
        #expect(body.contains("⚠ the counts in this answer are floors"))
        #expect(body.contains("1 file in this repo did not fully parse"))
        #expect(!body.contains("declarations may be missing from:"), "no cited file is broken, so the scoped banner has nothing to say")
        #expect(!body.contains("Sources/Alpha/Losing.swift"), "the note counts the broken files rather than listing them")
    }

    /// `where` publishes three repo-wide counts, not one, and the note covers all three rather than leaving two of them unmarked beside it.
    ///
    /// `extensions of X (N)` reads `extensions(ofTypeNamed:)` and `conformers of X (N, …)` reads `conformers(of:)` — the same lookups, the same exposure. Leaving them out would be worse than a plain omission: a note worded for the declaration count alone, printed directly above them, tells a reader applying it literally that *these* counts are not floors. The same extension count carries a floor note in `digest X` and would carry none here, for one fact.
    @Test
    func theWhereNoteCoversItsExtensionAndConformerCountsToo() async throws {
        let store = try TestSources.makeStore()
        let declared = try TestSources.parsed("protocol Target {}\nstruct Adopter: Target {}", path: "Sources/Alpha/A.swift")
        let extended = try TestSources.parsed("extension Target {\n    func helper() {}\n}", path: "Sources/Alpha/A+Extras.swift")
        let losing = try TestSources.parsed(Self.losing("Spare"), path: "Sources/Alpha/Losing.swift")
        try store.replaceFiles([declared, extended, losing]) { _ in ("Alpha", false) }
        let renderer = WhereRenderer(store: store)

        let body = try await renderer.render(query: "Target", semantic: .inactive(note: "test run")).body

        #expect(body.contains("extensions of Target (1):"))
        #expect(body.contains("conformers of Target (1, by written name):"))
        #expect(body.contains("declarations, extensions and conformers each come from a repository-wide lookup"))
    }

    /// Where both fire, the scoped banner leads and the counted note follows — the specific question before the general one.
    ///
    /// They answer different things and a reader acts on them differently: *these files, which this answer read, are broken* is something to go and open, and *the count is a floor* is something to distrust. Ordering them the other way puts the caveat about files the answer never saw above the one about files it did.
    @Test
    func theScopedBannerLeadsTheCountedNoteWhenBothApply() async throws {
        let store = try TestSources.makeStore()
        let cited = try TestSources.parsed(Self.brokenSource, path: "Sources/Alpha/Broken.swift")
        let elsewhere = try TestSources.parsed(Self.losing("Unrelated"), path: "Sources/Alpha/Other.swift")
        try store.replaceFiles([cited, elsewhere]) { _ in ("Alpha", false) }
        let renderer = WhereRenderer(store: store)

        let body = try await renderer.render(query: "Broken", semantic: .inactive(note: "test run")).body
        let banner = try #require(body.range(of: "⚠ parse errors — declarations may be missing from:")).lowerBound
        let note = try #require(body.range(of: "⚠ the counts in this answer are floors")).lowerBound

        #expect(banner < note)
    }

    /// A module digest publishes a total too, and the same sentence covers it over a different scope.
    ///
    /// The arithmetic differs and the wording does not. An overview counts the repository, so every file the parser could not finish is one its numbers were counted from; a module digest counts one module, and naming a broken file in another is the decorative counter again. What the two share is the reader's position: they are holding a number, and a number has no line missing from it.
    @Test
    func aModuleDigestSaysItsCountIsAFloorAndNamesOnlyItsOwnBrokenFiles() throws {
        let store = try TestSources.makeStore()
        let mine = try TestSources.parsed(Self.swallowingSource, path: "Sources/Alpha/Swallowing.swift")
        let elsewhere = try TestSources.parsed(Self.brokenSource, path: "Sources/Beta/Broken.swift")
        try store.replaceFiles([mine, elsewhere]) { path in (path.contains("/Beta/") ? "Beta" : "Alpha", false) }

        let rendered = try Self.digest("Alpha", store: store)

        #expect(rendered.hasPrefix("⚠ parse errors"))
        #expect(rendered.contains("the counts here are a floor"))
        #expect(rendered.contains("Sources/Alpha/Swallowing.swift"))
        #expect(!rendered.contains("Sources/Beta/Broken.swift"))
        #expect(rendered.contains("module Alpha — 1 top-level declarations"))
    }
}
