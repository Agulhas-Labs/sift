//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A recursive search by Claude Code's `ugrep` leaves out what `.gitignore` ignores, so the in-process search that weighs an answer does too.
@Suite(.temporaryDirectories)
struct GrepWalkIgnoreTests {
    /// A committed repository whose `.gitignore` names `build/`, holding `Sources/App/Kept.swift` and an ignored `build/Generated.swift`, both declaring `enum Ends`.
    private static func repository() throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([".gitignore": "build/\n", "Sources/App/Kept.swift": "enum Ends {}\n"], to: root)
        try Self.write(["build/Generated.swift": "enum Ends {}\n"], in: root)
        return root
    }

    private static func write(_ files: [String: String], in root: URL) throws {
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The files `enum Ends` is printed from under `root`, as `program`'s walk reads it.
    private static func printedFiles(in root: URL, program: ShellGrep.Program, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let search = try #require(ShellGrep(arguments: ["-r", "-E", "-n", "--", "enum Ends", "."]), sourceLocation: sourceLocation)
        let measured = search.measured(in: root.path, skipsCache: true, program: program)
        guard case let .printed(lines) = measured.outcome else {
            Issue.record("expected the search to be worked out, got \(measured.outcome)", sourceLocation: sourceLocation)
            return []
        }
        let prefixes = [root.path, "/private" + root.path].map { $0 + "/" }
        return Set(lines.map { line in prefixes.first(where: line.file.hasPrefix).map { String(line.file.dropFirst($0.count)) } ?? line.file }).sorted()
    }

    @Test
    func ugrepDoesNotCountAnIgnoredDirectory() throws {
        let root = try Self.repository()

        let files = try Self.printedFiles(in: root, program: .ugrep)

        #expect(files == ["Sources/App/Kept.swift"])
    }

    @Test
    func theSystemGrepStillCountsAnIgnoredDirectory() throws {
        let root = try Self.repository()

        let files = try Self.printedFiles(in: root, program: .system)

        #expect(files.contains("build/Generated.swift"))
    }

    @Test
    func ugrepCountsAnUntrackedFileThatIsNotIgnored() throws {
        let root = try Self.repository()
        try Self.write(["Sources/App/Loose.swift": "enum Ends {}\n"], in: root)

        let files = try Self.printedFiles(in: root, program: .ugrep)

        #expect(files == ["Sources/App/Kept.swift", "Sources/App/Loose.swift"])
    }

    @Test
    func aDirectoryThatIsNoRepositoryIsWalkedWhole() throws {
        let root = try TemporaryDirectory.make("not-a-repository")
        try Self.write([".gitignore": "build/\n", "Kept.swift": "enum Ends {}\n", "build/Generated.swift": "enum Ends {}\n"], in: root)

        let files = try Self.printedFiles(in: root, program: .ugrep)

        #expect(files == ["Kept.swift", "build/Generated.swift"])
    }

    /// A `Grep` for a declaration, in a repository whose ignored `build/` holds more files naming it than a search reads: the walk leaves them out, so the search is worked out, small, and the answer is withheld rather than handed over unweighed.
    @Test
    func anIgnoredDirectoryOfMatchesDoesNotKeepTheHookFromWeighingTheSearch() async throws {
        let root = try Self.repository()
        let padding = String(repeating: "generated ", count: 4)
        try Self.write(Dictionary(uniqueKeysWithValues: (1 ... 4100).map { ("build/Gen\($0).swift", "enum Ends {} // \(padding)\n") }), in: root)
        let match = try #require(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "enum Ends", "output_mode": "content"], in: root.path))
        let backoff = try InPlaceAnswerTests.backoff()

        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, deadline: .unbounded, backoff: backoff)
        }

        #expect(outcome == .withheld(.notSmaller))
    }

    /// A committed repository whose root `.gitignore` names `Sources/Gen/`, `*.gen.swift` and `build/`, with `Gizmo` in `Sources/Gen/a.swift`, `Sources/Keep/b.swift`, the ignored `Sources/Keep/c.gen.swift` and `build/d.swift`.
    private static func parentIgnoredRepository() throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([".gitignore": "Sources/Gen/\n*.gen.swift\nbuild/\n", "Sources/Keep/b.swift": "let Gizmo = 1\n"], to: root)
        try Self.write([
            "Sources/Gen/a.swift": "let Gizmo = 1\n",
            "Sources/Keep/c.gen.swift": "let Gizmo = 1\n",
            "build/d.swift": "let Gizmo = 1\n",
        ], in: root)
        return root
    }

    /// The files `Gizmo` is printed from by a walk of `operand` from `directory`, each named as the walk prints it.
    private static func needleFiles(walking directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let search = try #require(ShellGrep(arguments: ["-r", "-E", "-n", "--", "Gizmo", "."]), sourceLocation: sourceLocation)
        let measured = search.measured(in: directory.path, skipsCache: true)
        guard case let .printed(lines) = measured.outcome else {
            Issue.record("expected the search to be worked out, got \(measured.outcome)", sourceLocation: sourceLocation)
            return []
        }
        let prefixes = [directory.path, "/private" + directory.path].map { $0 + "/" }
        return Set(lines.map { line in prefixes.first(where: line.file.hasPrefix).map { String(line.file.dropFirst($0.count)) } ?? line.file }).sorted()
    }

    /// `ugrep` reads only the ignore files at or below the directory it searches, so a root `.gitignore` bears on a search of `Sources` for git alone: the files it names are still printed.
    @Test
    func ugrepCountsWhatAParentGitignoreNamesBelowTheSearchedDirectory() throws {
        let root = try Self.parentIgnoredRepository()

        let files = try Self.needleFiles(walking: root.appendingPathComponent("Sources"))

        #expect(files == ["Gen/a.swift", "Keep/b.swift", "Keep/c.gen.swift"])
    }

    /// The walk of the repository root itself keeps git's listing, so what the root `.gitignore` names is left out.
    @Test
    func ugrepWalkingTheRepositoryRootStillLeavesOutIgnoredFiles() throws {
        let root = try Self.parentIgnoredRepository()

        let files = try Self.needleFiles(walking: root)

        #expect(files == ["Sources/Keep/b.swift"])
    }

    /// Ripgrep, behind the `Grep` tool, does read the parent `.gitignore`: the search of `Sources` skips what it names.
    @Test
    func theGrepToolSkipsWhatAParentGitignoreNamesBelowTheSearchedDirectory() throws {
        let root = try Self.parentIgnoredRepository()
        let input: [String: Any] = ["pattern": "Gizmo", "output_mode": "content"]
        let search = try #require(SearchToolGrep(input: input, pattern: "Gizmo", searched: root.appendingPathComponent("Sources").path, in: root.path))

        let bytes = search.printedBytes(answerBytes: .max, deadline: .unbounded)

        #expect(bytes == "Sources/Keep/b.swift:1:let Gizmo = 1\n".utf8.count)
    }

    /// A repository whose root `.gitignore` names `Gen/` and whose `Packages/Kit/.gitignore` names `.build/`, holding `Gizmo` in `Packages/Kit/Sources/k.swift`, the ignored `Packages/Kit/.build/x.swift` and `Packages/Sources/Gen/g.swift`.
    private static func nestedIgnoreRepository() throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            ".gitignore": "Gen/\n",
            "Packages/Kit/.gitignore": ".build/\n",
            "Packages/Kit/Sources/k.swift": "let Gizmo = 1\n",
        ], to: root)
        try Self.write([
            "Packages/Kit/.build/x.swift": "let Gizmo = 1\n",
            "Packages/Sources/Gen/g.swift": "let Gizmo = 1\n",
        ], in: root)
        return root
    }

    /// `ugrep` reads `Packages/Kit/.gitignore` when it searches `Packages`, so `Kit/.build` is left out, but not the root `.gitignore`, so what only that names is still counted.
    @Test
    func ugrepBelowTheRootLeavesOutWhatABelowGitignoreNamesAndCountsWhatOnlyTheRootNames() throws {
        let root = try Self.nestedIgnoreRepository()

        let files = try Self.needleFiles(walking: root.appendingPathComponent("Packages"))

        #expect(files == ["Kit/Sources/k.swift", "Sources/Gen/g.swift"])
    }

    /// The `Grep` tool's ripgrep reads both, so it counts neither the `.build` nor the `Gen` file.
    @Test
    func theGrepToolBelowTheRootLeavesOutWhatEitherGitignoreNames() throws {
        let root = try Self.nestedIgnoreRepository()
        let input: [String: Any] = ["pattern": "Gizmo", "output_mode": "content"]
        let search = try #require(SearchToolGrep(input: input, pattern: "Gizmo", searched: root.appendingPathComponent("Packages").path, in: root.path))

        let bytes = search.printedBytes(answerBytes: .max, deadline: .unbounded)

        #expect(bytes == "Packages/Kit/Sources/k.swift:1:let Gizmo = 1\n".utf8.count)
    }
}
