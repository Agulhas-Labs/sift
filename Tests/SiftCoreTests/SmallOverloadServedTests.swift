//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the `Type.member` a name shares between several declarations: served in one answer where they are small together, listed where they are not, where an offset was passed, or where one cannot be read.
@Suite(.temporaryDirectories)
struct SmallOverloadServedTests {
    private static var path: String {
        "Sources/Core/Store.swift"
    }

    private static func engine(source: String) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: path, in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    /// Two overloads of `lookup`, the second given `fill` extra lines of body.
    private static func overloads(fill: Int) -> String {
        let padding = (0 ..< fill).map { "_ = \($0)" }.joined(separator: "\n        ")
        return """
        struct Store {
            func lookup(_ row: Int) -> Bool {
                row > 0
            }

            func lookup(_ usr: String) -> Bool {
                \(padding)
                return usr.isEmpty
            }
        }
        """
    }

    @Test
    func overloadsSmallTogetherAreServedUnderAnOpeningLine() async throws {
        let engine = try await Self.engine(source: Self.overloads(fill: 0))

        let answer = try engine.digest(target: "Store.lookup", options: DigestOptions())

        #expect(!answer.contains("is ambiguous"), "\(answer)")
        let lines = answer.components(separatedBy: "\n")
        let opening = try #require(lines.firstIndex { $0.contains("names 2 declarations") }, "\(answer)")
        #expect(lines[opening] == "Store.lookup names 2 declarations, 7 lines together; each follows")
        #expect(lines[opening + 1].isEmpty)
        let first = try #require(lines.firstIndex { $0.hasSuffix("— func — \(Self.path):2-4") }, "\(answer)")
        let second = try #require(lines.firstIndex { $0.hasSuffix("— func — \(Self.path):6-9") }, "\(answer)")
        #expect(opening < first && first < second)
        #expect(lines[first + 2] == "    func lookup(_ row: Int) -> Bool {")
        #expect(lines[second + 2] == "    func lookup(_ usr: String) -> Bool {")
        // One blank line between the blocks, and no part marker: the two are one target's answer.
        #expect(lines[second - 1].isEmpty && !lines[second - 2].isEmpty)
        #expect(!answer.contains(SourcePassthrough.partMarker))
    }

    @Test
    func overloadsAddingUpToTheCeilingAreServedAndOneLineMoreAreListed() async throws {
        // The overloads span `fill + 6` lines together once there is any filler.
        let ceiling = SourcePassthrough.floorLineCeiling
        let atCeiling = try await Self.engine(source: Self.overloads(fill: ceiling - 6))
        let overCeiling = try await Self.engine(source: Self.overloads(fill: ceiling - 5))

        let served = try atCeiling.digest(target: "Store.lookup", options: DigestOptions())
        let listed = try overCeiling.digest(target: "Store.lookup", options: DigestOptions())

        #expect(served.contains("names 2 declarations, \(ceiling) lines together; each follows"), "\(served)")
        #expect(!served.contains("is ambiguous"))
        #expect(listed.contains("Store.lookup is ambiguous — 2 declarations; digest one of these exact targets:"), "\(listed)")
        #expect(!listed.contains("each follows"))
    }

    @Test
    func anOffsetKeepsTheListWhereTheOverloadsAreSmall() async throws {
        let engine = try await Self.engine(source: Self.overloads(fill: 0))

        let answer = try engine.digest(target: "Store.lookup", options: DigestOptions(offset: 1))

        #expect(answer.contains("Store.lookup is ambiguous — 2 declarations"), "\(answer)")
        #expect(!answer.contains("each follows"))
    }

