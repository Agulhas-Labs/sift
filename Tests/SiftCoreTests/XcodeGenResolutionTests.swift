//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers XcodeGen resolution: where specs are found, how one is recognised, and what a source path means on disk.
///
/// Split out of `ModuleResolverTests` at the type-body limit: this one area — where a spec lives, what it is called, and sources arriving from a template or an include — has more cases than the rest of resolution put together.
@Suite(.temporaryDirectories)
struct XcodeGenResolutionTests {
    /// A repository laid out as one spec per feature, which is the shape a pair of hard-coded candidate paths can never see.
    ///
    /// Consulting XcodeGen only at fixed paths such as `project.yml` and `Apps/project.yml`, while SwiftPM manifests and `.xcodeproj` files are both discovered by walking, leaves a monorepo keeping a spec beside each feature resolving nothing at all and reporting every one of its files as a directory-name guess. Both `sources` spellings are covered because a monorepo will contain both.
    private static func makeNestedSpecTree() throws -> URL {
        let root = try TemporaryDirectory.make("nested-specs")
            .appendingPathComponent("nested-specs")
        try TestSources.write(
            """
            name: Alpha
            targets:
              AlphaKit:
                type: framework
                sources:
                  - path: Sources
            """,
            to: "Modules/Alpha/project.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Modules/Alpha/Sources/A.swift", in: root)
        try TestSources.write(
            """
            name: Beta
            targets:
              BetaFeature:
                type: framework
                sources: Sources
            """,
            to: "Features/Beta/project.yml",
            in: root
        )
        try TestSources.write("struct B {}\n", to: "Features/Beta/Sources/B.swift", in: root)
        try TestSources.write("struct C {}\n", to: "Apps/Shell/C.swift", in: root)
        return root
    }

    @Test
    func aSpecBesideEachFeatureIsDiscovered() throws {
        let root = try Self.makeNestedSpecTree()
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Modules/Alpha/Sources/A.swift") == "AlphaKit")
        #expect(resolver.resolvedModule(for: "Features/Beta/Sources/B.swift") == "BetaFeature")
        // No spec claims it, so the directory-name guess is still the honest answer.
        #expect(resolver.resolvedModule(for: "Apps/Shell/C.swift") == nil)
    }

    /// A nested spec's `sources` are resolved against the spec's own directory, and a repo-relative one still works.
    ///
    /// XcodeGen resolves a source path against the directory holding the spec, but `--root` moves that base, and a generate script that passes the repository root makes a top-level `Apps/project.yml` write `Apps/GizmoApp` while a stock nested spec writes `Sources`. Reading either as the other maps a prefix matching no file on disk, which looks exactly like a spec that declares nothing, so both readings are tried and the one that exists wins.
    @Test
    func aSourcePathIsReadAgainstTheSpecDirectoryOrTheRepoRoot() throws {
        let root = try Self.makeNestedSpecTree()
        try TestSources.write(
            """
            name: Legacy
            targets:
              LegacyApp:
                type: application
                sources:
                  - path: Modules/Legacy/Sources
            """,
            to: "Modules/Legacy/project.yml",
            in: root
        )
        try TestSources.write("struct D {}\n", to: "Modules/Legacy/Sources/D.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        // Spec-relative: `Sources` under `Modules/Alpha/` is `Modules/Alpha/Sources`, not a top-level `Sources`.
        #expect(resolver.resolvedModule(for: "Modules/Alpha/Sources/A.swift") == "AlphaKit")
        // A nested spec whose source path is written from the repo root — the repo-relative spelling some specs use, which must not become a double prefix.
        #expect(resolver.resolvedModule(for: "Modules/Legacy/Sources/D.swift") == "LegacyApp")
    }

    /// A discovered spec is a resolution input like any manifest, so its bytes move the fingerprint and its path is stamped.
    ///
    /// Without this the resolution would be right on a cold open and stale for the rest of the session: the fingerprint is what re-attributes an existing index, and `inputPaths` is what the engine watches for a mid-session edit.
    @Test
    func aDiscoveredSpecIsAWatchedResolutionInput() throws {
        let root = try Self.makeNestedSpecTree()
        let before = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(before.inputPaths.contains("Modules/Alpha/project.yml"))
        #expect(before.inputPaths.contains("Features/Beta/project.yml"))

        try TestSources.write(
            """
            name: Alpha
            targets:
              AlphaRenamed:
                type: framework
                sources:
                  - path: Sources
            """,
            to: "Modules/Alpha/project.yml",
            in: root
        )
        let after = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(after.fingerprint != before.fingerprint)
        #expect(after.resolvedModule(for: "Modules/Alpha/Sources/A.swift") == "AlphaRenamed")
    }

    /// A target whose `sources` come from a `targetTemplates` entry resolves, because that is where a monorepo keeps them.
    ///
    /// Requiring an inline `sources` would reject the whole document and report it as "not a spec" while it plainly is one — the same mistake as a fixed path or a fixed name, in a third form.
    @Test
    func aTargetInheritingSourcesFromATemplateResolves() throws {
        let root = try TemporaryDirectory.make("templated-spec")
            .appendingPathComponent("templated-spec")
        try TestSources.write(
            """
            name: Parcel
            targetTemplates:
              Feature:
                type: framework
                sources:
                  - path: Sources
            targets:
              ParcelKit:
                templates: [Feature]
            """,
            to: "Modules/Parcel/Parcel.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Modules/Parcel/Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Modules/Parcel/Sources/A.swift") == "ParcelKit")
    }

    /// Targets arriving from an `include:` resolve, and their sources are read against the directory of the file that declared them.
    ///
    /// The fragment lives in a hidden directory on purpose. Beside the spec, `BuildFileScan` would discover it as a spec in its own right and resolve it standalone — so deleting include-following entirely would leave the assertion true, and the test would pin nothing.
    @Test
    func targetsFromAnIncludedFragmentResolveAgainstTheirOwnDirectory() throws {
        let root = try TemporaryDirectory.make("included-spec")
            .appendingPathComponent("included-spec")
        try TestSources.write("include:\n  - ../../.xcodegen/targets.yml\n", to: "Modules/App/App.yml", in: root)
        try TestSources.write(
            """
            targets:
              SharedKit:
                type: framework
                sources:
                  - path: ../Modules/Shared/Sources
            """,
            to: ".xcodegen/targets.yml",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Modules/Shared/Sources/A.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Modules/Shared/Sources/A.swift") == "SharedKit")
        // The fragment decides module names, so it has to be watched like the spec that names it.
        #expect(resolver.inputPaths.contains(".xcodegen/targets.yml"))
    }
}
