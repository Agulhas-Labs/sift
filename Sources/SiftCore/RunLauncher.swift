//
// Copyright © Agulhas Labs
//

import Foundation

/// Runs a wrapped toolchain command, tees its output to the raw log, and filters it when the command is one this tool knows.
///
/// stdout and stderr share one pipe, exactly as `2>&1` does: the kernel then orders the two streams as the tool wrote them, which is what keeps a multi-line linker block contiguous and makes the log a faithful transcript rather than an approximate merge.
public struct RunLauncher: Sendable {
    private let workingDirectory: URL
    /// The repository root when the caller has already looked for it — `.some(nil)` for a directory in no repository — so one run asks git for it once.
    private let knownRoot: URL??
    /// Where this run's transcript is written, when that is not the directory the command runs in.
    ///
    /// `nil` — every real invocation — files the transcript under the working directory, which is what makes `sift run` leave a receipt in the repository it just ran in. A caller driving this launcher *inside* another repository's test process is not a real invocation: it inherits that process's working directory and would otherwise write into, and prune, a run log that is nothing to do with it.
    private let runLogDirectory: URL?

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
        knownRoot = nil
        runLogDirectory = nil
    }

    /// A launcher for a directory whose repository root — or the absence of one — the caller has already found, writing its transcript under `runLogDirectory` where the caller names one.
    public init(workingDirectory: URL, repositoryRoot: URL?, runLogDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory
        knownRoot = .some(repositoryRoot)
        self.runLogDirectory = runLogDirectory
    }
}

extension RunLauncher {
    /// Runs `arguments`, calling `sink` with each raw chunk when nothing is being filtered.
    ///
    /// The command is launched through `/usr/bin/env` so a bare name resolves on `PATH` and a missing one exits 127 the way a shell would, rather than throwing where the exit code is the contract.
    ///
    /// `children`, when given, starts the command as one of a set-aside's children — in a session of its own, announced to the watcher before it runs, with `/dev/null` for its input — so that neither it nor anything it starts can outlive a run killed outright and write into a tree already put back. `launched` is handed its process id, which is also its session's. `environment` is what the command is given, and is this process's own unless the caller says otherwise.
    ///
    /// **The wrapped command's environment is otherwise unchanged** — see ``ProcessEnvironment/withoutGit(from:)``. It is the caller's own command, run exactly as their shell would have run it; this tool's own git reads carry `GIT_OPTIONAL_LOCKS=0` themselves (``GitContext/readEnvironment()``), but forcing it onto the wrapped command too would mask a regression in the command's own git usage under a green `sift run`.
    ///
    /// Reading the event stream asks a `swift test` that executes tests for its Swift Testing event stream as well, in a file under `.sift/` removed once it is read, and reads the endings and failing tests its console lost from it (see ``RunEventStreamFold``). Only the command started carries the option: its recognition, its filter and the key it is filed under are all read from `arguments` as the caller wrote them.
    ///
    /// `progress`, when given, is begun before the command starts and fed every chunk of its output beside the filter; the caller ends it with sift's own exit code once that is known, and resets it on any path that throws.
    public func run(
        _ arguments: [String],
        passingThrough sink: ((Data) -> Void)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        children: SetAsideChildren? = nil,
        readingEventStream: Bool = false,
        progress: RunProgress? = nil,
        launched: ((Int32) -> Void)? = nil
    ) throws -> RunOutcome {
        guard !arguments.isEmpty else {
            throw RunError.nothingToRun
        }
        // The root is resolved before the command is recognised, not after: the extra linter names live in
        // the repository's config, so recognition here is the one place that can read them, and every other
        // caller of `recognize` reads argv alone.
        let repositoryRoot = knownRoot ?? GitContext.discoverRoot(from: workingDirectory)
        let linters = RunCommandKind.configuredLinters(inRepositoryAt: repositoryRoot)
        let kind = RunCommandKind.recognize(arguments, linters: linters)
        // `run` is the one entry point that writes into `.sift/` without building an engine, so a repo
        // that has never been indexed would otherwise gain an untracked transcript with no ignore coverage.
        // The same exclusion the engine applies, called rather than restated.
        if let repositoryRoot {
            GitContext(repoRoot: repositoryRoot).ensureCacheExcluded()
        }
        // The option is asked of the command that will run, never of `PATH`'s `swift`: the caller may have named
        // another toolchain's, and one that does not know the option fails the run it is given to.
        let streams = readingEventStream && Self.asksForEventStream(arguments, kind: kind)
            ? EventStreamDirectory.make(
                in: repositoryRoot ?? workingDirectory,
                for: "run-events",
                asking: Self.testCommand(of: arguments),
                from: workingDirectory,
                environment: environment
            ) : nil
        defer {
            streams?.remove()
        }
        let started = streams.map { Self.arguments(arguments, writingTo: $0) } ?? arguments
        let log = RunLog.open(inDirectory: runLogDirectory ?? workingDirectory)
        progress?.begin(arguments, kind: kind, logPath: log?.partURL.path)
        let pipe = Pipe()
        let finish: () -> Int32
        if let children {
            let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
            defer { close(null) }
            let writer = pipe.fileHandleForWriting.fileDescriptor
            let pid = try children.spawn(
                "/usr/bin/env",
                started,
                in: workingDirectory,
                environment: environment,
                streams: SetAsideChildren.Streams(input: null, output: writer, error: writer),
                forwardingSignals: true
            )
            try? pipe.fileHandleForWriting.close()
            launched?(pid)
            finish = { SetAsideChildren.exitCode(waitingFor: pid) }
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = started
            process.currentDirectoryURL = workingDirectory
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                ProcessStreams.abandon(pipe)
                throw error
            }
            launched?(process.processIdentifier)
            finish = {
                process.waitUntilExit()
                return exitCode(of: process)
            }
        }

