//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The tree walk behind a grep the hook weighs passes over a version-control directory as `ugrep` does, so it neither reads nor counts what is in it, and no directory `ugrep` reads.
@Suite(.temporaryDirectories)
struct GrepWalkSkipsGitTests {
    /// A repository whose `directory` holds more files than the walk's limit and whose one source file lies past them.
    private static func repository(holding directory: String = ".git") throws -> URL {
        let root = try TemporaryDirectory.make("walk-git").appendingPathComponent("walk-git")
        let objects = root.appendingPathComponent("\(directory)/objects")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        for index in 0 ... ShellGrep.fileLimit {
            try Data("widget \(index)\n".utf8).write(to: objects.appendingPathComponent("o\(index)"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("let widget = 1\n".utf8).write(to: root.appendingPathComponent("Sources/Z.swift"))
        return root
    }

    /// Measured against the `ugrep -G --ignore-files --hidden -I` behind Claude Code's `grep`: it skips these and reads `.cvs`, `CVS`, `_darcs` and `.other`.
    @Test(arguments: [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"])
    func aSearchPassesOverEveryVersionControlDirectoryUgrepSkips(directory: String) throws {
        let root = try Self.repository(holding: directory)
        let measured = try #require(ShellGrep(arguments: ["-rn", "widget", "."])).measured(in: root.path, skipsCache: false)

        guard case let .printed(lines) = measured.outcome else {
            Issue.record("expected the search worked out, got \(measured.outcome)")
            return
        }

        #expect(lines.map { URL(fileURLWithPath: $0.file).lastPathComponent } == ["Z.swift"])
    }

    @Test(arguments: [".cvs", "CVS", "_darcs", ".other"])
    func aSearchStillReadsTheDirectoriesUgrepReads(directory: String) throws {
        let root = try Self.repository(holding: directory)
        let measured = try #require(ShellGrep(arguments: ["-rn", "widget", "."])).measured(in: root.path, skipsCache: false)

        // The directory holds past the walk's limit, so reading it leaves the search undecided rather than worked out from `Z.swift` alone.
        if case let .printed(lines) = measured.outcome {
            #expect(lines.contains { $0.file.contains("/\(directory)/") }, "walk skipped \(directory)")
        }
    }

    @Test
    func aSearchOfAnyShapeFindsTheMatchPastAGitDirectoryAndReadsNothingIn() throws {
        let root = try Self.repository()
        let printed = "Sources/Z.swift:1:let widget = 1\n".utf8.count

        for weighsCache in [false, true] {
            let measured = try #require(ShellGrep(arguments: ["-rn", "widget", "."])).measured(in: root.path, skipsCache: weighsCache)

            guard case let .printed(lines) = measured.outcome else {
                Issue.record("expected the search worked out, got \(measured.outcome)")
                return
            }
            #expect(lines.map { URL(fileURLWithPath: $0.file).lastPathComponent } == ["Z.swift"], "cache \(weighsCache)")
            #expect(measured.bytes == printed, "cache \(weighsCache)")
        }
    }
}
