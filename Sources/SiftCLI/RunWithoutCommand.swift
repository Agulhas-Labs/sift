//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `run --without <pathspec> [--since <rev>] -- <tests>`: the named tests with the changes under the pathspec set aside — the uncommitted ones, or those the commits since a revision made — then again with them back, and one line per test on which way each went; and `run --restore`, which puts back a set-aside whose run is gone.
///
/// The order of the steps is the safety argument. The record is on disk before anything else happens; the watcher is confirmed running before the tree is touched; every child is announced to it before it runs; the first run's leftovers are ended and the tree put back and checked before the second run starts; the lock is held until the second run is over; and the only other place the tree is put back is the signal handler, which goes through the same session and so can never race this flow over the index.
///
/// **The exit code is the answer's, for a script to act on** — see ``Exit``. It is not the second run's: a script that runs `sift run --without … && …` has to be able to tell a proof from a test that merely passed, and "your work is not back in the tree" from either.
struct RunWithoutCommand {
    /// The wrapped command, without the terminator.
    let arguments: [String]
    /// What `--without` named, as the caller wrote it.
    let pathspecs: [String]
    /// What `--without-line` named, split into the file as the caller wrote it and its line: set, the run comments that one line out instead of setting aside a pathspec's changes.
    let line: (path: String, number: Int)?
    /// What `--since` named, as the caller wrote it: the run then sets aside the change committed on top of it instead of the one in the tree.
    let since: String?
    /// The tree and command a run starts on, taken the way `RunCommand` takes them, so the run with the change is keyed as a plain run would be.
    let runKey: (URL) -> TreeContentHash.RunKey?
    /// Files the run with the change in the per-user run log: `RunCommand`'s own filing, handed in so a run is filed one way whichever path ran it.
    let file: (RunOutcome, Int, Int, TreeContentHash.RunKey?) -> Void

    func run(in workingDirectory: URL) throws {
        let commit: String?
        do {
            try RunWithoutArguments.check(arguments, pathspecs: pathspecs, workingDirectory: workingDirectory, flag: line == nil ? "--without" : "--without-line")
            // Resolved here, before the record and before the lock: a revision git cannot name is the
            // caller's mistake, and nothing of theirs has been touched when they are told so.
            commit = try RunWithoutArguments.revision(since, pathspecs: pathspecs, workingDirectory: workingDirectory)
        } catch let error as RunWithoutError {
            throw ValidationError(error.description)
        }
        // Before anything is read for the record: a tree nobody may write has no `.sift/` to hold the set-aside, and the lock's own error is the platform's.
        if let root = GitContext.discoverRoot(from: workingDirectory) {
            do {
                try TreeWritability.requireSetAsideStore(repoRoot: root)
            } catch {
                StandardStreams.emitError("\(error)")
                throw Exit.refused.code
            }
        }
        // Read before the session begins: once the pathspec's files are the committed versions, a pathspec
        // covering the tests would make the working tree lie about which tests the change wrote.
        let changedTests = ChangedTests.identifiers(since: commit, in: workingDirectory)
        guard let executable = Bundle.main.executableURL else {
            StandardStreams.emitError(SetAsideError.guardUnavailable("this process cannot name its own executable").description)
            throw Exit.refused.code
        }
        // Armed before the changes are recorded, so an interruption while a large capture copies them ends it
        // cleanly — its copies gone with it — rather than killing the process with copies left in the store.
        let interruptions = RunInterruptions()
        interruptions.arm()
        let session: SetAsideSession
        do {
            if let line {
                session = try SetAsideSession.begin(line: line.number, of: line.path, from: workingDirectory)
            } else {
                session = try SetAsideSession.begin(pathspecs: pathspecs, from: workingDirectory, since: commit) { interruptions.pending != nil }
            }
        } catch let error as SetAsideError {
            if case .cancelled = error, let number = interruptions.pending {
                interruptions.claimOrPark()
                StandardStreams.emitError("◼ \(error.description)")
                exit(128 + number)
            }
            StandardStreams.emitError(error.description)
            throw (error.workIsOut ? Exit.notBack : Exit.refused).code
        }
        let named = session.record.named
        let guardian = GuardianSlot()
        if let number = interruptions.attach({ number in
            Self.interrupted(by: number, session: session, guardian: guardian, named: named)
        }) {
            // Arrived after the capture's last look and before anything was set aside: the record goes, and
            // the tree was never touched.
            _ = try? session.finish()
            session.close()
            interruptions.claimOrPark()
            StandardStreams.emitError("◼ sift run \(session.record.flag): interrupted by signal \(number) — nothing had been set aside yet, so the working tree is as it was; nothing was proven.")
            exit(128 + number)
        }
        try withExtendedLifetime(interruptions) {
            do {
                let handle = try SetAsideGuardian.arm(
                    executable: executable,
                    record: session.record,
                    repositoryRoot: session.store.repositoryRoot
                )
                guardian.handle = handle
                session.children.attach(handle)
            } catch {
                _ = try? session.finish()
                session.close()
                StandardStreams.emitError("\(error)")
                interruptions.claimOrPark()
                throw Exit.refused.code
            }
            try proveWithout(session: session, guardian: guardian, interruptions: interruptions, changedTests: changedTests, in: workingDirectory)
        }
    }

