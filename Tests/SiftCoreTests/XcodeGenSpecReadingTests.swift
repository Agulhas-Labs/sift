//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what a spec *means* once found: includes, templates, excludes, and the spellings XcodeGen accepts.
///
/// Split from `XcodeGenResolutionTests` at the type-body limit, which is also the honest shape of the work — "found it" and "read it correctly" fail independently, and every reading here is verified against xcodegen 2.46.0.
@Suite(.temporaryDirectories)
struct XcodeGenSpecReadingTests {
    /// A target the including document partially overrides keeps the `sources` it inherited, rather than being replaced wholesale.
    ///
    /// The shared-fragment-plus-override pattern, verified against xcodegen 2.46.0: overwriting the whole declaration would drop the inherited `sources` and map nothing.
    @Test
    func anOverriddenTargetKeepsItsInheritedSources() throws {
        let root = try TemporaryDirectory.make("override")
            .appendingPathComponent("override")
        try TestSources.write(
            """
            targets:
              Kit:
                type: framework
                sources: [Sources]
            """,
            to: ".xcodegen/base.yml",
            in: root
        )
        try TestSources.write(
            """
            include: [.xcodegen/base.yml]
            targets:
              Kit:
                settings:
                  SWIFT_VERSION: "6.0"
            """,
            to: "project.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Sources/A.swift") == "Kit")
    }

    /// A template that itself names a template contributes its sources, and a target's own `sources` add to the template's rather than replacing them.
    ///
    /// Both verified against xcodegen 2.46.0, which compiles every one of these directories into the target.
    @Test
    func templatesChainAndTheirSourcesConcatenate() throws {
        let root = try TemporaryDirectory.make("template-chain")
            .appendingPathComponent("template-chain")
        try TestSources.write(
            """
            name: Parcel
            targetTemplates:
              Base:
                type: framework
                sources: [Shared]
              Feature:
                templates: [Base]
            targets:
              ParcelKit:
                templates: [Feature]
                sources: [Own]
            """,
            to: "project.yml",
            in: root
        )
        try TestSources.write("struct S {}\n", to: "Shared/S.swift", in: root)
        try TestSources.write("struct O {}\n", to: "Own/O.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Shared/S.swift") == "ParcelKit")
        #expect(resolver.resolvedModule(for: "Own/O.swift") == "ParcelKit")
    }

    /// A path a target explicitly excludes is not claimed by it — the target says outright it does not compile the file.
    ///
    /// Claiming it anyway marks the file *resolved*, so it answers with the wrong module and carries no guessed banner: the confident wrong answer this area exists to prevent, and one that would reach every spec in the tree.
    @Test
    func anExcludedSubdirectoryIsNotClaimedByTheTargetThatExcludesIt() throws {
        let root = try TemporaryDirectory.make("excludes")
            .appendingPathComponent("excludes")
        try TestSources.write(
            """
            name: App
            targets:
              App:
                type: application
                sources:
                  - path: Sources
                    excludes: [Legacy]
            """,
            to: "project.yml",
            in: root
        )
        try TestSources.write("struct Kept {}\n", to: "Sources/Kept.swift", in: root)
        try TestSources.write("struct Old {}\n", to: "Sources/Legacy/Old.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Sources/Kept.swift") == "App")
        #expect(resolver.resolvedModule(for: "Sources/Legacy/Old.swift") == nil)
    }

    /// `sources` written as a bare mapping is a legal spelling and must resolve.
    @Test
    func aBareSourcesMappingResolves() throws {
        let root = try TemporaryDirectory.make("bare-mapping")
            .appendingPathComponent("bare-mapping")
        try TestSources.write(
            """
            name: App
            targets:
              App:
                type: application
                sources:
                  path: Sources
                  excludes: [Info.plist]
            """,
            to: "project.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Sources/A.swift") == "App")
    }

    /// A source path naming the repository root resolves nothing, so it must not count as a contribution.
    ///
    /// `resolvedModule` matches on `path == prefix` or `hasPrefix(prefix + "/")`, neither of which an empty prefix can satisfy — so storing it would produce a survey line reading healthy beside 100% guessed, the one outcome counting contributions rather than candidates exists to make impossible.
    @Test
    func aSpecCoveringTheWholeRepositoryIsNotCountedAsAContribution() throws {
        let root = try TemporaryDirectory.make("whole-repo")
            .appendingPathComponent("whole-repo")
        try TestSources.write(
            """
            name: Whole
            targets:
              Whole:
                type: application
                sources: [{path: .}]
            """,
            to: "project.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Sources/A.swift") == nil)
        #expect(resolver.survey.xcodeGenSpecs == 0)
        #expect(resolver.survey.specsWithoutResolvableSources == 1)
    }

    /// A spec that will not parse is named as one, not silently filed as "not a spec".
    @Test
    func aSpecThatWillNotParseIsReported() throws {
        let root = try TemporaryDirectory.make("unparsable")
            .appendingPathComponent("unparsable")
        try TestSources.write("targets:\n  Kit:\n\ttype: framework\n", to: "project.yml", in: root)
        try TestSources.write("struct A {}\n", to: "Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.survey.unparsableSpecs == 1)
        #expect(resolver.survey.line.contains("1 spec(s) that would not parse"))
    }

    /// A spec that resolves under its own directory must not fall back for a *stale* entry and claim a same-named top-level tree.
    ///
    /// A guard per *path* — accept the repo-relative reading only inside the spec's own subtree — rejects the main case the fallback exists for: a `--root`-generated spec naming a sibling tree (`Apps/project.yml` with `sources: Packages/Shared`). One spec is generated with one base, so the base is elected once per spec: its own directory wins unless nothing at all resolves under it. What that still guarantees, and what this pins, is the case where the spec demonstrably *is* spec-relative — a stale entry beside working ones cannot wander off and claim an unrelated tree.
    @Test
    func aStaleSourceEntryDoesNotClaimATopLevelTreeOfTheSameName() throws {
        let root = try TemporaryDirectory.make("stale-entry")
            .appendingPathComponent("stale-entry")
        try TestSources.write(
            """
            name: Alpha
            targets:
              AlphaKit:
                type: framework
                sources: Sources
              GhostKit:
                type: framework
                sources: Legacy
            """,
            to: "Modules/Alpha/Alpha.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Modules/Alpha/Sources/A.swift", in: root)
        // `Modules/Alpha/Legacy` does not exist. A top-level `Legacy` does, and belongs to nobody.
        try TestSources.write("struct Old {}\n", to: "Legacy/Old.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Modules/Alpha/Sources/A.swift") == "AlphaKit")
        #expect(resolver.resolvedModule(for: "Legacy/Old.swift") == nil)
    }

    /// A `--root`-generated spec naming a sibling tree resolves, which is the case a per-path containment guard breaks.
    @Test
    func aRootGeneratedSpecResolvesASiblingTree() throws {
        let root = try TemporaryDirectory.make("root-generated")
            .appendingPathComponent("root-generated")
        try TestSources.write(
            """
            name: App
            targets:
              Shell:
                type: application
                sources: [Apps/Shell]
              SharedKit:
                type: framework
                sources: [Packages/Shared]
            """,
            to: "Apps/project.yml",
            in: root
        )
        try TestSources.write("struct S {}\n", to: "Apps/Shell/S.swift", in: root)
        try TestSources.write("struct K {}\n", to: "Packages/Shared/K.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Apps/Shell/S.swift") == "Shell")
        #expect(resolver.resolvedModule(for: "Packages/Shared/K.swift") == "SharedKit")
    }

    /// Two targets sharing a source path resolve to the same module in every process, decided by name rather than by dictionary order.
    ///
    /// Swift seeds dictionary hashing per process, so last-wins iteration would make `Shared/*.swift` answer `App` in one run and `AppWidget` in the next, with a fingerprint identical across both because it hashes the spec's bytes. `XcodeProjectTargets.mappings` guards against the same thing.
    @Test
    func twoTargetsSharingSourcesResolveStably() throws {
        let root = try TemporaryDirectory.make("collision")
            .appendingPathComponent("collision")
        try TestSources.write(
            """
            name: App
            targets:
              App:
                type: application
                sources: [Shared, AppOnly]
              AppWidget:
                type: application
                sources: [Shared, WidgetOnly]
            """,
            to: "project.yml",
            in: root
        )
        try TestSources.write("struct S {}\n", to: "Shared/S.swift", in: root)
        try TestSources.write("struct A {}\n", to: "AppOnly/A.swift", in: root)
        try TestSources.write("struct W {}\n", to: "WidgetOnly/W.swift", in: root)

        let modules = (0 ..< 8).map { _ in
            ModuleResolver(repoRoot: root, config: SiftConfig()).resolvedModule(for: "Shared/S.swift")
        }

        #expect(Set(modules) == ["App"])
    }

    /// The fingerprint tracks what a spec *means* on disk, not its bytes, because the prefix depends on what exists.
    ///
    /// A spec declaring `sources: Sources` before that directory is generated resolves one way and another way after; the bytes never change, so a byte fingerprint would leave every stored row attributed to the wrong module with nothing short of `reset` to clear it.
    @Test
    func aSourcesDirectoryAppearingMovesTheFingerprint() throws {
        let root = try TemporaryDirectory.make("generated-sources")
            .appendingPathComponent("generated-sources")
        try TestSources.write(
            """
            name: Alpha
            targets:
              AlphaKit:
                type: framework
                sources: Sources
            """,
            to: "Modules/Alpha/Alpha.yml",
            in: root
        )
        let before = ModuleResolver(repoRoot: root, config: SiftConfig())

        try TestSources.write("struct A {}\n", to: "Modules/Alpha/Sources/A.swift", in: root)
        let after = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(after.fingerprint != before.fingerprint)
        #expect(after.resolvedModule(for: "Modules/Alpha/Sources/A.swift") == "AlphaKit")
    }

    /// A spec the config excludes names no modules, is not watched, and does not enter the fingerprint.
    ///
    /// Walking the filesystem directly for module resolution, while every other listing goes through git and the config, would let a vendored or generated spec rename modules for files the index does hold — and regenerating it would re-attribute the whole index.
    @Test
    func anExcludedSpecIsNotAResolutionInput() throws {
        let root = try TemporaryDirectory.make("excluded-spec")
            .appendingPathComponent("excluded-spec")
        try TestSources.write(
            """
            name: Vendored
            targets:
              VendoredKit:
                type: framework
                sources:
                  - path: Sources
            """,
            to: "Vendor/Vendored.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Vendor/Sources/A.swift", in: root)
        var config = SiftConfig()
        config.exclude = ["Vendor"]
        let resolver = ModuleResolver(repoRoot: root, config: config)

        #expect(resolver.resolvedModule(for: "Vendor/Sources/A.swift") == nil)
        #expect(resolver.inputPaths.isEmpty)
    }

    /// The survey counts what each build system contributed, and a near miss means a real spec that resolved nothing.
    ///
    /// Counting candidates instead would have a manifest with computed paths, an unreadable project and a spec resolving nothing all count as found, so the line beside "100% guessed" would read exactly like a healthy repository's — and every CI workflow would count as a near miss, which on a large checkout runs to thousands.
    @Test
    func theSurveyCountsContributionsAndRealNearMisses() throws {
        let root = try TemporaryDirectory.make("survey")
            .appendingPathComponent("survey")
        try TestSources.write("name: CI\non: [push]\njobs:\n  build:\n    runs-on: macos-latest\n", to: "ci.yml", in: root)
        // A real spec whose declared sources name nothing on disk — the actionable near miss.
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
        try TestSources.write("struct A {}\n", to: "Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.survey.xcodeGenSpecs == 0)
        // The workflow is simply not a spec, so it is not a near miss and is not counted.
        #expect(resolver.survey.specsWithoutResolvableSources == 1)
        #expect(resolver.survey.line.contains("0 XcodeGen spec(s)"))
        #expect(resolver.survey.line.contains("1 spec(s) whose targets declare no source path found on disk"))
    }

    /// A build file in a *sibling* tree is still found when `roots` is configured, because it routinely declares sources inside the root.
    ///
    /// Pruning the walk to the configured roots looks like free economy and is a regression — `Apps/App.yml` compiling `Modules/Feature` becomes invisible, where a walk that filters on nothing at all finds it. `exclude` still prunes, since that names what the user does not want read.
    @Test
    func aSiblingBuildFileIsFoundWhenRootsAreConfigured() throws {
        let root = try TemporaryDirectory.make("roots")
            .appendingPathComponent("roots")
        try TestSources.write(
            """
            name: Apps
            targets:
              FeatureKit:
                type: framework
                sources:
                  - path: Modules/Feature
            """,
            to: "Apps/Apps.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Modules/Feature/A.swift", in: root)
        var config = SiftConfig()
        config.roots = ["Modules"]
        let resolver = ModuleResolver(repoRoot: root, config: config)

        #expect(resolver.resolvedModule(for: "Modules/Feature/A.swift") == "FeatureKit")
    }

    /// A spec named after its product resolves, because XcodeGen's `project.yml` is a default and `--spec` takes any path.
    ///
    /// A monorepo may name each spec after the product it builds, so discovering `project.yml` anywhere still finds nothing there. A name carries no information, so the shape decides: a top-level `targets:` mapping with at least one target declaring `sources`.
    @Test
    func aSpecNamedAfterItsProductIsFound() throws {
        let root = try TemporaryDirectory.make("named-specs")
            .appendingPathComponent("named-specs")
        try TestSources.write(
            """
            name: Parcel
            targets:
              ParcelKit:
                type: framework
                sources:
                  - path: Sources
            """,
            to: "Parcel/Parcel.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Parcel/Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Parcel/Sources/A.swift") == "ParcelKit")
    }

    /// YAML that is not a build spec is ignored, and — just as important — never becomes a resolution input.
    ///
    /// A monorepo is full of YAML: CI workflows, lint configs, package metadata. Treating every one as a spec would map nonsense prefixes, and hashing every one into the fingerprint would re-attribute the whole index whenever a workflow was edited.
    @Test
    func yamlThatIsNotABuildSpecIsIgnored() throws {
        let root = try TemporaryDirectory.make("nonspec-yaml")
            .appendingPathComponent("nonspec-yaml")
        try TestSources.write(
            """
            name: CI
            on: [push]
            jobs:
              build:
                runs-on: macos-latest
            """,
            to: "ci/workflow.yml",
            in: root
        )
        // Shaped like a spec at a glance — it has `targets:` — but no target declares sources, so it maps nothing.
        try TestSources.write(
            """
            targets:
              - name: coverage
                threshold: 80
            """,
            to: "coverage.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Sources/A.swift") == nil)
        #expect(resolver.inputPaths.isEmpty)
    }
}
