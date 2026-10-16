//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A name declared nowhere but held by a Swift file's basename is named in every "not declared" answer, including the ones that list nearest symbols.
@Suite(.serialized, .temporaryDirectories)
struct NearMissBasenamePointerTests {
    static var pointer: String {
        "no declaration named Gizmo; a file has that name: digest Sources/App/Gizmo.swift"
    }

    static let withTests: [String: String] = [
        "Sources/App/Widget.swift": "struct Widget {}\n",
        "Sources/App/Gizmo.swift": "extension Widget { func stop() {} }\n",
        "Tests/AppTests/GizmoTests.swift": "struct GizmoTests {}\n",
    ]

    static func engine(files: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    @Test func whereNearMissNamesTheFileBeforeTheList() async throws {
        let engine = try await Self.engine(files: Self.withTests)
        let answer = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh())

        #expect(answer.contains("\(Self.pointer)\nno exact match; nearest symbols:"))
        #expect(answer.contains("GizmoTests"))
    }

    @Test func digestNearMissNamesTheFileBeforeTheListAndStaysAMiss() async throws {
        let engine = try await Self.engine(files: Self.withTests)
        let answer = try engine.digest(target: "Gizmo", options: DigestOptions())

        #expect(answer.contains("\(Self.pointer)\nno type named Gizmo; nearest symbols:"))
        #expect(DigestMiss.isMiss(inAnswer: answer))
    }

    @Test func digestWithNoCandidatesNamesTheFileAfterTheAbsence() async throws {
        var files = Self.withTests
        files["Tests/AppTests/GizmoTests.swift"] = nil
        let engine = try await Self.engine(files: files)
        let answer = try engine.digest(target: "Gizmo", options: DigestOptions())

        #expect(answer.contains("no symbol named Gizmo in the index\n\(Self.pointer)"))
        #expect(DigestMiss.isMiss(inAnswer: answer))
    }

    @Test func nearMissWithoutAFileOfThatNameHasNoPointer() async throws {
        var files = Self.withTests
        files["Sources/App/Gizmo.swift"] = nil
        let engine = try await Self.engine(files: files)
        let found = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh())
        let digested = try engine.digest(target: "Gizmo", options: DigestOptions())
        for answer in [found, digested] {
            #expect(answer.contains("nearest symbols:"))
            #expect(answer.contains("GizmoTests"))
            #expect(!answer.contains("no declaration named"))
        }
    }

    @Test func digestOfATypealiasNamedLikeItsFileHasNoPointer() async throws {
        let engine = try await Self.engine(files: ["Sources/Kit/Widget.swift": "typealias Widget = Int\n"])
        let answer = try engine.digest(target: "Widget", options: DigestOptions())

        #expect(!answer.contains("no declaration named"))
    }

    @Test func digestOfAFunctionNamedLikeItsFileHasNoPointer() async throws {
        let engine = try await Self.engine(files: ["Sources/Kit/Lever.swift": "func Lever() {}\n"])
        let answer = try engine.digest(target: "Lever", options: DigestOptions())

        #expect(!answer.contains("no declaration named"))
    }

    @Test func aModuleQualifiedQueryIsMatchedOnItsBaseName() async throws {
        let engine = try await Self.engine(files: ["Sources/App/Sprocket.swift": "extension Int {}\n"])
        let found = try await engine.lookup(symbol: "App.Sprocket", freshness: engine.ensureFresh())
        let digested = try engine.digest(target: "App.Sprocket", options: DigestOptions())
        for answer in [found, digested] {
            #expect(answer.contains("no declaration named Sprocket; a file has that name: digest Sources/App/Sprocket.swift"))
        }
    }
}
