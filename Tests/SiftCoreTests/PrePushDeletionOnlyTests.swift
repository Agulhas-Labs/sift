//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A push made only of ref deletions (`git push origin --delete <branch>`) sends no commits, so `githooks/pre-push` skips both `swift test` and the privacy gate for it rather than spending minutes on a push that publishes nothing.
///
/// Drives the real hook script, never a copy of its logic: a fake `swift` ahead of it on `PATH` writes a marker file and exits 1, so a run that reaches the gates is provable without ever running the real suite recursively, and a run that doesn't reach them leaves no marker at all.
@Suite(.temporaryDirectories)
struct PrePushDeletionOnlyTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    private static let zeroSha = String(repeating: "0", count: 40)
    private static let realSha = String(repeating: "a", count: 40)

    /// A deletion line, in the shape git feeds `pre-push` on stdin: the local sha is all zeros because no commit is moving.
    private static func deletionLine(named name: String = "gone") -> String {
        "refs/heads/\(name) \(zeroSha) refs/heads/\(name) \(realSha)"
    }

    /// An update line: `sha` is the local commit being published — real pushes carry the checkout's own `HEAD` here, and the checkout-matches-push gate now refuses anything else, so every call site passes the subject checkout's actual `HEAD` rather than a fake sha.
    private static func updateLine(named name: String = "main", sha: String) -> String {
        "refs/heads/\(name) \(sha) refs/heads/\(name) \(zeroSha)"
    }

    /// `lines`, terminated the way git actually sends them: one per line, every line ending in a newline including the last — `while read` silently drops a final line with no trailing newline, which a real push never sends.
    private static func refLines(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    private static func checkout(in root: URL) throws -> Checkout {
        let subject = root.appending(path: "Subject")
        try FileManager.default.createDirectory(
            at: subject.appending(path: "githooks"),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: repository.appending(path: "githooks/pre-push"),
            to: subject.appending(path: "githooks/pre-push")
        )
        try TestSources.runGit(["init", "-b", "main"], in: subject)
        try TestSources.runGit(["config", "user.email", "tester@example.invalid"], in: subject)
        try TestSources.runGit(["config", "user.name", "Tester"], in: subject)
        try TestSources.write("seed\n", to: "README.md", in: subject)
        try TestSources.commitAll(in: subject, message: "seed")

        let marker = root.appending(path: "swift-ran")
        let binaries = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let stub = binaries.appending(path: "swift")
        // Never the real suite: it writes proof of its own invocation and exits, in that order, so a test
        // that only checks the exit code still cannot mistake this for a pass.
        try "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        var environment = ProcessEnvironment.withoutGit()
        environment["PATH"] = "\(binaries.path):/usr/bin:/bin"

        return Checkout(subject: subject, marker: marker, environment: environment)
    }

    /// Runs the hook over `stdin`, working directory inside the checkout, and reports its exit status.
    private static func runHook(_ stdin: String, in subject: URL, environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [subject.appending(path: "githooks/pre-push").path]
        process.currentDirectoryURL = subject
        process.environment = environment

        let input = Pipe()
        process.standardInput = input
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink

        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        _ = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return process.terminationStatus
    }

    /// A single deletion carries no commits, so both gates are skipped and the hook exits clean.
    @Test
    func aSingleDeletionSkipsBothGates() throws {
        let root = try TemporaryDirectory.make("pre-push-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)

        let status = try Self.runHook(
            Self.refLines([Self.deletionLine()]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(status == 0)
        #expect(!FileManager.default.fileExists(atPath: checkout.marker.path))
    }

    /// The same is true of several deletions together — no line among them names a commit.
    @Test
    func twoDeletionsSkipBothGates() throws {
        let root = try TemporaryDirectory.make("pre-push-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)

        let stdin = Self.refLines([Self.deletionLine(named: "one"), Self.deletionLine(named: "two")])
        let status = try Self.runHook(stdin, in: checkout.subject, environment: checkout.environment)

        #expect(status == 0)
        #expect(!FileManager.default.fileExists(atPath: checkout.marker.path))
    }

    /// A deletion beside a real update still publishes a commit, so both gates run as usual.
    @Test
    func aDeletionMixedWithAnUpdateRunsTheGates() throws {
        let root = try TemporaryDirectory.make("pre-push-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let stdin = Self.refLines([Self.deletionLine(), Self.updateLine(sha: head)])
        let status = try Self.runHook(stdin, in: checkout.subject, environment: checkout.environment)

        #expect(status != 0)
        #expect(FileManager.default.fileExists(atPath: checkout.marker.path))
    }

    /// An ordinary push of a real commit runs the gates exactly as it does today.
    @Test
    func aPlainUpdateRunsTheGates() throws {
        let root = try TemporaryDirectory.make("pre-push-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let status = try Self.runHook(
            Self.refLines([Self.updateLine(sha: head)]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(status != 0)
        #expect(FileManager.default.fileExists(atPath: checkout.marker.path))
    }

    /// A blank line is not a deletion: its local sha is empty, not forty zeros, and `*[!0]*` never matches an empty string — so beside a real deletion, an unguarded case would read `all_deletions` as still true and skip both gates on a push this malformed line gives the hook no reason to trust.
    ///
    /// It must run them instead.
    @Test
    func aBlankLineBesideADeletionRunsTheGates() throws {
        let root = try TemporaryDirectory.make("pre-push-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)

        let stdin = Self.refLines(["", Self.deletionLine()])
        let status = try Self.runHook(stdin, in: checkout.subject, environment: checkout.environment)

        #expect(status != 0)
        #expect(FileManager.default.fileExists(atPath: checkout.marker.path))
    }

    /// Empty stdin is the conservative direction: with no ref lines to read at all, the hook cannot tell this is a deletion-only push, so it runs the gates.
    @Test
    func emptyStdinRunsTheGates() throws {
        let root = try TemporaryDirectory.make("pre-push-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)

        _ = try Self.runHook("", in: checkout.subject, environment: checkout.environment)

        #expect(FileManager.default.fileExists(atPath: checkout.marker.path))
    }
}

private extension PrePushDeletionOnlyTests {
    /// A checkout carrying just the hook, and an environment whose `PATH` leads to a fake `swift` that proves whether the gates ran.
    struct Checkout {
        let subject: URL
        let marker: URL
        let environment: [String: String]
    }
}
