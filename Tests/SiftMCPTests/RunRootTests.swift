//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `sift run --root <dir>` is a run started in that directory, with the caller's own directory untouched.
///
/// Every test spawns the built binary: a change of directory inside the test process would move every test running beside it.
@Suite(.temporaryDirectories)
struct RunRootTests {
    private static var passingTranscript: String {
        """
        ◇ Test run started.
        ✔ Test aTest() passed after 0.001 seconds.
        ✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
        """
    }

    /// The command sees the named directory as both its working directory and its `$PWD`.
    @Test
    func theCommandRunsInTheNamedDirectoryWithPWDNamingIt() throws {
        let started = try TemporaryDirectory.make("run-root-started")
        defer { try? FileManager.default.removeItem(at: started) }
        let target = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: target) }

        let expected = try Self.spawn("/bin/sh", ["-c", "cd \"$1\" && pwd -P", "_", target.path], in: started, isolated: false)
        let physical = expected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try Self.sift(["run", "--root", target.path, "--", "/bin/sh", "-c", "printf '%s\\n' \"$PWD\"; pwd -P"], in: started)

        #expect(result.status == 0)
        #expect(!physical.isEmpty)
        let lines = result.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("sift run:") }
        #expect(lines == [target.path, physical])
    }

    /// A directory named through a symbolic link is the command's `$PWD` as spelled, as after a shell `cd`, while its working directory is the physical one.
    @Test
    func pwdKeepsTheSymbolicLinkSpellingOfTheNamedDirectory() throws {
        let started = try TemporaryDirectory.make("run-root-link")
        defer { try? FileManager.default.removeItem(at: started) }
        let target = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: target) }
        let link = started.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try Self.sift(["run", "--root", link.path, "--", "/bin/sh", "-c", "echo $PWD; pwd -P"], in: started)

        #expect(result.status == 0, "\(result.output)")
        let lines = result.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("sift run:") }
        #expect(lines.first == link.path)
        #expect(lines.count == 2)
        #expect(lines.last != link.path)
    }

    /// A `--restore` under `--root` puts back the named repository's set-aside work, and the caller's own stays out.
    @Test
    func aRestoreUnderRootActsOnTheNamedRepositoryAlone() throws {
        let caller = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: caller) }
        let target = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: target) }
        for repository in [caller, target] {
            let file = repository.appendingPathComponent("feature.txt")
            try "committed\n".write(to: file, atomically: true, encoding: .utf8)
            for arguments in [["add", "feature.txt"], ["commit", "-m", "feature"]] {
                let result = try Self.spawn("/usr/bin/git", arguments, in: repository, isolated: false)
                #expect(result.status == 0, "\(arguments.joined(separator: " ")): \(result.output)")
            }
            try "changed\n".write(to: file, atomically: true, encoding: .utf8)
            // What a run leaves when it and its watcher were both killed: a record, the work set aside.
            let store = SetAsideStore(repositoryRoot: repository)
            let record = try SetAside.capture(pathspecs: ["feature.txt"], from: repository, into: store)
            guard case .setAside = try SetAside(store: store).setAside(record) else {
                Issue.record("the set-aside stopped part-way")
                return
            }
        }

        let result = try Self.sift(["run", "--root", target.path, "--restore"], in: caller)

        #expect(result.status == 0, "\(result.output)")
        #expect((try? String(contentsOf: target.appendingPathComponent("feature.txt"), encoding: .utf8)) == "changed\n")
        #expect((try? String(contentsOf: caller.appendingPathComponent("feature.txt"), encoding: .utf8)) == "committed\n")
        #expect(SetAsideSession.refusal(for: target) == nil)
        #expect(SetAsideSession.refusal(for: caller) != nil)
    }

    /// A green run started elsewhere is the named checkout's proof, and files its log there alone.
    @Test
    func aGreenRunFromElsewhereProvesTheNamedCheckout() throws {
        let started = try TemporaryDirectory.make("run-root-elsewhere")
        defer { try? FileManager.default.removeItem(at: started) }
        let target = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: target) }
        let tools = try TemporaryDirectory.make("run-root-tools")
        defer { try? FileManager.default.removeItem(at: tools) }
        let swift = tools.appendingPathComponent("swift")
        let payload = tools.appendingPathComponent("transcript.txt")
        try Self.passingTranscript.write(to: payload, atomically: true, encoding: .utf8)
        try "#!/bin/sh\ncat '\(payload.path)'\nexit 0\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        let green = try Self.sift(["run", "--root", target.path, "--", swift.path, "test"], in: started)
        let asked = try Self.sift(["run", "--proved", "--", swift.path, "test"], in: target)

        #expect(green.status == 0)
        #expect(asked.status == 0)
        let runs = target.appendingPathComponent(".sift/runs")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []).isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: started.appendingPathComponent(".sift").path))
    }

    /// A directory that does not exist is a usage error, said before the command runs.
    @Test
    func aMissingDirectoryIsAUsageError() throws {
        let started = try TemporaryDirectory.make("run-root-missing")
        defer { try? FileManager.default.removeItem(at: started) }

        let result = try Self.sift(["run", "--root", started.appendingPathComponent("missing").path, "--", "/usr/bin/true"], in: started)

        #expect(result.status == 64)
        #expect(result.output.contains("sift run --root: "))
        #expect(result.output.contains("is not a directory"))
        #expect(result.output.contains(started.appendingPathComponent("missing").path))
    }

    /// A `--root` after the terminator belongs to the command, which cannot take it, so it is refused before anything runs.
    @Test
    func aRootAfterTheTerminatorIsAUsageError() throws {
        let started = try TemporaryDirectory.make("run-root-late")
        defer { try? FileManager.default.removeItem(at: started) }

        let result = try Self.sift(["run", "--", "--root", started.path, "/usr/bin/true"], in: started)

        #expect(result.status == 64)
        #expect(result.output.contains("--root goes before the command"))
    }

    /// A `--without` under `--root` sets aside in the named repository, and the caller's own is never touched.
    @Test
    func aSetAsideUnderRootIsInTheNamedRepositoryAlone() throws {
        let caller = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: caller) }
        let target = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: target) }
        let tools = try TemporaryDirectory.make("run-root-tools")
        defer { try? FileManager.default.removeItem(at: tools) }
        let log = tools.appendingPathComponent("seen.log")
        for repository in [caller, target] {
            let file = repository.appendingPathComponent("feature.txt")
            try "committed\n".write(to: file, atomically: true, encoding: .utf8)
            for arguments in [["add", "feature.txt"], ["commit", "-m", "feature"]] {
                let result = try Self.spawn("/usr/bin/git", arguments, in: repository, isolated: false)
                #expect(result.status == 0, "\(arguments.joined(separator: " ")): \(result.output)")
            }
            try "changed\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let swift = tools.appendingPathComponent("swift")
        let script = """
        #!/bin/sh
        printf 'caller=%s target=%s\\n' "$(cat '\(caller.path)/feature.txt')" "$(cat '\(target.path)/feature.txt')" >> '\(log.path)'
        printf '%s\\n' '◇ Test run started.' '✔ Test aTest() passed after 0.001 seconds.' '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'
        exit 0

        """
        try script.write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        _ = try Self.sift(["run", "--root", target.path, "--without", "feature.txt", "--", swift.path, "test", "--filter", "aTest"], in: caller)

        let seen = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(seen.contains("caller=changed target=committed"))
        #expect(!seen.contains("caller=committed"))
        for repository in [caller, target] {
            #expect((try? String(contentsOf: repository.appendingPathComponent("feature.txt"), encoding: .utf8)) == "changed\n")
        }
    }

    /// `--root ..` from a symbolic-linked directory lands in its logical parent, as after a shell `cd ..`.
    @Test
    func dotDotFromALinkedDirectoryLandsInTheLogicalParent() throws {
        let base = try TemporaryDirectory.make("run-root-dotdot")
        defer { try? FileManager.default.removeItem(at: base) }
        let link = try Self.makeLinkedChild(in: base)

        let result = try Self.sift(["run", "--root", "..", "--", "/bin/sh", "-c", "pwd -P"], in: link, pwd: link.path)

        #expect(result.status == 0, "\(result.output)")
        #expect(Self.commandLines(result) == [Self.physical(base)])
    }

    /// `--root link/..` lands in the directory holding `link`, as after a shell `cd link/..`.
    @Test
    func aDotDotAfterALinkLandsInTheLinksParent() throws {
        let base = try TemporaryDirectory.make("run-root-linkdotdot")
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try Self.makeLinkedChild(in: base)

        let result = try Self.sift(["run", "--root", "link/..", "--", "/bin/sh", "-c", "pwd -P"], in: base, pwd: base.path)

        #expect(result.status == 0, "\(result.output)")
        #expect(Self.commandLines(result) == [Self.physical(base)])
    }

    /// A plain relative directory still lands in it, and a path naming no directory is still refused.
    @Test
    func aPlainRelativeRootStillLandsThereAndAMissingOneIsRefused() throws {
        let base = try TemporaryDirectory.make("run-root-plain")
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try Self.makeLinkedChild(in: base)

        let landed = try Self.sift(["run", "--root", "real", "--", "/bin/sh", "-c", "pwd -P"], in: base, pwd: base.path)
        let refused = try Self.sift(["run", "--root", "link/../missing", "--", "/usr/bin/true"], in: base, pwd: base.path)

        #expect(landed.status == 0, "\(landed.output)")
        #expect(Self.commandLines(landed) == [Self.physical(base) + "/real"])
        #expect(refused.status == 64)
        #expect(refused.output.contains("sift run --root: link/../missing is not a directory."))
    }
}

