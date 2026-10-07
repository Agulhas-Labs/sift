//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `githooks/pre-push` says when the connection git opened for the push closed while the gates ran.
///
/// git opens that connection before it runs the hook, and one that closes meanwhile turns a passing hook into a push that dies of SIGPIPE, exit 141, with nothing said.
///
/// Drives a real `git push` through the real hook, over an `ssh` stand-in that runs `git-receive-pack` on a local bare repository. The suite is a fake `swift` on `PATH` — the one that closes the connection ends the transport git started before exiting 0, which is the shape of a long suite outliving the connection — and the tree gate is a stand-in that passes, so everything the hook decides after the gates is what is under test.
@Suite(.temporaryDirectories)
struct PrePushTransportTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    /// The line the hook prints when the transport it noted has gone.
    private static var closedMessage: String {
        "the connection git opened to the remote closed while they ran"
    }

    /// A connection that closes while the suite runs is named, and nothing reaches the remote.
    @Test
    func aTransportThatClosesWhileTheGatesRunIsSaid() throws {
        let root = try TemporaryDirectory.make("pre-push-transport")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.fixture(in: root, suite: Self.suiteThatClosesTheTransport)

        let push = try Self.push(fixture)

        #expect(push.status != 0)
        #expect(push.output.contains(Self.closedMessage), "\(push.output)")
        #expect(try !Self.remoteHasMain(fixture))
    }

    /// A connection still open once the gates pass is left alone: the push lands and the hook says nothing about it.
    @Test
    func aTransportStillOpenLetsThePushLand() throws {
        let root = try TemporaryDirectory.make("pre-push-transport")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.fixture(in: root, suite: "#!/bin/sh\nexit 0\n")

        let push = try Self.push(fixture)

        #expect(push.status == 0, "\(push.output)")
        #expect(!push.output.contains(Self.closedMessage))
        #expect(try Self.remoteHasMain(fixture))
    }
}

private extension PrePushTransportTests {
    /// A `swift` that ends every process its grandparent — git — started besides the hook, waits until each has exited, and passes.
    static var suiteThatClosesTheTransport: String {
        """
        #!/bin/sh
        hook=$PPID
        git=$(ps -o ppid= -p "$hook" | tr -d ' ')
        ended=""
        for pid in $(pgrep -P "$git"); do
            [ "$pid" = "$hook" ] && continue
            kill "$pid"
            ended="$ended $pid"
        done
        for pid in $ended; do
            tries=0
            while [ "$tries" -lt 100 ]; do
                case "$(ps -o stat= -p "$pid" 2>/dev/null || true)" in
                    "" | Z*) break ;;
                esac
                tries=$((tries + 1))
                sleep 0.05
            done
        done
        exit 0

        """
    }

    static func fixture(in root: URL, suite: String) throws -> Fixture {
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

        let remote = root.appending(path: "Remote.git")
        try TestSources.runGit(["init", "--bare", remote.path], in: root)

        let binaries = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        // git calls it as `<ssh> [options] <host> <command>`: the command is the last argument.
        let ssh = "#!/bin/sh\nwhile [ $# -gt 1 ]; do shift; done\nexec sh -c \"$1\"\n"
        for (name, script) in [("ssh", ssh), ("swift", suite)] {
            let url = binaries.appending(path: name)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        var environment = ProcessEnvironment.withoutGit()
        environment["PATH"] = "\(binaries.path):/usr/bin:/bin"
        environment["GIT_SSH_COMMAND"] = binaries.appending(path: "ssh").path
        return Fixture(subject: subject, remote: remote, environment: environment)
    }

    /// Pushes `main` over the `ssh` stand-in, through the hook, and reports git's exit status and everything it and the hook printed.
    static func push(_ fixture: Fixture) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=\(fixture.subject.appending(path: "githooks").path)",
            "push", "ssh://stand-in\(fixture.remote.path)", "main",
        ]
        process.currentDirectoryURL = fixture.subject
        process.environment = fixture.environment
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
    }

    static func remoteHasMain(_ fixture: Fixture) throws -> Bool {
        let heads = try TestSources.runGit(["for-each-ref", "refs/heads"], in: fixture.remote)
        return heads.contains("refs/heads/main")
    }

    /// The checkout that pushes, the bare repository it pushes to, and the environment that routes `ssh` and `swift` to their stand-ins.
    struct Fixture {
        let subject: URL
        let remote: URL
        let environment: [String: String]
    }
}
