//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the single build-file walk: what it finds, what it refuses to descend, and what it drops.
///
/// The depth bound, the size cap and the bundle rule each silently drop real build files, and a repo that symlinks a shared module tree can have none of its specs discovered while every other test stays green.
@Suite(.temporaryDirectories)
struct BuildFileScanTests {
    private static func makeTree() throws -> URL {
        try TemporaryDirectory.make("scan").appendingPathComponent("scan")
    }

    /// All three build systems come out of one traversal, which is the invariant the type exists for.
    @Test
    func oneWalkFindsAllThreeBuildSystems() throws {
        let root = try Self.makeTree()
        try TestSources.write("// swift-tools-version: 6.2\n", to: "Kit/Package.swift", in: root)
        try TestSources.write("name: App\ntargets: {}\n", to: "Apps/App.yml", in: root)
        try TestSources.write("// project\n", to: "Apps/App.xcodeproj/project.pbxproj", in: root)

        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())

        #expect(scan.packageManifests.map(\.lastPathComponent) == ["Package.swift"])
        #expect(scan.yamlCandidates.map(\.lastPathComponent) == ["App.yml"])
        #expect(scan.xcodeProjects.map(\.lastPathComponent) == ["App.xcodeproj"])
    }

    /// An `.xcodeproj` is a directory and must be collected as a leaf, never descended.
    ///
    /// Descending it enumerates `xcuserdata/` and `xcshareddata/` on every construction and spends the depth budget inside a bundle — and a `.yaml` shipped in a bundle's resources would be shape-tested as a build spec.
    @Test
    func aBundleIsCollectedAsALeafAndNeverEntered() throws {
        let root = try Self.makeTree()
        try TestSources.write("// project\n", to: "App.xcodeproj/project.pbxproj", in: root)
        try TestSources.write("targets: {}\n", to: "App.xcodeproj/xcshareddata/buried.yml", in: root)
        try TestSources.write("targets: {}\n", to: "Assets.xcassets/inside.yml", in: root)

        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())

        #expect(scan.xcodeProjects.count == 1)
        #expect(scan.yamlCandidates.isEmpty)
        #expect(!scan.directories.contains { $0.path.contains("xcshareddata") })
    }

    /// A symlinked directory is walked, because `.isDirectoryKey` is false for one and enumerating *through* a link returns nothing.
    ///
    /// The target sits outside the repository, which is the common shape (`Modules/Shared -> ../../shared-ios`): the walk reads the resolved path and reports the logical one, so the module keeps the repo-relative path everything else is keyed on.
    @Test
    func aSymlinkedTreeOutsideTheRepositoryIsFollowed() throws {
        let root = try Self.makeTree()
        let outside = try Self.makeTree()
        try TestSources.write("name: Shared\ntargets: {}\n", to: "Shared.yml", in: outside)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Modules"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Modules/Shared"), withDestinationURL: outside)

        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())

        #expect(scan.yamlCandidates.map(\.path).contains { $0.hasSuffix("Modules/Shared/Shared.yml") })
    }

    /// A symlink pointing back into the tree cannot make the walk loop or report the same directory twice.
    @Test
    func aSymlinkIntoTheTreeDoesNotLoop() throws {
        let root = try Self.makeTree()
        try TestSources.write("targets: {}\n", to: "Modules/Feature/Feature.yml", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Modules/Loop"),
            withDestinationURL: root.appendingPathComponent("Modules")
        )

        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())

        #expect(scan.yamlCandidates.count == 1)
    }

    /// A YAML file larger than the cap is a data file that happens to be YAML, and is never opened.
    @Test
    func aCandidateOverTheSizeCapIsDropped() throws {
        let root = try Self.makeTree()
        let padding = String(repeating: "# padding\n", count: (BuildFileScan.candidateByteCap / 10) + 16)
        try TestSources.write("targets: {}\n" + padding, to: "huge.yml", in: root)
        try TestSources.write("targets: {}\n", to: "small.yml", in: root)

        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())

        #expect(scan.yamlCandidates.map(\.lastPathComponent) == ["small.yml"])
    }

    /// `exclude` prunes the walk; `roots` deliberately does not, because a sibling build file declares sources inside a root.
    @Test
    func excludePrunesAndRootsDoNot() throws {
        let root = try Self.makeTree()
        try TestSources.write("targets: {}\n", to: "Vendor/Vendored.yml", in: root)
        try TestSources.write("targets: {}\n", to: "Apps/App.yml", in: root)
        var config = SiftConfig()
        config.exclude = ["Vendor"]
        config.roots = ["Modules"]

        let scan = BuildFileScan.run(repoRoot: root, config: config)

        #expect(scan.yamlCandidates.map(\.lastPathComponent) == ["App.yml"])
    }

    /// A worktree's build files must still be found when its root arrives the way `git rev-parse --show-toplevel` actually spells one under `/tmp` — through `/private` — and sits, as a linked worktree does, under a hidden `.claude/worktrees` directory of its own.
    ///
    /// Standardizing the root alone strips the `/private` back off while every entry keeps it (it is built by appending onto the *un*-standardized root), so the relative-path computation falls back to the absolute path — and `.claude` in that path then reads as a hidden component, hiding every build file in the worktree from itself.
    @Test
    func aWorktreeUnderPrivateTmpReadsItsOwnBuildFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sift-scan-\(UUID().uuidString)/.claude/worktrees/agent-1")
        try TestSources.write("name: App\ntargets: {}\n", to: "Apps/App.yml", in: root)
        try TestSources.write("// swift-tools-version: 6.2\n", to: "Package.swift", in: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())

        #expect(scan.yamlCandidates.map(\.lastPathComponent) == ["App.yml"])
        #expect(scan.packageManifests.map(\.lastPathComponent) == ["Package.swift"])
    }

    /// The bound is deep enough for the layout this exists to read, and a build file past it is genuinely not found.
    @Test
    func theDepthBoundReachesAMonorepoLayoutAndStopsSomewhere() throws {
        let root = try Self.makeTree()
        try TestSources.write("targets: {}\n", to: "apps/ios/Modules/Feature/Parcel/Parcel.yml", in: root)
        let tooDeep = (0 ... BuildFileScan.maximumDepth + 1).map { "d\($0)" }.joined(separator: "/")
        try TestSources.write("targets: {}\n", to: tooDeep + "/Buried.yml", in: root)

        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())

        #expect(scan.yamlCandidates.contains { $0.lastPathComponent == "Parcel.yml" })
        #expect(!scan.yamlCandidates.contains { $0.lastPathComponent == "Buried.yml" })
    }
}
