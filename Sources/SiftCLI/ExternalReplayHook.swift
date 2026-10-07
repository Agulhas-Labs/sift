//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// The hook of another sift binary, put each call of a replay through that binary's `replay-hook` entry point against state of its own in `directory`, so `audit --replay --against` judges every call by both hooks in one replay.
///
/// A request the other binary fails, or answers in a shape it cannot read, is counted in ``failures`` and judged as ``failedRule``, so it is listed with the changes rather than read as agreement.
final class ExternalReplayHook: ReplayHook {
    /// The rule a verdict the other binary failed to give is listed under.
    static var failedRule: String {
        "unanswered"
    }

    let binary: URL
    let directory: URL
    let timeBudget: TimeInterval
    /// How long past ``timeBudget`` one request may run before its child is stopped and the request counted as failed.
    let margin: TimeInterval
    /// Where each child is recorded while it runs, so a signal that ends the run stops it; `nil` records none.
    let interruptions: ReplayInterruptions?
    /// Variables set over this process's own in every `replay-hook` child, so a caller can point the child at a home of its own; `nil` leaves the child this process's environment.
    let environment: [String: String]?
    private(set) var requests = 0
    private(set) var failures = 0
    /// The last instant a call carried, handed on for a line with none, as the in-process replay's clock stays where the last dated line moved it.
    private var lastInstant: Date?

    init(binary: URL, directory: URL, timeBudget: TimeInterval, margin: TimeInterval = 10, interruptions: ReplayInterruptions? = nil, environment: [String: String]? = nil) {
        self.binary = binary
        self.directory = directory
        self.timeBudget = timeBudget
        self.margin = margin
        self.interruptions = interruptions
        self.environment = environment
    }

