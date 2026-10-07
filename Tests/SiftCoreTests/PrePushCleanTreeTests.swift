//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `githooks/pre-push` runs `swift test` and the privacy gate over the working tree, not over the commit named on stdin.
///
/// It happened otherwise once: a push of a commit was refused on a red suite, an uncommitted fix followed in the same worktree, and the retried push of that same commit ran the gates over the now-green working tree and let it through, though the commit's own tree still failed.
///
/// Drives the real hook script, never a copy of its logic: a fake `swift` ahead of it on `PATH` writes a marker file and exits 1, so a run that reaches the gates is provable without ever running the real suite recursively, and a run that doesn't reach them leaves no marker at all.
@Suite(.temporaryDirectories)
struct PrePushCleanTreeTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    private static let zeroSha = String(repeating: "0", count: 40)
    private static let staleSha = String(repeating: "a", count: 40)

    /// An update line naming `sha` as the local commit being published.
    private static func updateLine(named name: String = "main", sha: String) -> String {
        "refs/heads/\(name) \(sha) refs/heads/\(name) \(zeroSha)"
    }

    /// `lines`, terminated the way git actually sends them: one per line, every line ending in a newline.
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

    /// Runs the hook over `stdin`, working directory inside the checkout, and reports what it printed alongside its exit status.
    private static func runHook(
        _ stdin: String,
        in subject: URL,
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
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
        let data = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    /// A local sha that is not this checkout's `HEAD` is refused before either gate runs: the checkout cannot prove anything about a commit it does not itself hold.
    @Test
    func aPushedShaThatIsNotHeadIsRefused() throws {
        let root = try TemporaryDirectory.make("pre-push-clean-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)

        let (status, output) = try Self.runHook(
            Self.refLines([Self.updateLine(sha: Self.staleSha)]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(status != 0)
        #expect(!FileManager.default.fileExists(atPath: checkout.marker.path))
        #expect(output.contains("pushes"))
        #expect(output.contains("this checkout is at"))
    }

    /// `HEAD` pushed, but a tracked file has been modified since: the gates would run over bytes that were never committed, so the push is refused before they start.
    @Test
    func aModifiedTrackedFileIsRefused() throws {
        let root = try TemporaryDirectory.make("pre-push-clean-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write("changed\n", to: "README.md", in: checkout.subject)

        let (status, output) = try Self.runHook(
            Self.refLines([Self.updateLine(sha: head)]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(status != 0)
        #expect(!FileManager.default.fileExists(atPath: checkout.marker.path))
        #expect(output.contains("the working tree differs from HEAD (1 changed, 0 untracked)"))
    }

    /// `HEAD` pushed, but an untracked file sits in the checkout: the gates run over the tracked tree plus whatever else is lying there, so this is refused too.
    @Test
    func anUntrackedFileIsRefused() throws {
        let root = try TemporaryDirectory.make("pre-push-clean-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write("notes\n", to: "notes.txt", in: checkout.subject)

        let (status, output) = try Self.runHook(
            Self.refLines([Self.updateLine(sha: head)]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(status != 0)
        #expect(!FileManager.default.fileExists(atPath: checkout.marker.path))
        #expect(output.contains("the working tree differs from HEAD (0 changed, 1 untracked)"))
    }

    /// `HEAD` pushed from a tree that matches it exactly: the new gate has nothing to object to, and the suite runs as before.
    @Test
    func aCleanTreeAtHeadRunsTheGates() throws {
        let root = try TemporaryDirectory.make("pre-push-clean-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try Self.runHook(
            Self.refLines([Self.updateLine(sha: head)]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(FileManager.default.fileExists(atPath: checkout.marker.path))
    }

    /// An annotated tag on `HEAD`: git hands this hook the *tag object's* sha, which peels to `HEAD`, so the push is let through.
    @Test
    func anAnnotatedTagOnHeadRunsTheGates() throws {
        let root = try TemporaryDirectory.make("pre-push-clean-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        try TestSources.runGit(["tag", "-a", "v1", "-m", "tag"], in: checkout.subject)
        let tagSha = try TestSources.runGit(["rev-parse", "v1"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try Self.runHook(
            Self.refLines(["refs/tags/v1 \(tagSha) refs/tags/v1 \(Self.zeroSha)"]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(FileManager.default.fileExists(atPath: checkout.marker.path))
    }

    /// An annotated tag on an earlier commit: it peels to that commit, not `HEAD`, so the checkout still cannot prove anything about it.
    @Test
    func anAnnotatedTagOnAnEarlierCommitIsRefused() throws {
        let root = try TemporaryDirectory.make("pre-push-clean-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        let earlier = try TestSources.runGit(["rev-parse", "HEAD"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write("second\n", to: "second.txt", in: checkout.subject)
        try TestSources.commitAll(in: checkout.subject, message: "second")
        try TestSources.runGit(["tag", "-a", "v1", "-m", "tag", earlier], in: checkout.subject)
        let tagSha = try TestSources.runGit(["rev-parse", "v1"], in: checkout.subject)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let (status, output) = try Self.runHook(
            Self.refLines(["refs/tags/v1 \(tagSha) refs/tags/v1 \(Self.zeroSha)"]),
            in: checkout.subject,
            environment: checkout.environment
        )

        #expect(status != 0)
        #expect(!FileManager.default.fileExists(atPath: checkout.marker.path))
        #expect(output.contains("pushes"))
        #expect(output.contains("this checkout is at"))
    }
}

private extension PrePushCleanTreeTests {
    /// A checkout carrying just the hook, and an environment whose `PATH` leads to a fake `swift` that proves whether the gates ran.
    struct Checkout {
        let subject: URL
        let marker: URL
        let environment: [String: String]
    }
}
