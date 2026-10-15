//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The readers beside `where` judge each file against its own build: a file a partial build skipped is refused by `affected`, seeds its after-edit walk, marks `diff`'s wrapper sites, and is named by `status` as a case only a query shows.
@Suite(.serialized, .temporaryDirectories)
struct PartialBuildAffectedStatusTests {
    /// A declaration in a file edited before a build of another target alone is refused, which the store-wide anchor read as unchanged.
    @Test
    func affectedRefusesAFileAPartialBuildSkipped() async throws {
        let root = try await Self.partiallyRebuiltPackage()

        let output = try await Self.affected(root)

        #expect(output.contains("Sources/Beta/Beta.swift was changed since the last build"), "\(output)")
    }

    /// A skipped file committed after its own build and before the partial build is seeded whole, its commit measured against its own build rather than the store's newest unit.
    @Test
    func theAfterEditWalkSeedsASkippedFileCommittedSinceItsOwnBuild() async throws {
        let root = try await Self.partiallyRebuiltPackage(committingBeta: true)

        let output = try await Self.affected(root)

        #expect(output.contains("seeded whole: committed since the build: Sources/Beta/Beta.swift"), "\(output)")
    }

    /// An attribute written in the skipped file is listed by `where` as written since the build, and `diff` marks it so.
    @Test
    func wrapperSitesInASkippedFileAreJudgedAgainstTheirOwnBuild() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let lookup = try await engine.lookup(symbol: "Wrap.init(wrappedValue:)", freshness: freshness)
        let range = try DiffRange.resolve(nil, git: GitContext(repoRoot: root))
        let diff = try await engine.diff(options: DiffOptions(range: range), freshness: freshness)

        #expect(lookup.contains(":5  in Box.w  (file changed since last build)"), "\(lookup)")
        #expect(diff.contains("Beta.swift:5") && diff.contains("(file changed since last build)"), "\(diff)")
    }

    /// A wrapper site in a file written after the build that no store holds a unit for, a file the diff does not list, is counted by `diff`'s header as new, beside the file the diff lists that it counts as changed.
    @Test
    func diffCountsAWrapperSiteInANewFileAsNew() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        try TestSources.write("import Alpha\n\npublic struct Gamma {\n    @Wrap public var z = 1\n}\n", to: "Sources/Beta/Gamma.swift", in: root)
        // Committed, so the diff does not list it: only the wrapper sites it holds make it a file the answer relied on.
        try TestSources.runGit(["add", "Sources/Beta/Gamma.swift"], in: root)
        try TestSources.runGit(["commit", "-m", "add gamma"], in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let range = try DiffRange.resolve(nil, git: GitContext(repoRoot: root))
        let diff = try await engine.diff(options: DiffOptions(range: range), freshness: freshness)

        #expect(diff.contains("2 cited files: 1 changed, 1 new"), "\(diff)")
    }

    /// `status` never opens the store, so after the same build it reads fresh and names the help topic that lists the case among those only a query shows.
    @Test
    func statusReadsFreshAndNamesThePartialBuildCase() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("semantic: fresh"), "\(status)")
        #expect(status.contains(SiftEngine.statusAxisNote), "\(status)")
        #expect(HelpTopics.topic(named: "answers")?.body.contains("unbuilt test files, a file a partial build skipped, a store") == true)
    }
}

private extension PartialBuildAffectedStatusTests {
    /// A package whose `Beta` target writes `Alpha`'s wrapper once, built whole; then the wrapper written a second time in `Beta`, `Alpha`'s initializer's parameter renamed, and `Alpha` alone rebuilt, so `Beta`'s edit predates the store's newest unit but not its own file's; when asked, that edit is committed first and `Beta` edited once more.
    static func partiallyRebuiltPackage(committingBeta: Bool = false) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Fixture\", targets: [.target(name: \"Alpha\"), .target(name: \"Beta\", dependencies: [\"Alpha\"])])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write(Self.alpha(rebuilt: false), to: "Sources/Alpha/Alpha.swift", in: root)
        try TestSources.write(Self.beta(["v"]), to: "Sources/Beta/Beta.swift", in: root)
        // Dated well before the build, so only a later commit is newer than it.
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "fixture"], in: root, dated: Date(timeIntervalSinceNow: -7200))
        try await TestSources.swiftBuildSuspending(packageAt: root)
        try TestSources.write(Self.beta(["v", "w"]), to: "Sources/Beta/Beta.swift", in: root)
        if committingBeta {
            // Committed after Beta's unit, then held a whole second clear of the partial build, since git floors a commit's time to the second.
            try TestSources.runGit(["add", "-A"], in: root)
            try TestSources.runGit(["commit", "-m", "edit beta"], in: root)
            try TestSources.write(Self.beta(["v", "w", "x"]), to: "Sources/Beta/Beta.swift", in: root)
            try await Task.sleep(for: .milliseconds(1100))
        }
        try TestSources.write(Self.alpha(rebuilt: true), to: "Sources/Alpha/Alpha.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Alpha"])
        return root
    }

    /// The wrapper, its initializer's parameter renamed once `rebuilt`: a signature change `diff` lists the callers of, which leaves the declaration the store resolves the same.
    static func alpha(rebuilt: Bool) -> String {
        let parameter = rebuilt ? "value" : "wrappedValue"
        return "@propertyWrapper\npublic struct Wrap {\n    public var wrappedValue: Int\n    public init(wrappedValue \(parameter): Int) {\n        self.wrappedValue = \(parameter)\n    }\n}\n"
    }

    static func beta(_ properties: [String]) -> String {
        "import Alpha\n\npublic struct Box {\n" + properties.map { "    @Wrap public var \($0) = 1\n" }.joined() + "    public init() {}\n}\n"
    }

    static func affected(_ root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }
}
