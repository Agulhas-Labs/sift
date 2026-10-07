//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `where` answer in a tree with no index store opens with at most three short lines, and the recipe for building a store moves to the help topic the first of them names.
///
/// The preamble is every line from the mode line to the blank line that opens the answer itself: the header and the `where` line above it are the same on every answer.
@Suite(.temporaryDirectories)
struct WhereShortModeTests {
    /// The widest a preamble line may run.
    private static let widthLimit = 160

    /// A repository holding one type with one called method, committed, with a `Package.swift` at its root when `package` is set.
    private static func makeRepo(package: Bool = false) throws -> URL {
        let root = try TestSources.makeTempRepo()
        if package {
            try TestSources.write("// swift-tools-version:6.0\nimport PackageDescription\n", to: "Package.swift", in: root)
        }
        try TestSources.write("struct Helper {\n    func work() {}\n}\n", to: "Sources/App/Helper.swift", in: root)
        try TestSources.write("func go() { Helper().work() }\n", to: "Sources/App/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }

    /// The `where` answer for `symbol` in `directory`, with references swept.
    private static func answer(_ symbol: String, in directory: URL) async throws -> String {
        let engine = try SiftEngine(directory: directory)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// The lines from the mode line up to the blank line under it.
    private static func preamble(of answer: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try #require(lines.firstIndex { $0.hasPrefix("mode: ") }, "\(answer)", sourceLocation: sourceLocation)
        let end = lines[start...].firstIndex(of: "") ?? lines.endIndex
        return Array(lines[start ..< end])
    }

    /// Asserts `preamble` is at most three lines, none wider than the limit.
    private static func expectShort(_ preamble: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(preamble.count <= 3, "\(preamble)", sourceLocation: sourceLocation)
        for line in preamble {
            #expect(line.count <= widthLimit, "\(line.count) characters: \(line)", sourceLocation: sourceLocation)
        }
    }

    /// Asserts the help topic `name` carries the build commands and the config key the preamble no longer does.
    private static func expectRecipe(inTopic name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let body = try #require(HelpTopics.topic(named: name), sourceLocation: sourceLocation).body
        for word in ["xcodebuild", "indexStorePath", "generic/platform=iOS Simulator", "swift build --build-tests"] {
            #expect(body.contains(word), "\(name) lacks \(word)", sourceLocation: sourceLocation)
        }
    }

    /// A checkout never built is told in three short lines, the first naming the `answers` topic, which carries the recipe.
    @Test
    func aCheckoutSweepOpensWithThreeShortLinesNamingTheHelpTopic() async throws {
        let preamble = try await Self.preamble(of: Self.answer("work()", in: Self.makeRepo()))

        Self.expectShort(preamble)
        #expect(preamble.count == 3, "\(preamble)")
        #expect(preamble.first?.contains("no index store for this tree yet") == true, "\(preamble)")
        #expect(preamble.first?.contains("sift help answers") == true, "\(preamble)")
        #expect(preamble.contains { $0.hasPrefix("callers/overrides: NOT ANSWERED") }, "\(preamble)")
        #expect(preamble.last?.contains("by written name") == true, "\(preamble)")
        #expect(preamble.last?.contains("same-named") == true, "\(preamble)")
        #expect(preamble.last?.contains("comments") == true, "\(preamble)")
        #expect(!preamble.joined().contains("xcodebuild"), "\(preamble)")
        try Self.expectRecipe(inTopic: "answers")
    }

    /// A worktree is named as one, and points at the `worktree-index` topic, which carries the recipe too.
    @Test
    func aWorktreeSweepNamesTheWorktreeTopic() async throws {
        let worktree = try TestSources.makeWorktree(of: Self.makeRepo(), named: "agent-7d8e9f0a")
        let preamble = try await Self.preamble(of: Self.answer("work()", in: worktree))

        Self.expectShort(preamble)
        #expect(preamble.first?.contains("no index store in this worktree") == true, "\(preamble)")
        #expect(preamble.first?.contains("sift help worktree-index") == true, "\(preamble)")
        try Self.expectRecipe(inTopic: "worktree-index")
    }

    /// A worktree of a package keeps the one command that builds its store, still within the width.
    @Test
    func aWorktreeOfAPackageKeepsItsBuildCommandWithinTheWidth() async throws {
        let worktree = try TestSources.makeWorktree(of: Self.makeRepo(package: true), named: "agent-1b2c3d4e")
        let preamble = try await Self.preamble(of: Self.answer("work()", in: worktree))

        #expect(preamble.first?.contains("sift run -- swift build --build-tests") == true, "\(preamble)")
        #expect(preamble.first?.contains("sift help worktree-index") == true, "\(preamble)")
        Self.expectShort(preamble)
    }

    /// A type's preamble, headed "used by" rather than callers, is held to the same width.
    @Test
    func aTypeSweepIsHeldToTheSameWidth() async throws {
        let preamble = try await Self.preamble(of: Self.answer("Helper", in: Self.makeRepo()))

        #expect(preamble.contains { $0.hasPrefix("used by: NOT ANSWERED") }, "\(preamble)")
        Self.expectShort(preamble)
    }

    /// A rejected `indexStorePath` is still named on the short mode line, since the reader who set it must learn it was refused.
    @Test
    func aRejectedSettingSurvivesOnTheShortModeLine() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}\n", to: "Sources/App/Helper.swift", in: root)
        try TestSources.write(#"{"indexStorePath": ".build/debug/index/store"}"#, to: ".sift.json", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let preamble = try await Self.preamble(of: Self.answer("helper()", in: root))
        let rejection = "indexStorePath '.build/debug/index/store' in .sift.json is not an index store (no v<N>/units under it)"

        #expect(preamble.count <= 3, "\(preamble)")
        #expect(preamble.first?.contains("no index store for this tree yet — \(rejection); how to build one:") == true, "\(preamble)")
    }
}
