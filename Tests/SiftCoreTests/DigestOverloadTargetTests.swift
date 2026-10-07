//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the exact targets an ambiguity answer suggests: candidates whose qualified names collide are named by their file ranges, so that following any suggestion serves source rather than the same ambiguity again.
@Suite(.temporaryDirectories)
struct DigestOverloadTargetTests {
    private static func engine(files: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    /// The target of each suggestion line in an ambiguity answer.
    private static func suggestedTargets(in answer: String) -> [String] {
        answer.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  digest ") else { return nil }
            return line.dropFirst("  digest ".count).components(separatedBy: " — ")[0]
        }
    }

    private static func expectEverySuggestionServesSource(
        _ answer: String,
        from engine: SiftEngine,
        containing markers: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let targets = suggestedTargets(in: answer)
        #expect(targets.count == markers.count, sourceLocation: sourceLocation)
        #expect(Set(targets).count == targets.count, "suggested targets repeat: \(targets)", sourceLocation: sourceLocation)
        for (target, marker) in zip(targets, markers) {
            let followed = try engine.digest(target: target, options: DigestOptions())
            #expect(!followed.contains("is ambiguous"), "\(target) answered another ambiguity", sourceLocation: sourceLocation)
            #expect(followed.contains(marker), "\(target) did not serve \(marker)", sourceLocation: sourceLocation)
        }
    }

    @Test
    func overloadsSharingASelectorAreNamedByTheirFileRanges() async throws {
        // Long enough that the two overloads are listed rather than served together.
        let padding = (0 ..< SourcePassthrough.floorLineCeiling).map { "_ = \($0)" }.joined(separator: "\n            ")
        let source = """
        struct Store {
            func lookup(_ row: Int, from base: String) -> Bool {
                row > 0
            }

            private func lookup(_ usr: String, from base: String) -> Bool {
            \(padding)
                usr.isEmpty
            }
        }
        """
        let engine = try await Self.engine(files: ["Sources/Core/Store.swift": source])

        let answer = try engine.digest(target: "Store.lookup(_:from:)", options: DigestOptions())

        #expect(answer.contains("is ambiguous — 2 declarations"))
        try Self.expectEverySuggestionServesSource(answer, from: engine, containing: ["row > 0", "usr.isEmpty"])
    }

    @Test
    func typesSharingAQualifiedNameAreNamedByTheirFileRanges() async throws {
        let engine = try await Self.engine(files: [
            "Sources/Core/First.swift": "struct Twin {\n    let first = 1\n}\n",
            "Sources/Core/Second.swift": "struct Twin {\n    let second = 2\n}\n",
        ])

        let answer = try engine.digest(target: "Twin", options: DigestOptions())

        #expect(answer.contains("is ambiguous — 2 declarations"))
        let targets = Self.suggestedTargets(in: answer)
        #expect(Set(targets).count == 2)
        for (target, marker) in zip(targets, ["= 1", "= 2"]) {
            let followed = try engine.digest(target: target, options: DigestOptions())
            #expect(!followed.contains("is ambiguous"), "\(target) answered another ambiguity")
            #expect(followed.contains(marker), "\(target) did not serve \(marker)")
        }
    }
}