        // A command this tool does not wrap has no contract, and the filter is never fed one line of its
        // output — but `.unreadable` is what that has to mean if it ever were, since a contract with
        // nothing owed accepts whichever verdict literal the log carries. The same argv says whether
        // `xcodebuild` was asked for `-quiet`, the one invocation whose clean run prints no verdict at all.
        var filter = RunOutputFilter(invokedAs: arguments, linters: linters)
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty {
                break
            }
            log?.append(chunk)
            progress?.consume(chunk)
            if kind.isFiltered {
                filter.consume(chunk)
            } else {
                sink?(chunk)
            }
        }
        try? reader.close()
        let code = finish()
        log?.close()
        progress?.endOutput()
        if let stream = streams?.read(Self.eventStreamFile) {
            filter.read(eventStream: ShardEventStream.read(stream))
        }

        return RunOutcome(
            kind: kind,
            logKey: RunCommandKind.logKey(of: arguments),
            exitCode: code,
            report: kind.isFiltered ? filter.finish(exitCode: code) : nil,
            log: log,
            repositoryRoot: repositoryRoot
        )
    }

    /// A signalled child has no exit status of its own, so it reports the shell's `128 + signal` instead.
    private func exitCode(of process: Process) -> Int32 {
        process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    }
}

extension RunLauncher {
    /// The file a run's event stream is written to, in a directory of that run's own.
    static var eventStreamFile: String {
        "events.jsonl"
    }

    /// Whether a run of `arguments` is one whose event stream is asked for: a `swift test` that executes tests, is not `swift test list`, and names no stream of the caller's own, which is theirs to read.
    static func asksForEventStream(_ arguments: [String], kind: RunCommandKind) -> Bool {
        guard kind == .swiftTest, RunCommandKind.executesTests(arguments), let test = arguments.dropFirst().firstIndex(of: "test") else {
            return false
        }
        guard RunCommandKind.testSubcommand(of: arguments[(test + 1)...]) != "list" else {
            return false
        }
        return !arguments.contains { argument in
            SuiteSpans.outputOptions.contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }
    }

    /// The part of `arguments` that names the `swift test` itself — everything up to and including `test` — which is what its options are asked of.
    static func testCommand(of arguments: [String]) -> [String] {
        guard let test = arguments.dropFirst().firstIndex(of: "test") else {
            return arguments
        }
        return Array(arguments[...test])
    }

    /// `arguments` with the option writing `streams`' run stream inserted straight after `test`, ahead of any `--` that hands the rest to the test binary.
    static func arguments(_ arguments: [String], writingTo streams: EventStreamDirectory) -> [String] {
        guard let test = arguments.dropFirst().firstIndex(of: "test") else {
            return arguments
        }
        var started = arguments
        started.insert(contentsOf: streams.arguments(writing: eventStreamFile), at: test + 1)
        return started
    }
}
