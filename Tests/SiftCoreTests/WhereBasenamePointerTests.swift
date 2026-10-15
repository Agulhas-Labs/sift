//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `where` that finds no declaration points at the Swift file whose basename is the queried name.
@Suite(.serialized, .temporaryDirectories)
struct WhereBasenamePointerTests {
    static func answer(files: [String: String], query: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return try await engine.lookup(symbol: query, freshness: engine.ensureFresh())
    }

    /// One file with the name gets the pointer line, right after the absence line.
    @Test
    func oneMatchingFileIsNamed() async throws {
        let answer = try await Self.answer(
            files: ["Sources/App/Widget.swift": "struct Widget {}", "Sources/App/Gizmo.swift": "extension Widget { func stop() {} }"],
            query: "Gizmo"
        )

        #expect(answer.contains("no declarations found\nno declaration named Gizmo; a file has that name: digest Sources/App/Gizmo.swift"), "\(answer)")
    }

    /// A query with a path in it is not a basename, so a file whose path ends with it is not named.
    @Test
    func aPathQueryNamesNoFile() async throws {
        let answer = try await Self.answer(
            files: ["Sources/App/Widget.swift": "struct Widget {}", "Sources/App/Gizmo.swift": "extension Widget { func stop() {} }"],
            query: "App/Gizmo"
        )

        #expect(!answer.contains("a file has that name"), "\(answer)")
    }

    /// Several files with the name are counted, three are shown and the rest counted.
    @Test
    func severalMatchingFilesAreCapped() async throws {
        var files = ["Sources/App/Widget.swift": "struct Widget {}"]
        for module in ["A", "B", "C", "D", "E"] {
            files["Sources/\(module)/Gizmo.swift"] = "extension Widget { func run() {} }"
        }
        let answer = try await Self.answer(files: files, query: "Gizmo")

        #expect(answer.contains("no declaration named Gizmo; 5 files have that name: digest Sources/A/Gizmo.swift, digest Sources/B/Gizmo.swift, digest Sources/C/Gizmo.swift, and 2 more"), "\(answer)")
    }

    /// No file with the name, no pointer.
    @Test
    func noMatchingFileAddsNothing() async throws {
        let answer = try await Self.answer(files: ["Sources/App/Widget.swift": "struct Widget {}"], query: "Gizmo")

        #expect(answer.contains("no declarations found"), "\(answer)")
        #expect(!answer.contains("no declaration named"), "\(answer)")
    }

    /// A name that is both a declaration and a basename is answered as a declaration, with no pointer.
    @Test
    func aDeclarationNamedLikeAFileIsUnchanged() async throws {
        let answer = try await Self.answer(files: ["Sources/App/Widget.swift": "struct Widget {}"], query: "Widget")

        #expect(!answer.contains("no declaration named"), "\(answer)")
        #expect(!answer.contains("no declarations found"), "\(answer)")
    }
}
