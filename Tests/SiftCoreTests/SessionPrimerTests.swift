//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the session-start primer: which context a starting session resolves to, and what each one says.
@Suite(.temporaryDirectories)
struct SessionPrimerTests {
    @Test
    func aSessionInsideAnIndexedRootNeedsNoRootArgument() throws {
        let context = SessionPrimer.context(
            cwd: "/repos/App",
            knownRoots: ["/repos/App"],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .insideRoot("/repos/App"))
        let primer = try #require(SessionPrimer.render(context))
        #expect(primer.contains("no `root:` argument"))
    }

    @Test
    func aSubdirectoryOfAnIndexedRootIsStillInsideIt() {
        let context = SessionPrimer.context(
            cwd: "/repos/App/Sources/Feature",
            knownRoots: ["/repos/App"],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .insideRoot("/repos/App"))
    }

    /// The common case: a session started from a directory above every repo.
    @Test
    func aSessionAboveTheReposListsThemAndRecommendsARoot() throws {
        // A rootless query does not "fail to resolve": `digest` and `where` resolve the name against the
        // indexed roots.
        // Passing `root:` is still the better call — one lookup instead of a probe per root, and never
        // ambiguous — so the primer recommends it rather than demanding it.
        let context = SessionPrimer.context(
            cwd: "/repos",
            knownRoots: ["/repos/Beta", "/repos/App"],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .aboveRoots(["/repos/App", "/repos/Beta"]))
        let primer = try #require(SessionPrimer.render(context))
        #expect(primer.contains("pass `root:` with the repo you mean"))
        #expect(!primer.contains("cannot resolve"))
        #expect(primer.contains("/repos/App"))
        #expect(primer.contains("/repos/Beta"))
    }

    /// A root nested inside another must resolve to the inner one, or every query goes to the wrong index.
    @Test
    func theDeepestContainingRootWins() {
        let context = SessionPrimer.context(
            cwd: "/repos/App/Packages/Kit/Sources",
            knownRoots: ["/repos/App", "/repos/App/Packages/Kit"],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .insideRoot("/repos/App/Packages/Kit"))
    }

    /// Prefix matching must respect path boundaries: `/repos/App` does not contain `/repos/AppExtras`.
    @Test
    func aSiblingSharingANamePrefixIsNotContainment() {
        let context = SessionPrimer.context(
            cwd: "/repos/AppExtras",
            knownRoots: ["/repos/App"],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .none)
    }

    @Test
    func aTrailingSlashDoesNotDefeatContainment() {
        let context = SessionPrimer.context(
            cwd: "/repos/App/",
            knownRoots: ["/repos/App"],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .insideRoot("/repos/App"))
    }

    @Test
    func anUnindexedSwiftRepositoryIsToldTheFirstQueryIndexesIt() throws {
        let context = SessionPrimer.context(
            cwd: "/elsewhere/Fresh",
            knownRoots: ["/repos/App"],
            repositoryRoot: "/elsewhere/Fresh",
            containsSwiftSources: true
        )

        #expect(context == .unregisteredSwiftRepository("/elsewhere/Fresh"))
        let primer = try #require(SessionPrimer.render(context))
        #expect(primer.contains("has not indexed yet"))
        #expect(primer.contains("no setup step"))
    }

    /// `~/Documents` is no repository, but a Vapor project buried three levels down can make it look like one — and the primer would then offer indexing the whole directory.
    @Test
    func aSwiftProjectBuriedUnderANonRepositoryDirectoryIsNotARepository() {
        let context = SessionPrimer.context(
            cwd: "/Users/someone/Documents",
            knownRoots: [],
            repositoryRoot: nil,
            containsSwiftSources: true
        )

        #expect(context == .none)
    }

    /// Started in a subdirectory of an unindexed repo, the primer must name the repo, not the subdirectory.
    @Test
    func anUnindexedRepositoryIsNamedByItsRootNotTheWorkingDirectory() {
        let context = SessionPrimer.context(
            cwd: "/repos/Fresh/Sources/App",
            knownRoots: [],
            repositoryRoot: "/repos/Fresh",
            containsSwiftSources: true
        )

        #expect(context == .unregisteredSwiftRepository("/repos/Fresh"))
    }

    @Test
    func enclosingRepositoryWalksUpAndStopsOutsideOne() throws {
        let repository = try TestSources.makeTempRepo()
        let nested = repository.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let found = try #require(SessionPrimer.enclosingRepository(of: nested.path))
        #expect(URL(fileURLWithPath: found).standardizedFileURL.path == repository.standardizedFileURL.path)

        let bare = try TestSources.makeTempDirectory()
        #expect(SessionPrimer.enclosingRepository(of: bare.path) == nil)
    }

    /// The cost property the path-scoping protects: a non-Swift session must pay nothing.
    @Test
    func aSessionWithNoSwiftInViewGetsNothing() {
        let context = SessionPrimer.context(
            cwd: "/documents/notes",
            knownRoots: ["/repos/App"],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .none)
        #expect(SessionPrimer.render(context) == nil)
    }

