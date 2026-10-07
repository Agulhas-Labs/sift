//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Where `sift` is installed, `githooks/pre-push` never runs the suite inside the push unless asked: a tree the ledger has not proved is refused at once.
///
/// git opens its connection to the remote before the hook runs, and a suite of several minutes outlives it: pushes ran the suite to green and then died with the connection closed, so the refusal is what saves the wall clock. `SIFT_PRE_PUSH_RUN=1` restores the in-push run. Drives the real hook with stand-ins for `sift` and `swift` that write a marker when a suite starts, so a suite that ran is provable without running any real one.
@Suite(.temporaryDirectories)
struct PrePushUnprovedTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    /// What the stand-in `sift` says to `run --proved` before exiting 1, so the test can see the hook pass it on.
    private static var ledgerExplanation: String {
        "✘ not proved — the tree differs from the last green run"
    }

    /// What the stand-in `sift` says to `run --proved` before exiting 2 — the ledger switched off, a question a run can never turn into a record.
    private static var cannotTellExplanation: String {
        "✘ not proved — the ledger is switched off here (SIFT_RUN_LEDGER=0)"
    }

    /// The line the hook leads its refusal with.
    private static var refusal: String {
        "no proved run for this tree — run  sift run -- swift test  then push again (the push answers from that run in seconds; or SIFT_PRE_PUSH_RUN=1 to run the suite in this push)"
    }

    /// A committed checkout carrying the hook and a privacy gate that passes, with stand-ins for `sift` and `swift` first on `PATH`.
    private static func checkout(in root: URL) throws -> UnprovedCheckout {
        let subject = root.appending(path: "Subject")
        try FileManager.default.createDirectory(at: subject.appending(path: "githooks"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repository.appending(path: "githooks/pre-push"),
            to: subject.appending(path: "githooks/pre-push")
        )
        try TestSources.write("#!/bin/sh\nexit 0\n", to: "Distribution/verify-tree.sh", in: subject)
        try TestSources.runGit(["init", "-b", "main"], in: subject)
        try TestSources.runGit(["config", "user.email", "tester@example.invalid"], in: subject)
        try TestSources.runGit(["config", "user.name", "Tester"], in: subject)
        try TestSources.write("seed\n", to: "README.md", in: subject)
        try TestSources.commitAll(in: subject, message: "seed")

        let marker = root.appending(path: "suite-ran")
        let binaries = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        // `run --help` names the flag, as a binary with the ledger does; `run --proved` explains and exits 1,
        // as the ledger does for a tree it has no green run of, or 2 when SIFT_RUN_LEDGER=0 leaves the
        // question unable to be put at all; any other `run` is the suite starting.
        let sift = """
        #!/bin/sh
        case "$2" in
            --help) echo -- --proved; exit 0 ;;
            --proved)
                if [ "${SIFT_RUN_LEDGER:-}" = "0" ]; then
                    echo "\(cannotTellExplanation)"; exit 2
                fi
                echo "\(ledgerExplanation)"; exit 1
                ;;
        esac
        touch "\(marker.path)"
        exit 0

        """
        let swift = "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n"
        for (name, script) in [("sift", sift), ("swift", swift)] {
            let url = binaries.appending(path: name)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        var environment = ProcessEnvironment.withoutGit()
        environment["PATH"] = "\(binaries.path):/usr/bin:/bin"
        // Either switch inherited from whoever runs the suite would choose the branch this test is about.
        environment["SIFT_PRE_PUSH_RUN"] = nil
        environment["SIFT_PRE_PUSH_RAW"] = nil
        return UnprovedCheckout(subject: subject, marker: marker, environment: environment)
    }

    /// Runs the hook with nothing on stdin — the conservative reading, which runs the gates — and reports its exit status and everything it printed.
    private static func runHook(in subject: URL, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [subject.appending(path: "githooks/pre-push").path]
        process.currentDirectoryURL = subject
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
    }

    /// An unproved tree is refused before any suite starts: the refusal leads, the ledger's explanation follows it, and the push fails.
    @Test
    func anUnprovedTreeIsRefusedWithoutRunningTheSuite() throws {
        let root = try TemporaryDirectory.make("pre-push-unproved")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)

        let run = try Self.runHook(in: checkout.subject, environment: checkout.environment)

        #expect(run.status == 1)
        #expect(!FileManager.default.fileExists(atPath: checkout.marker.path), "a suite started inside the push")
        let lines = run.output.split(separator: "\n").map(String.init)
        let refused = try #require(lines.firstIndex(of: Self.refusal), "no refusal line in: \(run.output)")
        #expect(lines.dropFirst(refused + 1).first == Self.ledgerExplanation)
        #expect(!run.output.contains("==== privacy gate ===="))
    }

    /// `SIFT_PRE_PUSH_RUN=1` puts the suite back inside the push for an unproved tree, and a green suite lets the push through.
    @Test
    func theOptInRunsTheSuiteInsideThePush() throws {
        let root = try TemporaryDirectory.make("pre-push-unproved")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        var environment = checkout.environment
        environment["SIFT_PRE_PUSH_RUN"] = "1"

        let run = try Self.runHook(in: checkout.subject, environment: environment)

        #expect(run.status == 0, "\(run.output)")
        #expect(FileManager.default.fileExists(atPath: checkout.marker.path), "the opt-in did not run the suite")
        #expect(!run.output.contains(Self.refusal))
        #expect(run.output.contains(Self.ledgerExplanation))
    }

    /// A tree the ledger cannot even ask about (`SIFT_RUN_LEDGER=0`) runs the suite inside the push rather than being refused: a run can never turn this into a record, so refusing would refuse forever with advice that cannot help.
    @Test
    func aTreeTheLedgerCannotAskAboutRunsTheSuiteInsideThePush() throws {
        let root = try TemporaryDirectory.make("pre-push-unproved")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try Self.checkout(in: root)
        var environment = checkout.environment
        environment["SIFT_RUN_LEDGER"] = "0"

        let run = try Self.runHook(in: checkout.subject, environment: environment)

        #expect(run.status == 0, "\(run.output)")
        #expect(FileManager.default.fileExists(atPath: checkout.marker.path), "the ledger being off did not run the suite")
        #expect(!run.output.contains(Self.refusal))
        #expect(run.output.contains(Self.cannotTellExplanation))
    }
}

private extension PrePushUnprovedTests {
    /// A checkout carrying the hook, the marker a started suite leaves, and an environment leading to the stand-ins.
    struct UnprovedCheckout {
        let subject: URL
        let marker: URL
        let environment: [String: String]
    }
}
