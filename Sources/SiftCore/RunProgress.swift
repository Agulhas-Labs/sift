//
// Copyright © Agulhas Labs
//

import Foundation

/// One wrapped run's live progress file: a ``RunLiveTally`` reading the run's output and a ``RunProgressWriter`` keeping `.sift/progress/` current from what it reads.
///
/// ``RunLauncher`` drives it from the loop that reads the command's output, on that loop's thread; only ``writer`` is ever reached from anywhere else, by a signal source ending the run. Nothing here can fail a run: the writer drops a write it cannot make, and nothing is printed.
public final class RunProgress {
    /// The writer, which a signal source's handler ends the run through when a signal ends it first.
    public let writer: RunProgressWriter
    private let repositoryRoot: URL
    private let tree: String?
    private var tally: RunLiveTally?

    /// Progress for a run in `repositoryRoot`, kept by `writer`, on the tree `tree` keys.
    init(repositoryRoot: URL, writer: RunProgressWriter, tree: String? = nil) {
        self.repositoryRoot = repositoryRoot
        self.tree = tree
        self.writer = writer
    }

    /// The environment variable that turns the progress file off: `off` and no run writes one.
    public static var switchName: String {
        "SIFT_PROGRESS"
    }

    /// Progress for a run in the repository at `repositoryRoot`, written under `writesUnder` where a test or probe scoped the run's writes there, as the run log is; `nil` where there is no repository to file it under or `environment` switches it off.
    ///
    /// `tree` is the key of the tree the run starts on, which the file carries so a reader can tell a run of the tree it is judging from a run of an earlier one; pass it only for a run that builds or tests the repository the file is filed under.
    public static func forRun(in repositoryRoot: URL?, writesUnder: URL?, environment: [String: String], tree: String? = nil) -> RunProgress? {
        guard let repositoryRoot, environment[switchName] != "off" else {
            return nil
        }
        let directory = RunProgressPaths.directory(in: repositoryRoot, writesUnder: writesUnder)
        return RunProgress(repositoryRoot: repositoryRoot, writer: RunProgressWriter(directory: directory), tree: tree)
    }

    /// Starts the run's file: `arguments` as the command, the scheme and destination an `xcodebuild` line names, and the log being written.
    func begin(_ arguments: [String], kind: RunCommandKind, logPath: String?) {
        tally = RunLiveTally(startedAt: Date())
        writer.begin(
            command: Self.command(arguments),
            repoRoot: repositoryRoot,
            scheme: Self.option("-scheme", of: arguments, kind: kind),
            destination: Self.option("-destination", of: arguments, kind: kind),
            logPath: logPath,
            tree: tree
        )
    }

    /// Reads a chunk of the run's output, the same chunk the filter is given, and hands the writer where the run has got to.
    func consume(_ chunk: Data) {
        // Mutated where it is stored: a copy taken here would copy every dictionary and the partial line it holds on each chunk.
        tally?.consume(chunk, now: Date())
        if let state = tally?.state {
            publish(state)
        }
    }

    /// Reads the line the output ended on without a newline, once the command has exited; the run is not ended here, since only the caller knows the exit code sift itself will give.
    func endOutput() {
        _ = tally?.finish(now: Date())
        if let tally {
            publish(tally.state)
        }
    }

    /// Ends the run's file with sift's own exit code, `done` for 0 and `failed` otherwise, naming the log where it stands once the run is over.
    ///
    /// The tally's own split of the time is not used: the writer times each phase from the changes it was handed, which leaves a run that never built or tested with no build or test time rather than all of it as build time.
    public func finish(exitCode: Int32, logPath: String?) {
        writer.update { $0.logPath = logPath }
        writer.finish(exitCode: exitCode)
    }

    private func publish(_ state: RunLiveState) {
        writer.update { snapshot in
            snapshot.phase = Self.phase(of: state)
            snapshot.current = state.current
            snapshot.tests.passed = state.tests.passed
            snapshot.tests.failed = state.tests.failed
            snapshot.tests.skipped = state.tests.skipped
            snapshot.errors = state.errors
            snapshot.warnings = state.warnings
        }
    }

    /// The file's phase for `state`: the tally starts out building, but the file says `idle` until a line names a build step or prints a step counter, so a command that neither builds nor tests stays idle.
    static func phase(of state: RunLiveState) -> RunProgressSnapshot.Phase {
        switch state.phase {
        case .testing: .testing
        case .building: state.current == nil && !state.buildStarted ? .idle : .building
        }
    }

    /// `arguments` on one line, each word as a shell would read it back.
    static func command(_ arguments: [String]) -> String {
        arguments.map(ShellWord.quoted).joined(separator: " ")
    }

    /// The value `name` is given in an `xcodebuild` line (`-scheme Gizmo`), or `nil` for any other command or a line that does not give it.
    static func option(_ name: String, of arguments: [String], kind: RunCommandKind) -> String? {
        guard kind == .xcodebuild, let index = arguments.firstIndex(of: name), index + 1 < arguments.endIndex else {
            return nil
        }
        return arguments[index + 1]
    }
}