    /// The probe is the only branch that touches the filesystem, so it must not be reached when the answer is already known.
    @Test
    func theFilesystemProbeIsNotRunWhenARootAlreadyMatches() {
        var probed = false
        _ = SessionPrimer.context(
            cwd: "/repos/App",
            knownRoots: ["/repos/App"],
            repositoryRoot: "/repos/App",
            containsSwiftSources: { probed = true
                return true
            }()
        )

        #expect(probed == false)
    }

    @Test
    func everyPrimerCarriesTheNoToolsFallback() throws {
        for context in [
            SessionContext.insideRoot("/repos/App"),
            .aboveRoots(["/repos/App"]),
            .unregisteredSwiftRepository("/repos/App"),
        ] {
            for audience in [SessionPrimer.Audience.session, .subagent] {
                let primer = try #require(SessionPrimer.render(context, audience: audience))
                // The CLI first, since the binary that printed this is on the machine; Read/Grep only past that.
                #expect(primer.contains("the CLI answers the same queries from Bash (`sift digest …`"))
                // The no-Bash clause is for a subagent, whose tool set can be narrower than a session's.
                #expect(primer.contains("use Read/Grep as normal") == (audience == .subagent))
                #expect(primer.contains("before"), "the primer's whole purpose is pre-empting the first raw read")
            }
        }
    }

