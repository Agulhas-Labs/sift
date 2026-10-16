//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An `--at` answer that finds no declaration of a name held by a Swift file's basename names that file from the revision's own file list, with the revision in the command it offers.
@Suite(.serialized, .temporaryDirectories)
struct RevisionBasenamePointerTests {
    static var sprocketLine: String {
        "no declaration named Sprocket; a file has that name: digest Sources/App/Sprocket.swift --at HEAD"
    }

    static func makeRepo(files: [String: String]) throws -> URL {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    static let extensionsOnly: [String: String] = [
        "Sources/App/Widget.swift": "struct Widget {}\n",
        "Sources/App/Sprocket.swift": "extension Int {}\n",
    ]

    @Test func whereAtARevisionNamesTheFileOfExtensionsWithTheRevisionInTheCommand() async throws {
        let root = try Self.makeRepo(files: Self.extensionsOnly)
        let answer = try await SiftEngine(directory: root).lookup(symbol: "Sprocket", at: "HEAD")

        #expect(answer.contains(Self.sprocketLine), "\(answer)")
    }

    @Test func digestAtARevisionNamesTheFileOfExtensionsWithTheRevisionInTheCommand() throws {
        let root = try Self.makeRepo(files: Self.extensionsOnly)
        let answer = try SiftEngine(directory: root).digest(targets: ["Sprocket"], at: "HEAD", options: DigestOptions())

        #expect(answer.contains(Self.sprocketLine), "\(answer)")
    }

    @Test func aNearMissAtARevisionLeadsTheListWithTheFile() async throws {
        let root = try Self.makeRepo(files: [
            "Sources/App/Widget.swift": "struct Widget {}\n",
            "Sources/App/Gizmo.swift": "extension Int {}\n",
            "Tests/AppTests/GizmoTests.swift": "struct GizmoTests {}\n",
        ])
        let answer = try await SiftEngine(directory: root).lookup(symbol: "Gizmo", at: "HEAD")
        let line = "no declaration named Gizmo; a file has that name: digest Sources/App/Gizmo.swift --at HEAD"

        #expect(answer.contains("\(line)\nno exact match; nearest symbols:"), "\(answer)")
        #expect(answer.contains("GizmoTests"), "\(answer)")
    }

    @Test func aFileAddedAfterTheRevisionIsNotNamedAtIt() async throws {
        let root = try Self.makeRepo(files: ["Sources/App/Widget.swift": "struct Widget {}\n"])
        try TestSources.write("extension Int {}\n", to: "Sources/App/Sprocket.swift", in: root)
        try TestSources.commitAll(in: root, message: "later")
        let engine = try SiftEngine(directory: root)

        let past = try await engine.lookup(symbol: "Sprocket", at: "HEAD~1")
        #expect(!past.contains("a file has that name"), "\(past)")
        let now = try await engine.lookup(symbol: "Sprocket", at: "HEAD")
        #expect(now.contains(Self.sprocketLine), "\(now)")
    }

    @Test func theWorkingTreeAnswerCarriesNoRevision() async throws {
        let root = try Self.makeRepo(files: Self.extensionsOnly)
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let answer = try await engine.lookup(symbol: "Sprocket", freshness: engine.ensureFresh())

        #expect(answer.contains("no declaration named Sprocket; a file has that name: digest Sources/App/Sprocket.swift"), "\(answer)")
        #expect(!answer.contains("--at"), "\(answer)")
    }
}
