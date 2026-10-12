//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A range answer says how many uncommitted `.swift` files it left out, whether or not the range itself was empty.
@Suite(.serialized, .temporaryDirectories)
struct AffectedFromUncommittedTests {
    static let head = AffectedOptions.CommitRange(from: "HEAD", to: "HEAD")

    static func answer(in root: URL, range: AffectedOptions.CommitRange?) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: range), freshness: freshness)
    }

    static func repo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public func one() -> Int { 1 }\n", to: "Sources/Lib/One.swift", in: root)
        try TestSources.commitAll(in: root, message: "one")
        return root
    }

    @Test
    func anEmptyRangeWithOneUncommittedFileSaysSo() async throws {
        let root = try Self.repo()
        try TestSources.write("public func two() -> Int { 2 }\n", to: "Sources/Lib/Two.swift", in: root)
        let answer = try await Self.answer(in: root, range: Self.head)

        #expect(answer.contains("1 uncommitted .swift file is not in this range; drop --from to include them, or commit first."), "\(answer)")
    }

    @Test
    func aNonEmptyRangeWithTwoUncommittedFilesSaysSo() async throws {
        let root = try Self.repo()
        try TestSources.write("public func two() -> Int { 2 }\n", to: "Sources/Lib/Two.swift", in: root)
        try TestSources.commitAll(in: root, message: "two")
        try TestSources.write("public func three() -> Int { 3 }\n", to: "Sources/Lib/Three.swift", in: root)
        try TestSources.write("public func one() -> Int { 11 }\n", to: "Sources/Lib/One.swift", in: root)
        let answer = try await Self.answer(in: root, range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD"))

        #expect(answer.contains("2 uncommitted .swift files are not in this range; drop --from to include them, or commit first."), "\(answer)")
    }

    @Test
    func aCleanTreeAddsNoLine() async throws {
        let root = try Self.repo()
        let answer = try await Self.answer(in: root, range: Self.head)

        #expect(!answer.contains("uncommitted"), "\(answer)")
    }

    @Test
    func withoutFromNoLineIsAdded() async throws {
        let root = try Self.repo()
        try TestSources.write("public func two() -> Int { 2 }\n", to: "Sources/Lib/Two.swift", in: root)
        let answer = try await Self.answer(in: root, range: nil)

        #expect(!answer.contains("not in this range"), "\(answer)")
    }

    @Test
    func aDirtyFileOutsideTheIndexIsNotCounted() async throws {
        let root = try Self.repo()
        try TestSources.write("public func other() -> Int { 3 }\n", to: ".build/x/G.swift", in: root)
        let answer = try await Self.answer(in: root, range: Self.head)

        #expect(!answer.contains("uncommitted"), "\(answer)")
    }

    @Test
    func aStagedOnlyNewFileIsCounted() async throws {
        let root = try Self.repo()
        try TestSources.write("public func two() -> Int { 2 }\n", to: "Sources/Lib/Two.swift", in: root)
        _ = try TestSources.runGit(["add", "Sources/Lib/Two.swift"], in: root)
        let answer = try await Self.answer(in: root, range: Self.head)

        #expect(answer.contains("1 uncommitted .swift file is not in this range"), "\(answer)")
    }
}