    /// The subagent's miss has a shape of its own: exploration sweeps a set of files rather than opening one.
    ///
    /// It also cannot be told to wait for the rule, because the rule never reaches it.
    @Test
    func theSubagentPrimerNamesTheSweepAndDoesNotDeferToTheRule() throws {
        let subagent = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .subagent))
        let session = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .session))

        #expect(subagent.contains("several types at once"))
        #expect(!subagent.contains("loads as a rule"))
        #expect(!session.contains("loads as a rule"))
        #expect(!session.contains("several types at once"))
        // Both still carry the decision rule itself — the audience changes the closing, not the substance.
        #expect(subagent.contains("This repo is indexed"))
    }

    /// A subagent spawned outside Swift work pays nothing either, the same silence the session hook keeps.
    @Test
    func aSubagentWithNoSwiftInViewGetsNothing() {
        #expect(SessionPrimer.render(.none, audience: .subagent) == nil)
    }

    /// A server proven not to be running is the first thing said, with the route that still works — and it is never said where the primer says nothing, since with no Swift in view the missing server does not matter.
    @Test
    func aServerProvenNotRunningLeadsThePrimerAndNeverSpeaksAlone() throws {
        let told = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .subagent, serverAbsent: true))

        #expect(told.hasPrefix("**This session's sift MCP server is not running"))
        #expect(told.contains("`sift strings …`"))
        #expect(told.contains("This repo is indexed"))
        #expect(SessionPrimer.render(.none, audience: .subagent, serverAbsent: true) == nil)
        #expect(SessionPrimer.render(.insideRoot("/repos/App"), audience: .subagent)?.contains("is not running") == false)
    }

    /// A repository whose modules are mostly guesswork says so before the first query, not after it.
    ///
    /// The per-answer banner cannot do this job: it arrives *with* an answer, so the first conclusion drawn from a wrong module name is already drawn by the time it is read.
    @Test
    func aMostlyGuessedRepositoryIsFlaggedAtSessionStart() throws {
        let primer = try #require(SessionPrimer.render(
            .insideRoot("/repos/App"),
            moduleHealth: SessionPrimer.ModuleHealth(guessed: 151, files: 151)
        ))

        #expect(primer.contains("mostly guesswork"))
        #expect(primer.contains("100%"))
        #expect(primer.contains("151 of 151"))
        // The whole point: the reader of this text cannot run it, so it has to be handed on.
        #expect(primer.contains("Say so at the start of your reply"))
        #expect(primer.contains("sift init"))
    }

    /// The primer states the risk and the remedy in ``GuessedModuleNotice``'s words, because it is one of four surfaces that say this and the only one that opens a session.
    ///
    /// Restating them by hand is how one surface keeps an old remedy after the banner, the audit and the agent guide have all been reworded to say the opposite. Asserting the shared strings rather than a copy of their current text is the point: reword the notice and this follows, or fails.
    @Test
    func theGuessedModuleWarningSharesTheNoticesWording() throws {
        let primer = try #require(SessionPrimer.render(
            .insideRoot("/repos/App"),
            moduleHealth: SessionPrimer.ModuleHealth(guessed: 120, files: 120)
        ))

        #expect(primer.contains(GuessedModuleNotice.consequence))
        #expect(primer.contains(GuessedModuleNotice.remedy))
    }

    /// An upgrade re-attributes an existing index on its own, so the primer must not send anyone to `init` before mentioning that.
    ///
    /// The reverse order is what makes the advice expensive: `init` is per-repository and nobody runs it across ten checkouts, while the three build systems below cover almost every repository that would trigger this warning.
    @Test
    func theGuessedModuleWarningNamesWhatResolvesAutomatically() throws {
        let primer = try #require(SessionPrimer.render(
            .insideRoot("/repos/App"),
            moduleHealth: SessionPrimer.ModuleHealth(guessed: 120, files: 120)
        ))

        let automatic = try #require(primer.range(of: "re-attributes")).lowerBound
        let initMention = try #require(primer.range(of: "sift init")).lowerBound

        #expect(primer.contains("SwiftPM"))
        #expect(primer.contains("XcodeGen"))
        #expect(primer.contains(".xcodeproj"))
        // The ordering *is* the guidance: reaching for a per-repository command before checking the binary is
        // current is the expensive half, and asserting mere presence would let the whole clause be deleted.
        #expect(automatic < initMention)
        // The claim that would make this a setup step rather than an unread build system.
        #expect(!primer.contains("nothing improves until someone runs it"))
        // And it must still say a *human* has to act, which is the banner's whole point.
        #expect(primer.contains("tell the user"))
    }

    /// Every repository has a few loose files outside any manifest; warning about those trains the reader to skip the line that matters.
    @Test
    func aHandfulOfLooseFilesIsNotWorthAWarning() throws {
        let healthy = SessionPrimer.ModuleHealth(guessed: 3, files: 162)
        let tiny = SessionPrimer.ModuleHealth(guessed: 9, files: 9)

        #expect(!healthy.isMostlyGuessed)
        // Below the file floor the ratio is noise — a two-file scratch repo is not a monorepo in trouble.
        #expect(!tiny.isMostlyGuessed)
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), moduleHealth: healthy))
        #expect(!primer.contains("mostly guesswork"))
    }

    /// The primer leads with the reading habit, because that is where the misses actually are.
    ///
    /// Most of the Swift lookups that go around the index open a file rather than search for a name, so a primer leading with `where` before `digest` is advice about the smaller half. Order is the whole of the guidance — every bullet is present either way — so order is what this pins.
    @Test
    func theReadingHabitIsNamedBeforeTheSearchHabit() throws {
        for audience in [SessionPrimer.Audience.session, .subagent] {
            let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: audience))
            let search = try #require(primer.range(of: "`where <Symbol>`"))
            let read = try #require(primer.range(of: "`digest <Type>`"))

            #expect(read.lowerBound < search.lowerBound)
            #expect(primer.contains("grepping"))
        }
    }

    /// The primer states the reading habit as guidance, and quotes no measurement of anyone's use to back it.
    ///
    /// It ships in the binary and is injected into every session on every machine, so a figure measured on one person's work is that person's data in everybody's context.
    @Test
    func theReadingHabitIsStatedWithoutAMeasuredShare() throws {
        for audience in [SessionPrimer.Audience.session, .subagent] {
            let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: audience))
                .replacingOccurrences(of: "\n", with: " ")

            #expect(primer.contains("before reading or grepping"))
            #expect(!primer.contains("real use"))
            #expect(!primer.contains("63%"))
        }
    }

    /// The primer covers the other half of a session's context cost: the build logs it pays for on the way out.
    ///
    /// One line, and it has to name the receipt as well as the payoff — a compression nobody can audit is one nobody trusts. Both audiences get it, because a subagent handed a verify loop is exactly where a thousand-line `xcodebuild` log lands.
    @Test
    func thePrimerNamesTheRunWrapperForBuildsAndTests() throws {
        for audience in [SessionPrimer.Audience.session, .subagent] {
            let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: audience))
            #expect(primer.contains("sift run --"))
            #expect(primer.contains(".sift/runs/"))
        }
    }

    /// A location handed over by an issue, a review or a build error reads as already located, so the primer names the digest that takes it.
    ///
    /// Without this line a cited `File.swift:120` went to a guessed `sed` window, and the CLI in a Bash line already being made was read as a fallback only.
    @Test
    func thePrimerSendsACitedLocationToAnAnchoredDigest() throws {
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App")))
        let folded = primer.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(folded.contains("a cited line: `digest File.swift:120`"))
        #expect(folded.contains("the CLI answers the same queries from Bash"))
    }

    @Test
    func theProbeFindsSwiftSourcesAndIgnoresBuildDirectories() throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.write("struct A {}", to: "Sources/App/A.swift", in: root)
        #expect(SessionPrimer.containsSwiftSources(at: root.path))

        let buildOnly = try TestSources.makeTempDirectory()
        try TestSources.write("struct Generated {}", to: ".build/generated/G.swift", in: buildOnly)
        #expect(SessionPrimer.containsSwiftSources(at: buildOnly.path) == false)
    }

    @Test
    func theProbeReportsNothingForANonSwiftDirectory() throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.write("# notes", to: "README.md", in: root)

        #expect(SessionPrimer.containsSwiftSources(at: root.path) == false)
    }
}
