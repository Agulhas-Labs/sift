//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A textconv driver comes from the repository's config and is a program git starts to render a diff: a diff sift runs for its content must not start it.
@Suite(.temporaryDirectories)
struct GitConfigHardeningTextconvTests {
    /// The size of a working-tree diff in a repository whose attributes bind a textconv driver that touches a marker: counted without starting the driver.
    @Test
    func aDiffSiftRunsNeverStartsTheRepositoriesTextconvDriver() throws {
        let scene = try Scene()

        let bytes = try GitContext(repoRoot: scene.repo).diffByteCount(from: "HEAD")

        #expect(bytes > 0, "the edit made no diff")
        #expect(!scene.driverRan, "a diff sift ran started the textconv driver")
    }

    /// The same repository, diffed by a plain `git diff` that is asked for a patch, starts the driver: the probe is live.
    @Test
    func theProbeDriverRunsForAPlainPatch() throws {
        let scene = try Scene()

        _ = try scene.git(["diff", "--no-color", "HEAD"])

        #expect(scene.driverRan, "a plain `git diff` never started the driver: the probe proves nothing")
    }
}

extension GitConfigHardeningTextconvTests {
    /// A repository in the test's own temporary directory with one tracked text file bound to a textconv driver, then edited.
    struct Scene {
        let repo: URL
        let marker: URL
        let notes: URL

        init() throws {
            repo = try TemporaryDirectory.make("textconv-repo")
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            let inside = repo.resolvingSymlinksInPath().path
            guard inside.hasPrefix(temporary + "/") else {
                throw OutsideTemporaryDirectory(path: inside)
            }
            marker = repo.appendingPathComponent(".git/textconv-ran")
            notes = repo.appendingPathComponent("notes.txt")
            let driver = repo.appendingPathComponent(".git/driver.sh")
            try "*.txt diff=probe\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            try "one\n".write(to: notes, atomically: true, encoding: .utf8)
            #expect(try git(["init", "-q"]) == 0)
            // The driver is written once the repository exists, inside its git directory, so it is never tracked.
            try "#!/bin/sh\ntouch '\(marker.path)'\ncat \"$1\"\n".write(to: driver, atomically: true, encoding: .utf8)
            #expect(chmod(driver.path, 0o755) == 0)
            #expect(try git(["add", "."]) == 0)
            #expect(try git(["-c", "user.name=probe", "-c", "user.email=probe@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "probe"]) == 0)
            let config = repo.appendingPathComponent(".git/config")
            let existing = try String(contentsOf: config, encoding: .utf8)
            try (existing + "[diff \"probe\"]\n\ttextconv = \(driver.path)\n").write(to: config, atomically: true, encoding: .utf8)
            try "one\ntwo\n".write(to: notes, atomically: true, encoding: .utf8)
        }

        var driverRan: Bool {
            FileManager.default.fileExists(atPath: marker.path)
        }

        func git(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repo
            process.environment = ProcessEnvironment.withoutGit()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    struct OutsideTemporaryDirectory: Error {
        let path: String
    }
}
