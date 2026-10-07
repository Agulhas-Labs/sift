//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a file digest whose target is a suffix more than one indexed file ends in: the answer names the candidates rather than "no indexed file matches", which is false about a target that matched several, and a suffix only one file ends in still resolves to that file.
@Suite(.temporaryDirectories)
struct AmbiguousFileDigestTests {
    private static func engine(files: [String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for path in files {
            try TestSources.write("struct Model {}\n", to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    @Test
    func aSuffixTwoFilesEndInListsBoth() async throws {
        let engine = try await Self.engine(files: ["Sources/Core/Model.swift", "Tests/Core/Model.swift"])

        let answer = try engine.digest(target: "Core/Model.swift", options: DigestOptions())

        #expect(answer == """
        Core/Model.swift is ambiguous — 2 indexed files end in it; digest one of these exact targets:
          digest Sources/Core/Model.swift
          digest Tests/Core/Model.swift
        """)
    }

    /// The list is the whole of what a caller can act on, so a cut one says how much it cut rather than reading as every file there is.
    @Test
    func aSuffixManyFilesEndInIsCutToTheCapAndSaysSo() async throws {
        let count = DigestRenderer.memberCap + 3
        let files = (0 ..< count).map { "Sources/Part\($0)/Model.swift" }
        let engine = try await Self.engine(files: files)

        let answer = try engine.digest(target: "Model.swift", options: DigestOptions())
        let lines = answer.split(separator: "\n").map(String.init)

        #expect(lines.first == "Model.swift is ambiguous — \(count) indexed files end in it; digest one of these exact targets:")
        #expect(lines.filter { $0.hasPrefix("  digest ") }.count == DigestRenderer.memberCap)
        #expect(lines.contains("  digest Sources/Part0/Model.swift"))
        #expect(lines.last == "  truncated: 3 more files")
    }

    @Test
    func aSuffixOneFileEndsInStillResolvesToIt() async throws {
        let engine = try await Self.engine(files: ["Sources/Core/Model.swift", "Tests/Other/Model.swift"])

        let answer = try engine.digest(target: "Core/Model.swift", options: DigestOptions())

        #expect(answer.contains("struct Model {}"))
        #expect(!answer.contains("ambiguous"))
    }

    /// A guessed directory that no indexed path ends in at all — not even a suffix mismatch, a plain miss — still serves the one indexed file of that basename, named on a leading line so the answer isn't mistaken for the exact path asked.
    @Test
    func aWrongDirectoryGuessWithOneBasenameMatchIsServedWithANotice() async throws {
        let engine = try await Self.engine(files: ["Sources/Alpha/Widget.swift"])

        let answer = try engine.digest(target: "Sources/Beta/Widget.swift", options: DigestOptions())

        #expect(answer.contains("no indexed file at Sources/Beta/Widget.swift — served Sources/Alpha/Widget.swift, the one indexed file of that name"))
        #expect(answer.contains("struct Model {}"))
    }

    /// A guessed directory that matches several indexed files of the same basename serves none of them — guessing one would repeat exactly the wrong-directory mistake this fallback exists to fix.
    @Test
    func aWrongDirectoryGuessWithSeveralBasenameMatchesServesNone() async throws {
        let engine = try await Self.engine(files: ["Sources/Alpha/Widget.swift", "Sources/Gamma/Widget.swift"])

        let answer = try engine.digest(target: "Sources/Beta/Widget.swift", options: DigestOptions())

        #expect(answer == """
        no indexed file matches Sources/Beta/Widget.swift — 2 indexed files share that basename; digest one of these exact targets:
          digest Sources/Alpha/Widget.swift
          digest Sources/Gamma/Widget.swift
        """)
    }

    /// More basename matches than `memberCap` are cut to the cap, the same way a suffix ambiguity is — a list that stops without saying so reads as every match there is.
    @Test
    func manyBasenameMatchesAreCutToTheCapAndSaySo() async throws {
        let count = DigestRenderer.memberCap + 3
        let files = (0 ..< count).map { "Sources/Part\($0)/Widget.swift" }
        let engine = try await Self.engine(files: files)

        let answer = try engine.digest(target: "Elsewhere/Widget.swift", options: DigestOptions())
        let lines = answer.split(separator: "\n").map(String.init)

        #expect(lines.first == "no indexed file matches Elsewhere/Widget.swift — \(count) indexed files share that basename; digest one of these exact targets:")
        #expect(lines.filter { $0.hasPrefix("  digest ") }.count == DigestRenderer.memberCap)
        #expect(lines.last == "  truncated: 3 more files")
    }

    /// A path target with no basename match anywhere in the index is the plain miss, unchanged.
    @Test
    func noBasenameMatchIsThePlainMiss() async throws {
        let engine = try await Self.engine(files: ["Sources/Core/Model.swift"])

        let answer = try engine.digest(target: "Sources/Elsewhere/Nowhere.swift", options: DigestOptions())

        #expect(answer == "no indexed file matches Sources/Elsewhere/Nowhere.swift")
    }

    /// A file that exists but is deliberately excluded from the index (gitignored) is told that, even where an indexed file elsewhere shares its basename — the basename fallback exists for a wrong-directory guess, never to override an answer that already found the exact path asked for.
    @Test
    func anExcludedFileKeepsItsNotIndexedAnswerRatherThanABasenameMatch() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct One {}\n", to: "Sources/A/One.swift", in: root)
        try TestSources.write("Fixtures/\n", to: ".gitignore", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("struct One {}\n", to: "Tests/Fixtures/One.swift", in: root)
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let answer = try engine.digest(target: "Tests/Fixtures/One.swift", options: DigestOptions())

        #expect(answer == "Tests/Fixtures/One.swift exists but is not indexed — git ignores it. A plain Read is the way to see it: nothing in it is in the index.")
    }

    /// An absolute path outside this repository is never served a repo file merely because it shares an indexed file's basename — the plain miss stands, since the basename search only ever runs on a path this repository could plausibly have meant.
    @Test
    func anAbsolutePathOutsideTheRepositoryIsNotServedARepoFile() async throws {
        let engine = try await Self.engine(files: ["Sources/A/One.swift"])
        let otherRepo = try TestSources.makeTempRepo()
        let outside = otherRepo.appendingPathComponent("Other/One.swift").path

        let answer = try engine.digest(target: outside, options: DigestOptions())

        #expect(answer == "no indexed file matches \(outside)")
    }
}