    private func proveWithout(
        session: SetAsideSession,
        guardian: GuardianSlot,
        interruptions: RunInterruptions,
        changedTests: Set<String>?,
        in workingDirectory: URL
    ) throws {
        // The promise to put the tree back after a kill is the watcher's, so nothing is set aside once it has
        // gone — however it went.
        guard guardian.handle?.isWatching() == true else {
            _ = try? session.finish()
            session.close()
            interruptions.claimOrPark()
            StandardStreams.emitError(SetAsideError.guardUnavailable("it stopped before anything was set aside").description)
            throw Exit.refused.code
        }
        // Readied before anything is set aside, so however long a stopped build takes to remove, the changes are
        // never out of the tree while it goes.
        let build = RunWithoutBuild(repositoryRoot: session.store.repositoryRoot, workingDirectory: workingDirectory, arguments: arguments)
        do {
            try build.prepare()
        } catch {
            _ = try? session.finish()
            _ = guardian.handle?.release()
            session.close()
            interruptions.claimOrPark()
            StandardStreams.emitError("sift run --without: \(build.shownDirectory) could not be cleared for the run without the change, so nothing was set aside and nothing was run: \(error.localizedDescription)")
            throw Exit.refused.code
        }
        let outcome: SetAside.Outcome
        do {
            guard let done = try session.setAsideTree() else {
                // Only an interruption stops a set-aside before it starts, and its handler owns the exit.
                interruptions.park()
            }
            outcome = done
        } catch {
            interruptions.checkpoint()
            // A failure that already says the work is not back is said once, by the finish below.
            if !session.hasFailed {
                StandardStreams.emitError("\(error)")
            }
            throw putBack(session, guardian: guardian, interruptions: interruptions).code
        }
        if case let .stopped(changed, restored) = outcome {
            let watched = guardian.handle?.release() ?? true
            interruptions.claimOrPark()
            StandardStreams.emitError(SetAsideError.changedDuringSetAside(changed).description)
            for kept in restored.kept {
                StandardStreams.emitError("  ⚠ kept rather than overwritten: \(kept)")
            }
            for path in restored.indexLeft {
                StandardStreams.emitError("  ⚠ staged again after it was recorded, so its index entry was left as that staging made it: \(path)")
            }
            if !watched {
                StandardStreams.emitError(RunWithoutAnswer.watcherLostLine)
            }
            session.close()
            throw Exit.refused.code
        }
        interruptions.checkpoint()
        let launcher = RunLauncher(workingDirectory: workingDirectory, repositoryRoot: session.store.repositoryRoot)
        // Both runs get the same environment, so the change is the only difference between them: a test that runs git
        // against a rewritten URL would otherwise fail without the change for that reason alone.
        let environment = build.environment
        let first = LaunchedChild()
        let before: RunOutcome
        do {
            // In a build directory of its own: one the run with the change, and the caller's next build, never read.
            before = try launcher.run(build.rewrittenArguments, environment: environment, children: session.children, launched: first.set)
        } catch {
            interruptions.checkpoint()
            StandardStreams.emitError("sift run --without: the command could not be started: \(error)")
            throw putBack(session, guardian: guardian, interruptions: interruptions).code
        }
        // Whatever the run without the change left running could go on writing into the tree once the changes
        // are back, so it is ended first.
        let stragglers = first.pid.map { session.children.settle($0) } ?? 0
        if stragglers == 0, before.report?.testOutcomes.isEmpty == false {
            // Reaching its tests is the one sign the build finished and recorded what it wrote, and with nothing
            // left running nothing is still writing into it.
            build.keep()
        }
        // Said once the run is known to have stopped before its tests: a run that built and ran them is a verdict
        // in its own right, and the note would claim an impossibility it just disproved.
        if let notice = RunWithoutAnswer.newFilesNotice(session.record, withoutBuilt: before.report?.testOutcomes.isEmpty == false) {
            StandardStreams.emitError(notice)
        }
        let selector = RunTestSelector.named(in: arguments)
        // Kept as a plain run keeps it, before either answer below names it: a run that did not build has only its
        // raw log to say what failed.
        Self.keepIfUnbuilt(before, selector: selector)
        interruptions.checkpoint()
        let restored: SetAside.Restored
        do {
            guard case let .restored(done) = try session.finish() else {
                // Only an interruption finishes a session behind this flow's back, and its handler owns the exit.
                interruptions.park()
            }
            restored = done
        } catch {
            // The watcher is deliberately not let go: it tries the restore again once this process is gone,
            // which is harmless if the tree is already back and may succeed where this attempt did not.
            interruptions.checkpoint()
            interruptions.claimOrPark()
            StandardStreams.emitError("\(error)")
            throw Exit.notBack.code
        }
        let watched = guardian.handle?.release() ?? true
        interruptions.checkpoint()
        if let unresolved = RunWithoutBuild.unresolvedAnswer(to: before, without: session.record.named) {
            interruptions.claimOrPark()
            // What a resolution that failed left behind is a partial fetch, never a build to build on.
            try? FileManager.default.removeItem(at: build.directory)
            let pathspecs = session.record.named
            var lines = [unresolved]
            // Nothing ran with the change, but the set-aside itself still happened — the same receipt the
            // ordinary answer would give it, not a second copy of its wording.
            lines.append(RunWithoutAnswer.setAsideLine(restored.record, pathspecs: pathspecs))
            if !restored.record.leftInPlace.isEmpty {
                lines.append(RunWithoutAnswer.leftInPlaceLine(restored.record))
            }
            if let stopped = RunWithoutAnswer.stragglersLine(stragglers, pathspecs: pathspecs) {
                lines.append(stopped)
            }
            lines.append(contentsOf: restored.kept.map { "  ⚠ changed while it was set aside, so kept rather than overwritten: \($0)" })
            if !watched {
                lines.append(RunWithoutAnswer.watcherLostLine)
            }
            let paths = RunAnswerPaths.read(in: workingDirectory)
            lines.append("  raw output at \(RunWithoutAnswer.logLine(before, named: "without \(pathspecs)", paths: paths))")
            StandardStreams.emit(lines.joined(separator: "\n"))
            session.close()
            throw Exit.notProven.code
        }
        let second = LaunchedChild()
        // With the change back and before the command starts: the tree this run reads is the caller's own.
        let startedOn = runKey(session.store.repositoryRoot)
        let started = Date()
        let after = try launcher.run(arguments, environment: environment, children: session.children, launched: second.set)
        if let pid = second.pid {
            session.children.forget(pid)
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Self.keepIfUnbuilt(after, selector: selector)
        interruptions.claimOrPark()
        let answer = RunWithoutAnswer(
            pathspecs: session.record.named,
            without: before,
            with: after,
            restored: restored,
            workingDirectory: workingDirectory,
            repositoryRoot: session.store.repositoryRoot,
            stragglers: stragglers,
            headNow: restored.headNow ?? session.headNow(),
            retriesFailures: RunWithoutArguments.retriesFailures(arguments),
            watcherLost: !watched,
            buildDirectory: build.directory.path,
            buildDirectorySize: build.sizeOnDisk,
            changedTests: changedTests,
            selector: selector
        )
        let rendered = answer.render()
        StandardStreams.emit(rendered.text)
        // Only the run with the change is filed: the one without it ran a tree the caller does not have, and
        // its failures — every one of them expected, since that is the proof — would read in `flakes` as
        // tests that fail one run in two.
        file(after, rendered.lines, elapsed, startedOn)
        session.close()
        guard answer.proven else {
            throw Exit.notProven.code
        }
    }

    /// After a set-aside that failed part-way, or a command that could not start: put back whatever was set aside, say which way that went, and answer the exit that says so.
    private func putBack(_ session: SetAsideSession, guardian: GuardianSlot, interruptions: RunInterruptions) -> Exit {
        do {
            try session.finish()
            let watched = guardian.handle?.release() ?? true
            interruptions.claimOrPark()
            StandardStreams.emitError("sift run --without: what had been set aside is back in place and checked by content hash; nothing was run.")
            if !watched {
                StandardStreams.emitError(RunWithoutAnswer.watcherLostLine)
            }
            return .refused
        } catch {
            interruptions.claimOrPark()
            StandardStreams.emitError("\(error)")
            return .notBack
        }
    }

    /// Moves the raw log of either run that did not build out of the count later runs prune, into the pool `run` keeps such a log in, so the path the answer names for it still resolves.
    private static func keepIfUnbuilt(_ outcome: RunOutcome, selector: RunTestSelector?) {
        if let report = outcome.report, selector?.didNotBuild(report, exitCode: outcome.exitCode) == true {
            outcome.log?.keep(in: .didNotBuild)
        }
    }

    /// What the first `SIGINT`, `SIGTERM` or `SIGHUP` does: pass it on to the running tests and end them, put the tree back through the session, let the watcher go, and exit as a signalled process would.
    ///
    /// A restore that fails keeps the watcher — it tries again once this process is gone — and exits ``Exit/notBack``, never with a sentence saying the tree is as it was. A second signal kills outright, the handler having put every disposition back to its default, and the watcher restores in its place.
    private static func interrupted(
        by number: Int32,
        session: SetAsideSession,
        guardian: GuardianSlot,
        named: String
    ) -> Never {
        let state: String
        var kept: [String] = []
        var wasOut = true
        switch session.interrupt(forwarding: number) {
        case .success(.untouched):
            state = "nothing had been set aside yet, so the working tree is as it was"
            wasOut = false
        case .success(.alreadyBack):
            state = "the changes under \(named) were already back in place"
        case let .success(.restored(restored)):
            state = "the changes under \(named) are back in place and checked by content hash"
            kept = restored.kept
        case let .failure(error):
            StandardStreams.emitError("◼ sift run \(session.record.flag): interrupted by signal \(number).")
            StandardStreams.emitError(error.description)
            exit(Exit.notBack.rawValue)
        }
        let watched = guardian.handle?.release() ?? true
        StandardStreams.emitError("◼ sift run \(session.record.flag): interrupted by signal \(number) — \(state); nothing was proven.")
        for path in kept {
            StandardStreams.emitError("  ⚠ changed while it was set aside, so kept rather than overwritten: \(path)")
        }
        if !watched, wasOut {
            StandardStreams.emitError(RunWithoutAnswer.watcherLostLine)
        }
        exit(128 + number)
    }

    /// `run --restore`: put back a set-aside whose run is gone.
    static func restore(in workingDirectory: URL) throws {
        do {
            guard let restored = try SetAsideSession.restoreAbandoned(in: workingDirectory) else {
                StandardStreams.emit("sift run --restore: nothing to put back — this working tree has no set-aside record.")
                return
            }
            let count = restored.record.entries.count
            let what = restored.record.line.map { "\($0.path):\($0.number), the line `sift run --without-line` commented out" }
                ?? "\(count == 1 ? "1 path" : "\(count) paths") under \(restored.record.named)"
            StandardStreams.emit("✔ sift run --restore: put back \(what), checked by content hash; the record is gone.")
            if restored.ended > 0 {
                StandardStreams.emit("  stopped \(restored.ended == 1 ? "1 process" : "\(restored.ended) processes") the run had left running, before putting the changes back")
            }
            for kept in restored.kept {
                StandardStreams.emit("  ⚠ changed while it was set aside, so kept rather than overwritten: \(kept)")
            }
            if let headNow = restored.headNow {
                StandardStreams.emit("  ⚠ HEAD moved from \(restored.record.head.prefix(10)) to \(headNow.prefix(10)) while the changes were set aside; they are back on top of it")
            }
        } catch let error as SetAsideError {
            StandardStreams.emitError("sift run --restore: \(error.description)")
            throw (error.workIsOut ? Exit.notBack : Exit.refused).code
        }
    }
}

extension RunWithoutCommand {
    /// What `run --without` and `run --restore` exit with.
    enum Exit: Int32, CaseIterable {
        /// Every named test failed without the change and passed with it.
        case proven = 0
        /// The runs happened and proved nothing: a test that pins nothing, one that fails both ways, no test reported, a suite that did not compile, a command that failed before its tests, HEAD moving under the run.
        case notProven = 1
        /// Refused, or stopped, before any test ran — and nothing is out of the tree: either nothing was set aside, or what was is back and checked.
        case refused = 2
        /// Somebody's changes are NOT back in the working tree.
        ///
        /// The record and every copy are kept, and `sift run --restore` puts them back.
        case notBack = 3

