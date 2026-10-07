//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A worktree of a SwiftPM package is told the one command that builds its store, in the same one line; a pointer to the help topic alone sent readers to `grep` instead.
@Suite(.temporaryDirectories)
struct WorktreePackageNoteTests {
    @Test
    func aWorktreeWithAPackageAtItsRootIsToldTheBuildCommand() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version:6.0\nimport PackageDescription\n", to: "Package.swift", in: root)
        try TestSources.write("struct Helper {\n    func work() {}\n}\n", to: "Sources/App/Helper.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let worktree = try TestSources.makeWorktree(of: root, named: "agent-5e6f7a8b")
        let engine = try SiftEngine(directory: worktree)

        let output = try await engine.lookup(symbol: "work()", freshness: engine.ensureFresh())
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let modeIndex = try #require(lines.firstIndex { $0.hasPrefix("mode:") })

        #expect(lines.first?.contains("semantic: none (no index store — see note)") == true, "\(output)")
        let expected = "mode: syntactic (sift help answers); no index store in this worktree; "
            + "build: sift run -- swift build --build-tests (sift help worktree-index)"
        #expect(lines[modeIndex] == expected, "\(output)")
        #expect(lines[modeIndex + 1].hasPrefix("callers/overrides: NOT ANSWERED"))
    }
}
