//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the note a `sift run` of `xcodebuild` prints when the generated project does not list a Swift file its XcodeGen spec holds.
///
/// No `xcodebuild` is spawned: the line-producing function is called on a fixture directory.
struct XcodeGenStaleProjectTests {
    /// Builds a fixture under a fresh temporary directory, runs `body` on it, and removes it.
    private static func withFixture(spec: String?, listed: [String], _ body: (URL) -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stale-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        for name in ["A", "B"] {
            try "struct \(name) {}\n".write(to: root.appendingPathComponent("Sources/\(name).swift"), atomically: true, encoding: .utf8)
        }
        if let spec {
            try spec.write(to: root.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        }
        let entries = listed.map { "path = \($0).swift;" }.joined(separator: "\n")
        try entries.write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        body(root)
    }

    private static var spec: String {
        """
        name: App
        targets:
          App:
            type: application
            platform: iOS
            sources: [Sources]
        """
    }

    @Test
    func `a file the project does not list is named`() throws {
        try Self.withFixture(spec: Self.spec, listed: ["A"]) { root in
            let line = XcodeGenStaleProject.line(project: root.appendingPathComponent("App.xcodeproj"), repositoryRoot: root)
            #expect(line == "project: App.xcodeproj does not list 1 Swift file its spec project.yml holds (B.swift) — run xcodegen generate")
        }
    }

    @Test
    func `a project listing every file prints nothing`() throws {
        try Self.withFixture(spec: Self.spec, listed: ["A", "B"]) { root in
            #expect(XcodeGenStaleProject.line(project: root.appendingPathComponent("App.xcodeproj"), repositoryRoot: root) == nil)
        }
    }

    @Test
    func `a project with no spec beside it prints nothing`() throws {
        try Self.withFixture(spec: nil, listed: ["A"]) { root in
            #expect(XcodeGenStaleProject.line(project: root.appendingPathComponent("App.xcodeproj"), repositoryRoot: root) == nil)
        }
    }

    @Test
    func `an excluded file the project does not list prints nothing`() throws {
        let excluding = Self.spec.replacingOccurrences(of: "sources: [Sources]", with: "sources:\n          - path: Sources\n            excludes: [\"B.swift\"]")
        try Self.withFixture(spec: excluding, listed: ["A"]) { root in
            #expect(XcodeGenStaleProject.line(project: root.appendingPathComponent("App.xcodeproj"), repositoryRoot: root) == nil)
        }
    }

    @Test
    func `a run of xcodebuild test reads the one project in its directory`() throws {
        try Self.withFixture(spec: Self.spec, listed: ["A"]) { root in
            let line = XcodeGenStaleProject.line(for: ["xcodebuild", "test", "-scheme", "App"], from: root.path, repositoryRoot: root)
            #expect(line?.contains("(B.swift)") == true)
            #expect(XcodeGenStaleProject.line(for: ["swift", "test"], from: root.path, repositoryRoot: root) == nil)
        }
    }

    @Test
    func `a spec whose sources are written from the repository root is read from there`() throws {
        try Self.withFixture(spec: nil, listed: ["A"]) { root in
            let apps = root.appendingPathComponent("Apps", isDirectory: true)
            try? FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: root.appendingPathComponent("App.xcodeproj"), to: apps.appendingPathComponent("App.xcodeproj"))
            try? Self.spec.write(to: apps.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
            let line = XcodeGenStaleProject.line(project: apps.appendingPathComponent("App.xcodeproj"), repositoryRoot: root)
            #expect(line == "project: Apps/App.xcodeproj does not list 1 Swift file its spec Apps/project.yml holds (B.swift) — run xcodegen generate")
        }
    }

    /// Builds a fixture holding exactly `files` (paths below the root) and a project listing `listed`, and returns the note for it.
    private static func note(spec: String, files: [String], listed: [String], padding: Int = 0) throws -> String? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stale-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct S {}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try spec.write(to: root.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        let entries = listed.map { "path = \($0);" } + Array(repeating: "isa = PBXBuildFile; settings = {};", count: padding)
        try entries.joined(separator: "\n").write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        return XcodeGenStaleProject.line(project: root.appendingPathComponent("App.xcodeproj"), repositoryRoot: root)
    }

    /// A spec whose one source is `Sources`, with `source` the extra keys of that entry.
    private static func spec(source: String) -> String {
        "name: App\ntargets:\n  App:\n    type: application\n    platform: iOS\n    sources:\n      - path: Sources\n\(source)"
    }

    @Test
    func `a globstar exclude matches a top-level file`() throws {
        let spec = Self.spec(source: "        excludes: [\"**/*Tests.swift\"]\n")

        #expect(try Self.note(spec: spec, files: ["Sources/FooTests.swift"], listed: []) == nil)
    }

    @Test
    func `a globstar exclude matches a deeply nested file`() throws {
        let spec = Self.spec(source: "        excludes: [\"**/*Tests.swift\"]\n")

        #expect(try Self.note(spec: spec, files: ["Sources/Deep/BetaTests.swift"], listed: []) == nil)
    }

    @Test
    func `a single star in an exclude does not cross a directory`() throws {
        let spec = Self.spec(source: "        excludes: [\"*Tests.swift\"]\n")
        let line = try Self.note(spec: spec, files: ["Sources/Deep/BetaTests.swift"], listed: [])

        #expect(line?.contains("(BetaTests.swift)") == true)
    }

    @Test
    func `a folder reference source is not walked`() throws {
        let spec = Self.spec(source: "        type: folder\n")

        #expect(try Self.note(spec: spec, files: ["Sources/gen.swift"], listed: []) == nil)
    }

    @Test
    func `a playground bundle's files are not sources of their own`() throws {
        let spec = Self.spec(source: "")

        #expect(try Self.note(spec: spec, files: ["Sources/Gizmo.playground/Contents.swift"], listed: []) == nil)
    }

    @Test
    func `a source with includes counts only the files they match`() throws {
        let spec = Self.spec(source: "        includes: [\"*.swift\"]\n")

        #expect(try Self.note(spec: spec, files: ["Sources/Deep/Extra.swift"], listed: []) == nil)
        #expect(try Self.note(spec: spec, files: ["Sources/Extra.swift"], listed: [])?.contains("(Extra.swift)") == true)
    }

    @Test
    func `a listed file whose name ends in a missing file's name does not hide it`() throws {
        let spec = Self.spec(source: "")
        let line = try Self.note(spec: spec, files: ["Sources/B.swift", "Sources/MyB.swift"], listed: ["MyB.swift"])

        #expect(line?.contains("(B.swift)") == true)
    }

    @Test
    func `four thousand listed files are all found listed`() throws {
        // A size case for correctness only. The check reads the project file once into a set of names, where it
        // first searched the whole file once per source file; no wall-clock budget tells the two apart reliably on a
        // loaded machine (1.1 s against 4.6 s alone, 2.8 s for the fast one under the full suite), so none is asserted.
        let names = (0 ..< 4000).map { "Gizmo\($0).swift" }

        #expect(try Self.note(spec: Self.spec(source: ""), files: names.map { "Sources/\($0)" }, listed: names, padding: 20000) == nil)
    }

    @Test
    func `a synchronized folder source is not walked`() throws {
        let spec = Self.spec(source: "        type: syncedFolder\n")

        #expect(try Self.note(spec: spec, files: ["Sources/Gizmo.swift"], listed: []) == nil)
    }

    @Test
    func `a bracket class in an exclude matches as a class`() throws {
        let spec = Self.spec(source: "        excludes: [\"[A-M]*.swift\"]\n")
        let line = try Self.note(spec: spec, files: ["Sources/Gizmo.swift", "Sources/Orchard.swift"], listed: [])

        #expect(line?.contains("(Orchard.swift)") == true)
        #expect(line?.contains("Gizmo.swift") == false)
    }

    @Test
    func `an exclude naming a directory with a trailing slash takes in its files`() throws {
        let spec = Self.spec(source: "        excludes: [\"Generated/\"]\n")

        #expect(try Self.note(spec: spec, files: ["Sources/Generated/Gizmo.swift"], listed: []) == nil)
    }
}