        var code: ExitCode {
            ExitCode(rawValue)
        }
    }
}

private extension RunWithoutCommand {
    /// The pid of a command this run started, once it exists.
    final class LaunchedChild: @unchecked Sendable {
        private let gate = NSLock()
        private var stored: Int32?

        var pid: Int32? {
            gate.withLock { stored }
        }

        func set(_ pid: Int32) {
            gate.withLock { stored = pid }
        }
    }

    /// The watcher's handle, filled in once it is armed — the signal handler is armed before it, so a signal during arming can still put the record away.
    final class GuardianSlot: @unchecked Sendable {
        private let gate = NSLock()
        private var stored: SetAsideGuardian.Handle?

        var handle: SetAsideGuardian.Handle? {
            get { gate.withLock { stored } }
            set { gate.withLock { stored = newValue } }
        }
    }

    /// The signals that end a run, caught so a set-aside can be put back before the process goes — and the one claim that decides which thread exits.
    ///
    /// **One-shot, on the reasoning `ServerSignalWatch` gives for a server:** the handler's first act puts every disposition back to its default, so a second signal kills outright however the first one's restore is going, and the watcher takes over from there. A process that swallowed every Ctrl-C while a restore was wedged would be worse than one that can always be stopped.
    ///
    /// **Exactly one thread exits.** The handler and the main flow can each reach the end — the handler after an interruption, the main flow after the second run — and two `exit` calls racing each other can wedge a process in its teardown. Whichever claims first exits; the other parks and waits to be ended with the process.
    ///
    /// **Armed before there is a session to hand a signal to.** One that arrives while the changes are still being recorded is held as ``pending`` — the capture asks, stops, and takes its copies with it — and one that arrives before ``attach(_:)`` is answered by it, so the main flow says it and exits.
    final class RunInterruptions: @unchecked Sendable {
        private static let watched: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        private let gate = NSLock()
        private var signalled = false
        private var claimed = false
        private var waiting: Int32?
        private var handler: (@Sendable (Int32) -> Void)?
        private var sources: [any DispatchSourceSignal] = []