private extension RunRootTests {
    /// `real/child` and a symbolic link `link` to it, in `base`; returns the link.
    static func makeLinkedChild(in base: URL) throws -> URL {
        let child = base.appendingPathComponent("real/child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        return link
    }

    static func physical(_ url: URL) -> String {
        url.path.withCString { path in
            realpath(path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? url.path
        }
    }

    static func commandLines(_ result: (status: Int32, output: String)) -> [String] {
        result.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("sift run:") }
    }
}

private extension RunRootTests {
    static func sift(_ arguments: [String], in directory: URL, pwd: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, output: String) {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
        return try spawn(binary.path, arguments, in: directory, isolated: true, pwd: pwd)
    }

    /// One process in `directory`, with no git variables; an isolated one also gets its own home and the ledger switched on.
    static func spawn(_ executable: String, _ arguments: [String], in directory: URL, isolated: Bool, pwd: String? = nil) throws -> (status: Int32, output: String) {
        let home = try TemporaryDirectory.make("run-root-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessEnvironment.withoutGit()
        if isolated {
            environment[RunLedger.switchName] = nil
            environment["SIFT_HOME"] = home.path
            environment["CLAUDE_CODE_SESSION_ID"] = nil
        }
        if let pwd {
            environment["PWD"] = pwd
        }
        process.environment = environment
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
    }

    /// A disposable, freshly committed repository.
    static func makeRepository(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try TemporaryDirectory.make("run-root-repo")
        try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for arguments in [
            ["init", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Tester"],
            ["add", "-A"],
            ["commit", "-m", "seed"],
        ] {
            let result = try spawn("/usr/bin/git", arguments, in: root, isolated: false)
            #expect(result.status == 0, "\(arguments.joined(separator: " ")): \(result.output)", sourceLocation: sourceLocation)
        }
        return root
    }
}
