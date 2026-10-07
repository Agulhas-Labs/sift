//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers root resolution: the enclosing repo, and the rootless query that resolves itself from the registry.
@Suite(.temporaryDirectories)
struct RootResolverTests {
    private static func makeRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TestSources.makeTempDirectory().appendingPathComponent("roots.json"))
    }

    /// An indexed repo declaring `type`, recorded in `registry`.
    @discardableResult
    private static func makeIndexedRepo(declaring type: String, in registry: RootsRegistry) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct \(type) { public let value: Int }", to: "Sources/Lib/\(type).swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root, registry: registry)
        try await engine.ensureFresh()
        return root
    }

    @Test
    func anEnclosingRepositoryAnswersWithoutConsultingTheRegistry() async throws {
        let registry = try Self.makeRegistry()
        let root = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)

        let resolved = try RootResolver.resolve(directory: root, registry: registry, probing: "Anything")

        #expect(resolved.url.standardizedFileURL == root.standardizedFileURL)
        // The ordinary case stays silent — a note on every answer would be noise.
        #expect(resolved.note == nil)
    }

    @Test
    func aRootlessQueryResolvesToTheOnlyIndexedRootDeclaringTheName() async throws {
        let registry = try Self.makeRegistry()
        let declaring = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        try await Self.makeIndexedRepo(declaring: "Unrelated", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        let resolved = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")

        #expect(resolved.url.standardizedFileURL == declaring.standardizedFileURL)
        let note = try #require(resolved.note)
        #expect(note.contains(declaring.path))
        #expect(note.contains("Depot"))
        #expect(note.contains("no repository encloses"))
    }

    @Test
    func aNameDeclaredInSeveralRootsIsReportedRatherThanGuessed() async throws {
        let registry = try Self.makeRegistry()
        let first = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let second = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        do {
            _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")
            Issue.record("an ambiguous name resolved to a single root")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("declared in 2 indexed repositories"))
            #expect(message.contains(first.path))
            #expect(message.contains(second.path))
        }
    }

    @Test
    func anAmbiguityListsOnlyTheRootsThatDeclareTheNameNotEveryRoot() async throws {
        let registry = try Self.makeRegistry()
        try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let irrelevant = try await Self.makeIndexedRepo(declaring: "Unrelated", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        do {
            _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")
            Issue.record("an ambiguous name resolved to a single root")
        } catch {
            // The whole point of resolving is to stop handing back a list of every root on the machine.
            #expect(!String(describing: error).contains(irrelevant.path))
        }
    }

    /// An indexed repo that only *extends* `type` — the declaration lives in some dependency no registry indexes.
    @discardableResult
    private static func makeIndexedRepo(extending type: String, in registry: RootsRegistry) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public extension \(type) { func polished() -> Bool { true } }", to: "Sources/Lib/\(type)+Extras.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await SiftEngine(directory: root, registry: registry).ensureFresh()
        return root
    }

    /// The type lives where it is declared: one declaring root beats any number of roots that merely extend the name, rather than reading as a false ambiguity.
    @Test
    func aDeclaringRootBeatsRootsThatMerelyExtendTheName() async throws {
        let registry = try Self.makeRegistry()
        let declaring = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        try await Self.makeIndexedRepo(extending: "Depot", in: registry)
        try await Self.makeIndexedRepo(extending: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        let resolved = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")

        #expect(resolved.url.standardizedFileURL == declaring.standardizedFileURL)
    }

    /// A dependency's type extended in exactly one indexed root resolves there — the only root with anything to say about it — and the note says "extending", not "declaring".
    @Test
    func anExtensionOnlyNameResolvesToTheExtendingRoot() async throws {
        let registry = try Self.makeRegistry()
        let extending = try await Self.makeIndexedRepo(extending: "Depot", in: registry)
        try await Self.makeIndexedRepo(declaring: "Unrelated", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        let resolved = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")

        #expect(resolved.url.standardizedFileURL == extending.standardizedFileURL)
        let note = try #require(resolved.note)
        #expect(note.contains("extending Depot"))
    }

    /// Several extension-only roots are a real tie, and the refusal must not claim they *declare* the name.
    @Test
    func extensionOnlyRootsAreReportedAsExtendingNotDeclaring() async throws {
        let registry = try Self.makeRegistry()
        try await Self.makeIndexedRepo(extending: "Depot", in: registry)
        try await Self.makeIndexedRepo(extending: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        do {
            _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")
            Issue.record("a tie between extension-only roots resolved to one of them")
        } catch {
            let message = String(describing: error)

            #expect(message.contains("Depot is extended in 2 indexed repositories"))
            #expect(!message.contains("declared in"))
        }
    }

    /// Four apps each declare a `Theme`, and the query comes from a *container* folder enclosing exactly one of the candidates — the directory names the subtree, so refusing would make the caller repeat what they had already said.
    @Test
    func aContainerDirectoryCollapsesAnAmbiguityToTheRootItEncloses() async throws {
        let registry = try Self.makeRegistry()
        let container = try TestSources.makeTempDirectory().resolvingSymlinksInPath()
        let enclosed = try TestSources.makeTempRepo(at: container.appendingPathComponent("app"))
        try TestSources.write("public struct Theme { public let value: Int }", to: "Sources/Lib/Theme.swift", in: enclosed)
        try TestSources.commitAll(in: enclosed, message: "seed")
        try await SiftEngine(directory: enclosed, registry: registry).ensureFresh()
        try await Self.makeIndexedRepo(declaring: "Theme", in: registry)

        let resolved = try RootResolver.resolve(directory: container, registry: registry, probing: "Theme")

        #expect(resolved.url.standardizedFileURL == enclosed.standardizedFileURL)
        let note = try #require(resolved.note)
        #expect(note.contains("under it"))
        #expect(note.contains(enclosed.path))
    }

    /// Two candidates under the same container are still a tie — but the refusal lists only those, not every declarer on the machine.
    @Test
    func aTieAmongEnclosedCandidatesListsOnlyThose() async throws {
        let registry = try Self.makeRegistry()
        let container = try TestSources.makeTempDirectory().resolvingSymlinksInPath()
        var inside: [URL] = []
        for name in ["app", "web"] {
            let repo = try TestSources.makeTempRepo(at: container.appendingPathComponent(name))
            try TestSources.write("public struct Theme { public let value: Int }", to: "Sources/Lib/Theme.swift", in: repo)
            try TestSources.commitAll(in: repo, message: "seed")
            try await SiftEngine(directory: repo, registry: registry).ensureFresh()
            inside.append(repo)
        }
        let outside = try await Self.makeIndexedRepo(declaring: "Theme", in: registry)

        do {
            _ = try RootResolver.resolve(directory: container, registry: registry, probing: "Theme")
            Issue.record("a tie among enclosed candidates resolved to one of them")
        } catch {
            let message = String(describing: error)

            #expect(message.contains("2 indexed repositories"))
            for repo in inside {
                #expect(message.contains(repo.path))
            }
            #expect(!message.contains(outside.path))
        }
    }

    /// Functions are stored labeled (`save(_:to:)`), so an exact-match probe can never heal a function target: `where` on a bare function name dead-ends on the teaching error while the name sits uniquely in one indexed root.
    @Test
    func aRootlessQueryResolvesOnAFunctionNameStoredLabeled() async throws {
        let registry = try Self.makeRegistry()
        let declaring = try TestSources.makeTempRepo()
        try TestSources.write(
            "public struct Service { public func fetchValue(for key: String, in scope: Int) -> Int { scope } }",
            to: "Sources/Lib/Service.swift",
            in: declaring
        )
        try TestSources.commitAll(in: declaring, message: "seed")
        try await SiftEngine(directory: declaring, registry: registry).ensureFresh()
        try await Self.makeIndexedRepo(declaring: "Unrelated", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        // Both the bare name and a labeled form must find the labeled row `fetchValue(for:in:)`.
        for target in ["fetchValue", "fetchValue(for:in:)"] {
            let resolved = try RootResolver.resolve(directory: portfolio, registry: registry, probing: target)
            #expect(resolved.url.standardizedFileURL == declaring.standardizedFileURL)
        }
    }

    @Test
    func aNameNoIndexedRootDeclaresKeepsTheTeachingError() async throws {
        let registry = try Self.makeRegistry()
        let indexed = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        do {
            _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Phantom")
            Issue.record("an unknown name resolved to a root")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("not inside a git repository"))
            #expect(message.contains(indexed.path))
        }
    }

    @Test
    func aTargetNoIndexCanBeAskedAboutCannotResolveAndSaysSo() async throws {
        let registry = try Self.makeRegistry()
        try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        // `.` names nothing at all, and a path no indexed root records is a miss like any other — a *partial*
        // path especially, since the probe matches the whole repo-relative path rather than a suffix.
        for target in [".", "Lib/Depot.swift", "Sources/Lib/Phantom.swift"] {
            do {
                _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: target)
                Issue.record("\(target) resolved to a root it could not have identified")
            } catch {
                #expect(String(describing: error).contains("not inside a git repository"))
            }
        }
    }

    /// A repo-relative file path resolves the same way a name does — the failure a name probe can never heal.
    ///
    /// `digest ProductKit/…/RecordService.swift` from a folder above the repositories must not dead-end on the registry listing while the file sits in an indexed root recording that exact path.
    @Test
    func aRootlessQueryResolvesToTheOnlyIndexedRootRecordingTheFilePath() async throws {
        let registry = try Self.makeRegistry()
        let recording = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        try await Self.makeIndexedRepo(declaring: "Unrelated", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        let resolved = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Sources/Lib/Depot.swift")

        #expect(resolved.url.standardizedFileURL == recording.standardizedFileURL)
        let note = try #require(resolved.note)
        #expect(note.contains(recording.path))
        // A repository contains a file; it does not declare one.
        #expect(note.contains("containing Sources/Lib/Depot.swift"))
    }

    /// One path in two repositories is the same refusal as one name in two — and says so in the verb that fits.
    @Test
    func aPathRecordedBySeveralRootsIsReportedRatherThanGuessed() async throws {
        let registry = try Self.makeRegistry()
        let first = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let second = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        do {
            _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Sources/Lib/Depot.swift")
            Issue.record("an ambiguous path resolved to a single root")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("Sources/Lib/Depot.swift is contained by 2 indexed repositories"))
            #expect(message.contains(first.path))
            #expect(message.contains(second.path))
        }
    }

    @Test
    func aQualifiedTargetResolvesOnEitherOfItsEnds() async throws {
        let registry = try Self.makeRegistry()
        let declaring = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        // `Type.member` carries the type first; `Module.Type` carries it last, and a module is not a symbol.
        let onFirst = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot.value")
        let onLast = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Lib.Depot")

        #expect(onFirst.url.standardizedFileURL == declaring.standardizedFileURL)
        #expect(onLast.url.standardizedFileURL == declaring.standardizedFileURL)
    }

    @Test
    func probeKeysReduceTargetsToNamesAnExactMatchCanFind() {
        #expect(RootResolver.probeKeys(from: "Depot") == ["Depot"])
        #expect(RootResolver.probeKeys(from: "Depot.value") == ["Depot", "value"])
        #expect(RootResolver.probeKeys(from: "Lib.Depot.value") == ["Lib", "value"])
        // A labeled form is stripped to its base name, which is what the symbols table stores it under.
        #expect(RootResolver.probeKeys(from: "Depot.save(_:to:)") == ["Depot", "save"])
        #expect(RootResolver.probeKeys(from: ".").isEmpty)
        #expect(RootResolver.probeKeys(from: "Sources/Lib/Depot.swift").isEmpty)
        #expect(RootResolver.probeKeys(from: "Depot.swift").isEmpty)
    }

    @Test
    func aPathTargetAsksTheFilesTableAndANameTargetTheSymbolsTable() {
        // The two shapes are never mixed: a path names no symbol, and a bare name is no file, so probing the
        // wrong table could only produce a miss (or, on a name like `Package`, a wrong root). For a name,
        // every declaring question outranks every extending one — the type lives where it is declared.
        #expect(RootResolver.probeEvidence(for: "Sources/Lib/Depot.swift") == [.containing("Sources/Lib/Depot.swift")])
        #expect(RootResolver.probeEvidence(for: "Depot.swift") == [.containing("Depot.swift")])
        #expect(RootResolver.probeEvidence(for: "Depot") == [.declaring("Depot"), .extending("Depot")])
        #expect(RootResolver.probeEvidence(for: "Depot.value") ==
            [.declaring("Depot"), .declaring("value"), .extending("Depot"), .extending("value")])
        #expect(RootResolver.probeEvidence(for: ".").isEmpty)
    }

    @Test
    func resolvingNeverIndexesTheRootItProbes() async throws {
        let registry = try Self.makeRegistry()
        try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let unindexed = try TestSources.makeTempRepo()
        registry.record(unindexed.path)
        let portfolio = try TestSources.makeTempDirectory()

        _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")

        // Same contract as the cross-root pointer: a probe is read-only, and must never build a cache in a
        // repository the query was not about.
        #expect(!FileManager.default.fileExists(atPath: unindexed.appendingPathComponent(".sift").path))
    }

    /// A repository and its own worktree are not an ambiguity.
    ///
    /// Both roots declare the same type because they are the same code, so the "pass root: with the one you mean" refusal asked a question with no useful answer. The checkout is the one that wins: a worktree under `.claude/worktrees/` is agent scratch that comes and goes, and the caller who typed no `root:` wanted the project.
    @Test
    func aWorktreeNeverCompetesWithTheRepositoryItBelongsTo() async throws {
        let registry = try Self.makeRegistry()
        let checkout = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let worktree = try TestSources.makeWorktree(of: checkout, named: "audit")
        let worktreeEngine = try SiftEngine(directory: worktree, registry: registry)
        try await worktreeEngine.ensureFresh()
        let portfolio = try TestSources.makeTempDirectory()

        // Both roots are registered and both indexes declare Depot.
        #expect(registry.knownRoots().contains(worktree.path))
        #expect(SiblingIndexProbe.declares(name: "Depot", atRoot: worktree.path))

        let resolved = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")

        #expect(resolved.url.standardizedFileURL == checkout.standardizedFileURL)
    }

    /// A container folder with one repository under it is not ambiguous, whatever the index has been asked.
    ///
    /// A container holding a single indexed repo in `app` is the case. Name evidence heals the calls that name a type and nothing else — `digest .` names nothing probeable, and a name the index has not recorded misses like any other — so without this the answer is a lecture about git while the only repository it could have meant sits one directory down.
    @Test
    func aContainerWithOneIndexedRepositoryAnswersWhateverTheProbeCouldNotIdentify() async throws {
        let registry = try Self.makeRegistry()
        let container = try TestSources.makeTempDirectory().resolvingSymlinksInPath()
        let enclosed = try TestSources.makeTempRepo(at: container.appendingPathComponent("app"))
        try TestSources.write("public struct Depot { public let value: Int }", to: "Sources/Lib/Depot.swift", in: enclosed)
        try TestSources.commitAll(in: enclosed, message: "seed")
        try await SiftEngine(directory: enclosed, registry: registry).ensureFresh()
        try await Self.makeIndexedRepo(declaring: "Unrelated", in: registry)

        // A target no index declares, a target no index can be asked about, and no target at all.
        for target in ["Phantom", ".", nil] {
            let resolved = try RootResolver.resolve(directory: container, registry: registry, probing: target)

            #expect(resolved.url.standardizedFileURL == enclosed.standardizedFileURL)
            let note = try #require(resolved.note)
            #expect(note.contains(enclosed.path))
            #expect(note.contains("the only indexed repository under it"))
            // Chosen for where it sits, so the note claims no evidence it does not have.
            #expect(!note.contains("declaring"))
        }
    }

    /// Evidence outranks proximity: the enclosed repository is the last resort, not the first guess.
    @Test
    func aNameDeclaredOutsideTheContainerStillWinsOverTheRepositoryInsideIt() async throws {
        let registry = try Self.makeRegistry()
        let container = try TestSources.makeTempDirectory().resolvingSymlinksInPath()
        let enclosed = try TestSources.makeTempRepo(at: container.appendingPathComponent("app"))
        try TestSources.write("public struct Local { public let value: Int }", to: "Sources/Lib/Local.swift", in: enclosed)
        try TestSources.commitAll(in: enclosed, message: "seed")
        try await SiftEngine(directory: enclosed, registry: registry).ensureFresh()
        let elsewhere = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)

        let resolved = try RootResolver.resolve(directory: container, registry: registry, probing: "Depot")

        #expect(resolved.url.standardizedFileURL == elsewhere.standardizedFileURL)
    }

    /// Two repositories under the container is a real question, and asking it is still right.
    @Test
    func aContainerWithSeveralIndexedRepositoriesStillHasToAsk() async throws {
        let registry = try Self.makeRegistry()
        let container = try TestSources.makeTempDirectory().resolvingSymlinksInPath()
        for name in ["app", "service"] {
            let repo = try TestSources.makeTempRepo(at: container.appendingPathComponent(name))
            try TestSources.write("public struct Local { public let value: Int }", to: "Sources/Lib/Local.swift", in: repo)
            try TestSources.commitAll(in: repo, message: "seed")
            try await SiftEngine(directory: repo, registry: registry).ensureFresh()
        }

        do {
            _ = try RootResolver.resolve(directory: container, registry: registry, probing: "Phantom")
            Issue.record("a container holding two repositories picked one of them")
        } catch {
            #expect(String(describing: error).contains("not inside a git repository"))
        }
    }

    /// Two worktrees of one repository under a container are one repository, so the sole-enclosed case still applies.
    @Test
    func aContainerHoldingOnlyWorktreesOfOneRepositoryIsNotAmbiguous() async throws {
        let registry = try Self.makeRegistry()
        let container = try TestSources.makeTempDirectory().resolvingSymlinksInPath()
        let checkout = try TestSources.makeTempRepo(at: container.appendingPathComponent("app"))
        try TestSources.write("public struct Local { public let value: Int }", to: "Sources/Lib/Local.swift", in: checkout)
        try TestSources.commitAll(in: checkout, message: "seed")
        try await SiftEngine(directory: checkout, registry: registry).ensureFresh()
        let worktree = try TestSources.makeWorktree(of: checkout, named: "audit")
        try await SiftEngine(directory: worktree, registry: registry).ensureFresh()

        let resolved = try RootResolver.resolve(directory: container, registry: registry, probing: "Phantom")

        #expect(resolved.url.standardizedFileURL == checkout.standardizedFileURL)
    }

    /// Two genuinely different repositories still have to ask — collapsing worktrees must not collapse projects.
    @Test
    func collapsingWorktreesLeavesRealAmbiguityIntact() async throws {
        let registry = try Self.makeRegistry()
        let first = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        _ = try TestSources.makeWorktree(of: first, named: "audit")
        let second = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        do {
            _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")
            Issue.record("two separate repositories resolved to one root")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("is declared in 2 indexed repositories"))
            #expect(message.contains(first.path))
            #expect(message.contains(second.path))
        }
    }

    /// The snapshot the audit's module-health section reads, against a real index rather than a hand-built row.
    @Test
    func aSnapshotReportsWhatTheIndexHoldsAndNothingWhereThereIsNoIndex() async throws {
        let registry = try Self.makeRegistry()
        let indexed = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let unindexed = try TestSources.makeTempRepo()

        let snapshot = try #require(ReadOnlyIndex.snapshot(atRoot: indexed.path))

        #expect(snapshot.files == 1)
        // A root with no index reads as nothing to say — never as a healthy zero, and never by building one.
        #expect(ReadOnlyIndex.snapshot(atRoot: unindexed.path) == nil)
        #expect(!FileManager.default.fileExists(atPath: unindexed.appendingPathComponent(".sift").path))
    }

    /// A repository is identified by the git directory it shares, not by its path.
    @Test
    func aWorktreeSharesItsRepositorysIdentityAndTheCheckoutIsPreferred() throws {
        let checkout = try TestSources.makeTempRepo()
        let worktree = try TestSources.makeWorktree(of: checkout, named: "audit")
        let unrelated = try TestSources.makeTempRepo()

        #expect(RepositoryIdentity.sameRepository(checkout.path, worktree.path))
        #expect(!RepositoryIdentity.sameRepository(checkout.path, unrelated.path))

        // Whichever order they arrive in, the checkout is the survivor.
        #expect(RepositoryIdentity.collapsingWorktrees(of: [checkout.path, worktree.path]) == [checkout.path])
        #expect(RepositoryIdentity.collapsingWorktrees(of: [worktree.path, checkout.path]) == [checkout.path])
        // A worktree alone still answers for its repository.
        #expect(RepositoryIdentity.collapsingWorktrees(of: [worktree.path]) == [worktree.path])
        #expect(RepositoryIdentity.collapsingWorktrees(of: [checkout.path, unrelated.path]).count == 2)
    }

    /// A bare repository's worktrees are one repository, and none of them is its checkout — because it has none.
    ///
    /// The identity is the shared git directory, which holds whatever shape the repository has; the preference for a checkout simply finds nothing to prefer and falls back to a stable choice, which is what keeps the answer the same whichever order the roots arrive in.
    @Test
    func worktreesOfABareRepositoryAreOneRepositoryWithNoCheckoutAmongThem() throws {
        let bare = try TestSources.makeBareRepo(named: "orchard")
        let alpha = try TestSources.makeWorktree(ofBare: bare, named: "alpha")
        let bravo = try TestSources.makeWorktree(ofBare: bare, named: "bravo")

        #expect(RepositoryIdentity.sameRepository(alpha.path, bravo.path))
        #expect(RepositoryIdentity.collapsingWorktrees(of: [alpha.path, bravo.path]) == [alpha.path])
        #expect(RepositoryIdentity.collapsingWorktrees(of: [bravo.path, alpha.path]) == [alpha.path])
    }

    /// A checkout whose git directory lives elsewhere is the repository's own tree, and beats the worktrees linked to it.
    ///
    /// Recognising the checkout by the git directory sitting *inside* it fails with `--separate-git-dir`, and the preference then falls through to whichever path is shortest — and the worktree here is sited to be exactly that.
    @Test
    func aCheckoutWhoseGitDirectoryLivesElsewhereIsStillPreferredOverItsWorktrees() throws {
        let repo = try TestSources.makeRepoWithSeparateGitDirectory(named: "orchard")
        let worktree = repo.checkout.deletingLastPathComponent().appendingPathComponent("wt")
        try TestSources.runGit(["worktree", "add", "-b", "wt", worktree.path], in: repo.checkout)

        // Sited to win the length fallback, so a checkout recognised by path alone would lose to it.
        #expect(worktree.path.count < repo.checkout.path.count)
        #expect(RepositoryIdentity.sameRepository(repo.checkout.path, worktree.path))
        #expect(RepositoryIdentity.collapsingWorktrees(of: [worktree.path, repo.checkout.path]) == [repo.checkout.path])
    }
}