    /// Whether `binary` has the `replay-hook` entry point this hook drives: a build from before it has none.
    ///
    /// Judged by `replay-hook --help`'s own text, not its exit code: ArgumentParser answers an unknown subcommand's `--help` with the *root* command's own usage, at exit 0, so a build from before `replay-hook` existed would otherwise be read as having it. A real `replay-hook`'s help names its own usage line (`USAGE: sift replay-hook …`), which the root's never does, since the entry point is hidden from the root's own listing. Empty output — a stand-in binary with nothing to say for `--help` — is read as supported too, since nothing a real build ever prints for `--help` is empty; only the root's *unrelated* usage text need be ruled out.
    ///
    /// A binary that has not answered within `limit` seconds is stopped and counted as having none, so a child that hangs on its help never holds the audit.
    static func isSupported(by binary: URL, within limit: TimeInterval = 10, interruptions: ReplayInterruptions? = nil) -> Bool {
        guarded(by: interruptions) {
            guard let reply = launch(binary, arguments: ["replay-hook", "--help"], within: limit, interruptions: interruptions), reply.status == 0 else {
                return false
            }
            let text = String(data: reply.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty || text.contains("replay-hook")
        }
    }

    /// The index schema version and resolution fingerprint `binary` keeps, read from the store it writes for an empty repository made for the question and removed after, beside this build's own fingerprint for that same empty repository.
    ///
    /// Asked through `index`, which every build has, so a build that knows nothing of this question still answers it. Its home is moved into the same directory, so the repository it indexes is recorded nowhere a live session reads. The base directory it works in is where the empty repository is made; a caller that cannot write there is told so rather than blamed on the other binary.
    static func schemaVersion(of binary: URL, probeBase: URL = FileManager.default.temporaryDirectory, within limit: TimeInterval = 30, interruptions: ReplayInterruptions? = nil) -> SchemaProbe {
        // One unit of work from the probe directory's making to its removal, so a signal's cleanup removes it only
        // once nothing here can write into it again.
        guarded(by: interruptions) {
            probedSchemaVersion(of: binary, probeBase: probeBase, within: limit, interruptions: interruptions)
        }
    }

    /// The schema probe's answer, asked inside a unit of work so a stop parks it.
    private static func probedSchemaVersion(of binary: URL, probeBase: URL, within limit: TimeInterval, interruptions: ReplayInterruptions?) -> SchemaProbe {
        let manager = FileManager.default
        let probe = probeBase.appendingPathComponent("sift-schema-probe-\(UUID().uuidString)", isDirectory: true)
        interruptions?.track(probe)
        defer {
            try? manager.removeItem(at: probe)
            interruptions?.forget(probe)
        }
        let repository = probe.appendingPathComponent("repository", isDirectory: true)
        let home = probe.appendingPathComponent("home", isDirectory: true)
        guard (try? manager.createDirectory(at: repository, withIntermediateDirectories: true)) != nil else {
            return .setupFailed("could not create \(repository.path)")
        }
        guard (try? manager.createDirectory(at: home, withIntermediateDirectories: true)) != nil else {
            return .setupFailed("could not create \(home.path)")
        }
        guard launch(URL(fileURLWithPath: "/usr/bin/git"), arguments: ProcessEnvironment.gitHardening + ["init", "-q", repository.path], within: limit, interruptions: interruptions)?.status == 0 else {
            return .setupFailed("`git init` did not make an empty repository at \(repository.path)")
        }
        let ownFingerprint = ReadOnlyIndex.resolutionFingerprint(atRoot: repository.path)
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        // Its exit status is not the answer: a store the child opened carries its version whether or not the index that followed succeeded.
        _ = launch(binary, arguments: ["index", "--root", repository.path], environment: environment, within: limit, interruptions: interruptions)
        guard let schema = ReadOnlyIndex.storedSchemaVersion(atRoot: repository.path) else {
            return .wroteNoIndex
        }
        return .stamps(IndexStamps(schema: schema, fingerprint: ReadOnlyIndex.storedResolutionFingerprint(atRoot: repository.path), ownFingerprint: ownFingerprint))
    }

    func verdict(payload: [String: Any], cwd: String, at instant: Date?, decides: Bool) -> ReplayVerdict? {
        guard let answer = ask(payload: payload, cwd: cwd, at: instant, extra: decides ? [] : ["--outside-window"]),
              let hooked = answer["hooked"] as? Bool
        else {
            failures += 1
            return ReplayVerdict(token: "failed", rule: Self.failedRule)
        }
        guard hooked else { return nil }
        guard let token = answer["token"] as? String, let rule = answer["rule"] as? String else {
            failures += 1
            return ReplayVerdict(token: "failed", rule: Self.failedRule)
        }
        return ReplayVerdict(token: token, rule: rule, call: answer["call"] as? String, answerBytes: (answer["answerBytes"] as? NSNumber)?.intValue)
    }

    func answered(payload: [String: Any], cwd: String, at instant: Date?) {
        if ask(payload: payload, cwd: cwd, at: instant, extra: ["--answered"]) == nil {
            failures += 1
        }
    }

    func locatedOnlyByAnswers(_ path: String, payload: [String: Any]) -> Bool {
        guard let located = ask(payload: payload, cwd: "/", at: nil, extra: ["--located", path])?["located"] as? Bool else {
            failures += 1
            return false
        }
        return located
    }

    /// The other binary's one-line answer to one request, or `nil` where it failed or answered in a shape that is not a JSON object.
    private func ask(payload: [String: Any], cwd: String, at instant: Date?, extra: [String]) -> [String: Any]? {
        requests += 1
        if let instant {
            lastInstant = instant
        }
        guard let input = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var arguments = ["replay-hook", "--state", directory.path, "--cwd", cwd, "--time-budget", String(timeBudget)]
        if let moment = lastInstant {
            arguments += ["--at", String(moment.timeIntervalSince1970)]
        }
        let childEnvironment = environment.map { ProcessInfo.processInfo.environment.merging($0) { _, set in set } }
        guard let reply = Self.launch(binary, arguments: arguments + extra, input: input, environment: childEnvironment, within: timeBudget + margin, interruptions: interruptions), reply.status == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply.output)) as? [String: Any]
    }

    /// What a child of `binary` run with `arguments` wrote to stdout and the status it exited with, given `input` on stdin, or `nil` where it could not be launched or was not done within `limit` seconds.
    ///
    /// A child still running at that deadline is stopped and reaped before this returns; while it runs, it is recorded in `interruptions`.
    static func launch(
        _ binary: URL,
        arguments: [String],
        input: Data = Data(),
        environment: [String: String]? = nil,
        within limit: TimeInterval,
        interruptions: ReplayInterruptions? = nil
    ) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let (stdin, stdout) = (Pipe(), Pipe())
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // A child that exits before reading all of it is a write error then, not a SIGPIPE that takes this process down.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Launched under the interruptions' own lock where there are any, so a signal never finds this child alive and unrecorded.
        let start = { (try? process.run()) != nil ? process.processIdentifier : nil }
        let launched = (interruptions.map { $0.launch(start) } ?? start()) != nil
        // Every end is closed here rather than left to deallocation, which a replay of thousands of calls outruns until
        // no descriptor is left for the next child: the child's own ends at once, launched or not, and this side's
        // too where no child was launched to talk to.
        for end in [stdin.fileHandleForReading, stdout.fileHandleForWriting] {
            try? end.close()
        }
        guard launched else {
            for end in [stdin.fileHandleForWriting, stdout.fileHandleForReading] {
                try? end.close()
            }
            return nil
        }
        let child = process.processIdentifier
        defer { interruptions?.forget(child: child) }
        let deadline = DispatchTime.now() + limit
        guard let output = exchange(input, writing: stdin.fileHandleForWriting, reading: stdout.fileHandleForReading, until: deadline),
              exited.wait(timeout: deadline) == .success
        else {
            stop(process, exited: exited)
            return nil
        }
        return (process.terminationStatus, output)
    }

    /// `input` written to a child and its output read to the end on a thread of their own, or `nil` where that is not done by `deadline`.
    ///
    /// That thread closes both ends once it is done, so a child stopped at the deadline leaves neither behind, and one whose ends outlive it holds that thread and never the replay.
    private static func exchange(_ input: Data, writing: FileHandle, reading: FileHandle, until deadline: DispatchTime) -> Data? {
        let done = DispatchSemaphore(value: 0)
        let reply = ExchangedReply()
        DispatchQueue.global(qos: .userInitiated).async {
            // The child reads its stdin to the end before it writes, so writing all of it first cannot wait on a full stdout.
            try? writing.write(contentsOf: input)
            try? writing.close()
            reply.set((try? reading.readToEnd()) ?? Data())
            try? reading.close()
            done.signal()
        }
        guard done.wait(timeout: deadline) == .success else { return nil }
        return reply.value
    }

    /// `body`'s result, run as one unit of work of `interruptions` where there are any.
    private static func guarded<Value>(by interruptions: ReplayInterruptions?, _ body: () -> Value) -> Value {
        guard let interruptions else { return body() }
        return interruptions.working(body)
    }

    /// A child past its deadline asked to terminate, killed where it is still running a second later, and waited on until it is reaped.
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        guard exited.wait(timeout: .now() + 1) == .timedOut else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 10)
    }
}

extension ExternalReplayHook {
    /// The schema version and resolution fingerprint a probe of another binary's empty-repository store read back, beside this build's own fingerprint for that same empty repository.
    struct IndexStamps {
        let schema: Int
        let fingerprint: String?
        let ownFingerprint: String
    }

    /// What a probe of another binary's schema and resolution fingerprint found.
    enum SchemaProbe {
        /// The stamps read back from the store the other binary wrote.
        case stamps(IndexStamps)
        /// The probe ran but the other binary left no store usable within its time limit.
        case wroteNoIndex
        /// The probe itself could not be readied — the empty repository could not be made — so the other binary was never asked.
        case setupFailed(String)
    }
}

private extension ExternalReplayHook {
    /// The output a child wrote, handed from the thread that read it to the one waiting on it.
    final class ExchangedReply: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        var value: Data? {
            lock.withLock { data }
        }

        func set(_ output: Data) {
            lock.withLock { data = output }
        }
    }
}
