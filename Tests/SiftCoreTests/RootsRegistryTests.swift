//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the roots registry and the two answers it feeds: the not-a-repo teaching error and the cross-root pointer on a name miss.
@Suite(.temporaryDirectories)
struct RootsRegistryTests {
    private static func makeRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TestSources.makeTempDirectory().appendingPathComponent("roots.json"))
    }

    @Test
    func recordIsIdempotentAndKnownRootsPrunesVanishedPaths() throws {
        let registry = try Self.makeRegistry()
        let surviving = try TestSources.makeTempDirectory()
        let vanishing = try TestSources.makeTempDirectory()

        registry.record(surviving.path)
        registry.record(surviving.path)
        registry.record(vanishing.path)
        try FileManager.default.removeItem(at: vanishing)

        #expect(registry.knownRoots() == [surviving.path])
        // The prune persists: a second read must not resurrect the vanished path.
        #expect(registry.knownRoots() == [surviving.path])
    }

    /// A repository built under the temp directory is scratch work by construction, and remembering it costs a probe on every rootless query for as long as the directory survives.
    @Test
    func aRootUnderAnEphemeralPrefixIsNeverRecorded() throws {
        // Real directories throughout, because `knownRoots` also prunes paths that do not exist —
        // asserting the boundary against invented paths would pass on the wrong reason.
        let base = try TestSources.makeTempDirectory()
        let scratch = base.appendingPathComponent("scratch")
        let scratchRepo = scratch.appendingPathComponent("bigproj")
        let lookalike = base.appendingPathComponent("scratchpad").appendingPathComponent("repo")
        for directory in [scratchRepo, lookalike] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let registry = RootsRegistry(
            fileURL: base.appendingPathComponent("roots.json"),
            ephemeralPrefixes: [scratch.path]
        )

        registry.record(scratchRepo.path)
        // A component boundary, not a string prefix: `scratchpad` is an ordinary directory.
        registry.record(lookalike.path)

        #expect(registry.knownRoots() == [lookalike.path])
    }

    /// The registry heals on read rather than only on write, so a machine already poisoned by a session that built fixtures under `/tmp` recovers the first time it is consulted.
    ///
    /// Self-testing can leave most of a machine's roots pointing at throwaway repos, and `digest Widget` from a folder above them then answers about one of them — with a freshness header, which is the shape of wrong answer that gets believed.
    @Test
    func anAlreadyRecordedEphemeralRootIsDroppedOnRead() throws {
        // The poisoned entry has to be a directory that *exists*, or `knownRoots`'s pre-existing
        // vanished-path prune drops it whatever this policy does and the test passes on the
        // wrong reason.
        let base = try TestSources.makeTempDirectory()
        let scratchRepo = base.appendingPathComponent("scratch").appendingPathComponent("bigproj")
        let durable = try TestSources.makeTempDirectory()
        try FileManager.default.createDirectory(at: scratchRepo, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("roots.json")
        let policyFree = RootsRegistry(fileURL: file)
        policyFree.record(scratchRepo.path)
        policyFree.record(durable.path)
        #expect(policyFree.knownRoots().count == 2)

        let registry = RootsRegistry(
            fileURL: file,
            ephemeralPrefixes: [base.appendingPathComponent("scratch").path]
        )

        #expect(registry.knownRoots() == [durable.path])
        // And the prune persists, so the cost is paid once rather than on every query.
        #expect(policyFree.knownRoots() == [durable.path])
    }

    /// The temp directory this process is actually given has to be covered, not just `/tmp` — they are different places on macOS, and a list that named only one would leave the other collecting fixtures.
    @Test
    func theSystemPrefixesCoverBothSpellingsOfTheTempDirectory() throws {
        let prefixes = RootsRegistry.systemEphemeralPrefixes
        let file = try TestSources.makeTempDirectory().appendingPathComponent("roots.json")
        let registry = RootsRegistry(fileURL: file, ephemeralPrefixes: prefixes)
        // `makeTempDirectory` builds under the directory this process is actually given, which is
        // the `/var/folders/…` spelling on macOS and `/tmp` on Linux — the entry that exists is the
        // one worth asserting on, rather than a path invented to match a prefix.
        let processTemp = try TestSources.makeTempDirectory()

        registry.record(processTemp.path)

        #expect(registry.knownRoots().isEmpty)
        #expect(prefixes.contains("/tmp"))
        #expect(prefixes.contains("/private/tmp"))
        // An empty or root-level prefix would mark every absolute path ephemeral and wipe the registry.
        #expect(!prefixes.contains(""))
        #expect(!prefixes.contains("/"))
    }

    @Test
    func corruptRegistryFileReadsAsEmpty() throws {
        let file = try TestSources.makeTempDirectory().appendingPathComponent("roots.json")
        try Data("not json at all".utf8).write(to: file)
        let registry = RootsRegistry(fileURL: file)

        #expect(registry.knownRoots().isEmpty)

        // And recording over the corpse heals it rather than failing.
        let root = try TestSources.makeTempDirectory()
        registry.record(root.path)
        #expect(registry.knownRoots() == [root.path])
    }

    @Test
    func rootlessQueryOutsideARepoTeachesTheKnownRoots() throws {
        let registry = try Self.makeRegistry()
        let indexed = try TestSources.makeTempRepo()
        registry.record(indexed.path)
        let nowhere = try TestSources.makeTempDirectory()

        do {
            _ = try SiftEngine(directory: nowhere, registry: registry)
            Issue.record("an engine opened outside any git repository")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("not inside a git repository"))
            #expect(message.contains("Pass root:"))
            #expect(message.contains(indexed.path))
        }
    }

    /// Two repos, one registry: a name missed in A but declared in B's existing index gets a pointer, not a dead end.
    ///
    /// The declaring repo carries a manifest and a nested type on purpose. The manifest names its module, so the probe's module arm has something real to cross; the nesting — including a member declared in an extension written by the nested type's full path — is what walks the probe's own parent chain more than one link, which a flat `Depot.lit` never does. The chain walk is hand-rolled against another root's database, so a reversed insert or an off-by-one there would kill every nested pointer and stay green on a flat fixture.
    private static func makeSiblings() async throws -> Siblings {
        let registry = try makeRegistry()
        let declaring = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Lib", targets: [.target(name: "Lib")])
            """,
            to: "Package.swift",
            in: declaring
        )
        try TestSources.write("public struct Depot { public let lit: Bool }", to: "Sources/Lib/Depot.swift", in: declaring)
        try TestSources.write(
            """
            public enum Torch {
                public struct Flame {
                    public let colour: String
                }
            }

            public extension Torch.Flame {
                var isWarm: Bool { true }
            }
            """,
            to: "Sources/Lib/Torch.swift",
            in: declaring
        )
        try TestSources.commitAll(in: declaring, message: "depot")
        let declaringEngine = try SiftEngine(directory: declaring, registry: registry)
        try await declaringEngine.ensureFresh()

        let planless = try TestSources.makeTempRepo()
        try TestSources.write("struct Local {}", to: "Sources/App/Local.swift", in: planless)
        try TestSources.commitAll(in: planless, message: "local")
        let engine = try SiftEngine(directory: planless, registry: registry)
        try await engine.ensureFresh()
        return Siblings(planless: engine, declaringRoot: declaring, registry: registry)
    }

    @Test
    func digestMissPointsAtTheSiblingRootDeclaringTheName() async throws {
        let siblings = try await Self.makeSiblings()

        let output = try siblings.planless.digest(target: "Depot", options: DigestOptions())

        #expect(output.contains("Depot is declared in \(siblings.declaringRoot.path)"))
        #expect(output.contains("retry with root=\(siblings.declaringRoot.path)"))
        #expect(output.contains("per that root's last index"))
    }

    @Test
    func whereMissPointsAtTheSiblingRootDeclaringTheName() async throws {
        let siblings = try await Self.makeSiblings()
        let freshness = try await siblings.planless.ensureFresh()

        let output = try await siblings.planless.lookup(symbol: "Depot", freshness: freshness, options: WhereOptions(includeSemantic: false))

        #expect(output.contains("Depot is declared in \(siblings.declaringRoot.path)"))
        #expect(output.contains("retry with root=\(siblings.declaringRoot.path)"))
    }

    /// A sibling that only *extends* the name still gets a pointer — but an honest one, since it holds members bolted onto a dependency's type, not the type itself.
    @Test
    func aSiblingThatOnlyExtendsTheNameIsPointedAtWithTheHonestVerb() async throws {
        let siblings = try await Self.makeSiblings()
        let extending = try TestSources.makeTempRepo()
        try TestSources.write("public extension Lantern { func brightness() -> Int { 11 } }", to: "Sources/Lib/Lantern+Extras.swift", in: extending)
        try TestSources.commitAll(in: extending, message: "lantern")
        try await SiftEngine(directory: extending, registry: siblings.registry).ensureFresh()

        let output = try siblings.planless.digest(target: "Lantern", options: DigestOptions())

        #expect(output.contains("Lantern is extended in \(extending.path)"))
        #expect(output.contains("retry with root=\(extending.path)"))
        #expect(!output.contains("Lantern is declared in"))
    }

    @Test
    func aRecordedButNeverIndexedRootIsSkippedAndNeverIndexedAsASideEffect() async throws {
        let siblings = try await Self.makeSiblings()
        let unindexed = try TestSources.makeTempRepo()
        siblings.registry.record(unindexed.path)

        let output = try siblings.planless.digest(target: "Phantom", options: DigestOptions())

        #expect(!output.contains(unindexed.path))
        // The probe must never create the sibling's cache: indexing what someone else's miss touched
        // would be a write to a repository the query was never about.
        #expect(!FileManager.default.fileExists(atPath: unindexed.appendingPathComponent(".sift").path))
    }

    /// A dotted target is checked as a path, because it is printed as one.
    ///
    /// Probing the last component and wording the answer with the whole target answers `Ghost.lit` with every repository that has anything called `lit` in it, under a line reading "Ghost.lit is declared in …". A pointer costs a repository opened, and a wrong one costs as many as it lists — which is why a line here is worse than no line.
    @Test
    func aDottedTargetIsNotPointedAtARootThatMerelyDeclaresItsLastComponent() async throws {
        let siblings = try await Self.makeSiblings()

        let output = try siblings.planless.digest(target: "Ghost.lit", options: DigestOptions())

        // The declaring root has a `lit` — as a member of `Depot`, which has nothing to do with `Ghost`.
        #expect(!output.contains(siblings.declaringRoot.path))
        #expect(!output.contains("Ghost.lit is declared in"))
    }

    /// The other half of the same rule: a path the sibling's index really does resolve still gets its pointer.
    @Test
    func aDottedTargetTheSiblingActuallyDeclaresIsStillPointedAt() async throws {
        let siblings = try await Self.makeSiblings()
        let freshness = try await siblings.planless.ensureFresh()

        let output = try await siblings.planless.lookup(symbol: "Depot.lit", freshness: freshness, options: WhereOptions(includeSemantic: false))

        #expect(output.contains("Depot.lit is declared in \(siblings.declaringRoot.path)"))
        #expect(output.contains("retry with root=\(siblings.declaringRoot.path)"))
    }

    /// The probe walks a real chain across roots, in the right direction, and crosses the module arm.
    ///
    /// Each of these needs one more link than `Depot.lit`: a member two deep, the same member reached through the module, one addressed by its immediate container alone, and one declared in an extension written by the nested type's full path — the shape that flattening exists for. The negative is the direction check: `colour` sits under `Torch.Flame`, not under `Torch`, and a chain assembled backwards would answer it.
    ///
    /// What each assertion actually covers, since the fixture is not uniform: reversing the walk's `insert(at: 0)` reddens the first three positives and the negative, but **not** `throughExtension` — an extension sits at file scope, so `isWarm`'s chain is the single element `["Torch.Flame"]` and reversing one element is a no-op. That case pins a different property, and the mutation that reddens it is stopping `QualifiedPath.flattened` from splitting a dotted extension name.
    @Test
    func theCrossRootProbeResolvesANestedPathAndNotAWrongOne() async throws {
        let siblings = try await Self.makeSiblings()

        let nested = try siblings.planless.digest(target: "Torch.Flame.colour", options: DigestOptions())
        let moduleQualified = try siblings.planless.digest(target: "Lib.Torch.Flame.colour", options: DigestOptions())
        let byContainer = try siblings.planless.digest(target: "Flame.colour", options: DigestOptions())
        let throughExtension = try siblings.planless.digest(target: "Torch.Flame.isWarm", options: DigestOptions())
        let skippingALink = try siblings.planless.digest(target: "Torch.colour", options: DigestOptions())

        #expect(nested.contains("Torch.Flame.colour is declared in \(siblings.declaringRoot.path)"))
        #expect(moduleQualified.contains("Lib.Torch.Flame.colour is declared in \(siblings.declaringRoot.path)"))
        #expect(byContainer.contains("Flame.colour is declared in \(siblings.declaringRoot.path)"))
        #expect(throughExtension.contains("Torch.Flame.isWarm is declared in \(siblings.declaringRoot.path)"))
        #expect(!skippingALink.contains(siblings.declaringRoot.path))
    }

    /// A label that exists in no repository at all is still part of the claim, so it is part of the check.
    @Test
    func aLabelTheSiblingDoesNotDeclareDrawsNoPointer() async throws {
        let siblings = try await Self.makeSiblings()

        let real = try siblings.planless.digest(target: "Depot.lit", options: DigestOptions())
        let invented = try siblings.planless.digest(target: "Depot.lit(nonsense:)", options: DigestOptions())

        #expect(real.contains("Depot.lit is declared in \(siblings.declaringRoot.path)"))
        #expect(!invented.contains(siblings.declaringRoot.path))
    }

    @Test
    func aLocalHitNeverCarriesACrossRootPointer() async throws {
        let siblings = try await Self.makeSiblings()

        let output = try siblings.planless.digest(target: "Local", options: DigestOptions())

        // The pointer is a miss answer only — a resolved local answer must stay uncluttered.
        #expect(!output.contains(siblings.declaringRoot.path))
    }
}

extension RootsRegistryTests {
    /// Two repos sharing one registry: the engine that will miss the name, the root that declares it, and the registry that lets the first find the second.
    private struct Siblings {
        let planless: SiftEngine
        let declaringRoot: URL
        let registry: RootsRegistry
    }
}