    @Test
    func overloadsWhoseSourceCannotBeReadAreListed() throws {
        let store = try TestSources.makeStore()
        let file = try TestSources.parsed(Self.overloads(fill: 0), path: Self.path)
        try store.replaceFiles([file]) { _ in ("Core", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: TestSources.makeTempDirectory())

        let answer = try renderer.render(target: "Store.lookup", options: DigestOptions())

        #expect(answer.contains("Store.lookup is ambiguous — 2 declarations"), "\(answer)")
        #expect(!answer.contains("each follows"))
    }

    @Test
    func aListLineNamedByItsFileRangePrintsTheLocationOnce() async throws {
        let fill = SourcePassthrough.floorLineCeiling
        let engine = try await Self.engine(source: Self.overloads(fill: fill))

        let answer = try engine.digest(target: "Store.lookup", options: DigestOptions())

        let suggestions = answer.components(separatedBy: "\n").filter { $0.hasPrefix("  digest ") }

        #expect(suggestions == ["  digest \(Self.path):2-4 — func", "  digest \(Self.path):6-\(8 + fill) — func"], "\(answer)")
    }

    @Test
    func aListLineNamedByItsQualifiedNameStillPrintsItsLocation() async throws {
        let source = Self.overloads(fill: SourcePassthrough.floorLineCeiling).replacingOccurrences(of: "lookup(_ usr: String)", with: "lookup(by usr: String)")
        let engine = try await Self.engine(source: source)

        let answer = try engine.digest(target: "Store.lookup", options: DigestOptions())

        let suggestions = answer.components(separatedBy: "\n").filter { $0.hasPrefix("  digest ") }

        #expect(suggestions.count == 2, "\(answer)")
        #expect(suggestions.allSatisfy { $0.contains(" — func — \(Self.path):") }, "\(answer)")
    }

    private static func engine(files: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (file, source) in files {
            try TestSources.write(source, to: file, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    /// A file whose later declarations are lost to a syntax error.
    private static var brokenTail: String {
        """

        struct Broken {
            func truncated(
        }
        """
    }

    @Test
    func theRepositoryWideNoticeLeavesOutTheFilesServedFromAndStillNamesTheOthers() async throws {
        let other = "Sources/Core/Other.swift"
        let engine = try await Self.engine(files: [Self.path: Self.overloads(fill: 0) + Self.brokenTail, other: Self.brokenTail])

        let answer = try engine.digest(target: "Store.lookup", options: DigestOptions())

        let lines = answer.components(separatedBy: "\n")
        let repoWide = try #require(lines.first { $0.hasPrefix("⚠ parse errors elsewhere in this repo") }, "\(answer)")
        #expect(repoWide.hasSuffix("Not files this answer drew on: \(other)"), "\(repoWide)")
        #expect(!repoWide.contains(Self.path))
        #expect(!answer.contains("list below"))
        let scoped = try #require(lines.first { $0.hasPrefix("⚠ parse errors — declarations may be missing from:") }, "\(answer)")
        #expect(scoped.hasSuffix(Self.path))
        #expect(answer.contains("each follows"))
    }

    @Test
    func aServedFileAloneLeavesNothingForTheRepositoryWideNotice() async throws {
        let engine = try await Self.engine(source: Self.overloads(fill: 0) + Self.brokenTail)

        let answer = try engine.digest(target: "Store.lookup", options: DigestOptions())

        #expect(!answer.contains("elsewhere in this repo"), "\(answer)")
        #expect(answer.contains("each follows"))
    }

    @Test
    func twoServedOverloadsInOneBrokenFileCarryItsBannerOnce() async throws {
        let engine = try await Self.engine(source: Self.overloads(fill: 0) + Self.brokenTail)

        let answer = try engine.digest(target: "Store.lookup", options: DigestOptions())

        #expect(answer.components(separatedBy: "⚠ parse errors — declarations may be missing from:").count == 2, "\(answer)")
    }

    @Test
    func aServedSetStaysOnePartBesideAnotherTarget() async throws {
        let engine = try await Self.engine(source: Self.overloads(fill: 0))

        let answer = try engine.digest(targets: ["Store.lookup", "Store"], options: DigestOptions())

        #expect(answer.components(separatedBy: String(SourcePassthrough.partMarker)).count == 2, "\(answer)")
        #expect(answer.contains("each follows"))
    }

    @Test
    func theMemberwiseInitIsAppendedAfterTheServedExtensionInits() async throws {
        let source = """
        struct Pair {
            var left: Int
            var right: Int
        }

        extension Pair {
            init(both: Int) {
                self.init(left: both, right: both)
            }
        }

        extension Pair {
            init(sum: Int) {
                self.init(left: sum, right: 0)
            }
        }
        """
        let engine = try await Self.engine(source: source)

        let answer = try engine.digest(target: "Pair.init", options: DigestOptions())

        let both = try #require(answer.range(of: "init(both: Int)"), "\(answer)")
        let sum = try #require(answer.range(of: "init(sum: Int)"), "\(answer)")
        let synthesized = try #require(answer.range(of: "memberwise", options: String.CompareOptions.backwards), "\(answer)")

        #expect(answer.contains("names 2 declarations"))
        #expect(both.lowerBound < sum.lowerBound && sum.upperBound <= synthesized.lowerBound, "\(answer)")
    }
}