        func arm() {
            gate.withLock {
                for number in Self.watched {
                    signal(number, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
                    source.setEventHandler { [self] in
                        for other in Self.watched {
                            signal(other, SIG_DFL)
                        }
                        let handle: (@Sendable (Int32) -> Void)? = gate.withLock {
                            signalled = true
                            if handler == nil, waiting == nil {
                                waiting = number
                            }
                            return handler
                        }
                        guard let handle, claim() else {
                            return
                        }
                        handle(number)
                    }
                    source.resume()
                    sources.append(source)
                }
            }
        }

        /// A signal that arrived with no session to hand it to.
        var pending: Int32? {
            gate.withLock { waiting }
        }

        /// Hands every signal from here on to `handle` — or, when one has already arrived with nobody to hand it to, answers it, and the caller deals with it.
        func attach(_ handle: @escaping @Sendable (Int32) -> Void) -> Int32? {
            gate.withLock {
                if let waiting {
                    return waiting
                }
                handler = handle
                return nil
            }
        }

        /// Stops here for good if a signal has arrived: its handler is putting the tree back and will end the process.
        func checkpoint() {
            if gate.withLock({ signalled }) {
                park()
            }
        }

        /// Takes the one exit, or parks if the handler already has it.
        func claimOrPark() {
            if !claim() {
                park()
            }
        }

        func park() -> Never {
            while true {
                sleep(60)
            }
        }

        private func claim() -> Bool {
            gate.withLock {
                guard !claimed else {
                    return false
                }
                claimed = true
                return true
            }
        }
    }
}