/// The note an adopted answer carries names the repository that answered, and a finished answer is read back for it.
extension RootResolverTests {
    /// Every shape of the note gives back its repository; an answer with none gives back nothing.
    @Test(arguments: [
        ResolvedRoot.adopted(URL(fileURLWithPath: "/work/big"), matching: .declaring("Depot"), from: "/work", within: false),
        ResolvedRoot.adopted(URL(fileURLWithPath: "/work/big"), matching: .containing("Sources/App/Depot.swift"), from: "/work", within: true),
        ResolvedRoot.enclosedSole(URL(fileURLWithPath: "/work/big"), from: "/work"),
    ])
    func anAdoptedAnswerNamesTheRepositoryThatAnsweredIt(resolved: ResolvedRoot) throws {
        let note = try #require(resolved.note)
        let answer = "tree: big  head: 0000000  dirty: 0  parse_errors: 0\n\(note)\nSources/App/Depot.swift — module: App"

        #expect(ResolvedRoot.adoptedRoot(inAnswer: answer) == "/work/big")
        #expect(ResolvedRoot.adoptedRoot(inAnswer: "tree: big  head: 0000000  dirty: 0\nSources/App/Depot.swift — module: App") == nil)
    }
}

/// A line-range target, which names a file and some of its lines, resolves the way the file alone does.
extension RootResolverTests {
    /// The files table records paths, never lines, so the probe asks it about the path alone — in every form a range takes.
    @Test
    func aLineRangeTargetResolvesToTheRootRecordingItsFile() async throws {
        let registry = try Self.makeRegistry()
        let recording = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        try await Self.makeIndexedRepo(declaring: "Unrelated", in: registry)
        let portfolio = try TestSources.makeTempDirectory()

        for target in ["Sources/Lib/Depot.swift:1", "Sources/Lib/Depot.swift:1-40", "Sources/Lib/Depot.swift:1:5", "Sources/Lib/Depot.swift:1:5:"] {
            #expect(RootResolver.probeEvidence(for: target) == [.containing("Sources/Lib/Depot.swift")], "\(target)")
            let resolved = try RootResolver.resolve(directory: portfolio, registry: registry, probing: target)

            #expect(resolved.url.standardizedFileURL == recording.standardizedFileURL, "\(target)")
            #expect(resolved.note?.contains("containing Sources/Lib/Depot.swift") == true, "\(target)")
        }
    }
}
