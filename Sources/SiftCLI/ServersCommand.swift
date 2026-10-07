//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift servers` — the MCP servers this machine believes are running, and the one sanctioned way to stop one.
///
/// **Why a command and not a policy.** A server whose parent has died ends itself (``SiftMCP/ServerParentWatch``). The orphans left over are the other kind: their parents are alive, their client sockets are open, and the host has simply stopped speaking — a state a server cannot tell apart from a user who went to lunch. Rather than guess, the tool hands a person the evidence `sift status` can already see, and a way to act on it that cannot become a guess in disguise.
///
/// It takes no `--root` option group, deliberately: this reads `~/.sift` and nothing else, so it answers the same way from inside any repository or none.
struct ServersCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "servers",
            abstract: "List the MCP servers this machine believes are running, and stop ones you name.",
            discussion: """
            With no arguments it lists. `--stop` needs at least one `--pid` or a `--root`, and a `--root` \
            at or above your home directory is refused: there is no form of this that reaps whatever it \
            finds, because a command that did would be an idle timeout with extra steps — and a server \
            that exits for being quiet is a session losing its index mid-run. A stop prints what it would \
            do and changes nothing until `--yes`. Three kinds of server are never stopped, each named with \
            the evidence: this session's own, one in this process's own ancestry, and one with a sign of \
            life in the last ten minutes.
            """
        )
    }

    @Flag(name: .customLong("stop"), help: "Stop the servers named by --pid and --root, subject to the guards.")
    var stop = false

    @Option(name: .customLong("pid"), help: "A server to stop, by process id. Repeat for several.")
    var pids: [Int32] = []

    @Option(name: .customLong("root"), help: "Stop the servers serving this directory or anything beneath it — an absolute path.")
    var root: String?

    @Flag(name: .customLong("yes"), help: "Actually send the signal. Without it, --stop prints the plan and changes nothing.")
    var yes = false

    @Option(name: .customLong("file"), help: "Server lifecycle log to read (defaults to ~/.sift/server.jsonl).")
    var file: String?

    @Option(name: .customLong("usage-file"), help: "Usage log to read for signs of life (defaults to ~/.sift/usage.jsonl, or the file SIFT_USAGE_LOG names).")
    var usageFile: String?

    /// How a stop is actually sent.
    ///
    /// Injectable for the same reason ``RunCommand``'s log is: the half of this command worth pinning is which servers it decides to leave alone, and a test that had to send real signals to find that out would be a test that kills a live index whenever it is wrong.
    var send: (Int32) -> Int32? = ServerRoster.stop

    /// Whether a recorded start still names a live process.
    ///
    /// Injectable alongside `send` and for a reason peculiar to this command: every guard here is a statement about *elapsed time*, and a test cannot produce a process that both started ten minutes ago and started just now. Pinned on its own in the lifecycle report's own suite; stubbed here so the command's own wiring can be exercised against a log that says what a real one would say tomorrow.
    var isRunning: (ServerLifecycleEntry) -> Bool = ServerLifecycleReport.isStillRunning

    /// Both refusals, before a single file is read.
    ///
    /// They are here rather than inside `run` because neither depends on what is running: a stop that names nothing, and a root that names the machine, are wrong on their face. Refusing early also means the one command that must never act sweepingly never even opens the logs.
    func validate() throws {
        guard stop else { return }
        guard !pids.isEmpty || root != nil else {
            throw ValidationError("--stop needs at least one --pid or a --root. Run `sift servers` first and name what you mean.")
        }
        // The one root argument this refuses, and the refusal is the design rather than a rail on it
        // (``SiftMCP/ServerRoster/namesTheWholeMachine(_:home:)``). `/` is a prefix of every absolute path, so
        // one token would have selected every server on the machine — the "reaps whatever it finds" form this
        // command exists not to have. In a cron neither the session guard nor the ancestry guard is even
        // operative against it, so what would have remained is the bare idle timeout this design refuses.
        if let root, ServerRoster.namesTheWholeMachine(root) {
            throw ValidationError("--root \(root) names this machine rather than somewhere in it, and would select every server on it. Name a repository, or name pids.")
        }
    }

    func run() async throws {
        let now = Date()
        let session = UsageLog.currentSession
        let lifecycleLog = file.map { URL(fileURLWithPath: $0) } ?? ServerLifecycleLog.standard().fileURL
        let usageLog = usageFile.map { URL(fileURLWithPath: $0) } ?? UsageLog.standardFileURL()
        let lastAnswered = ServerRoster.lastAnswered(in: usageLog)
        let entries = ServerLifecycleReport.entries(in: lifecycleLog)
        let evidence = ServerRosterReport.Evidence(
            lifecycleLog: lifecycleLog.path,
            lifecycleEntries: entries.count,
            usageLog: usageLog.path,
            sessionsWithActivity: lastAnswered.count,
            callerIsNamed: session != nil
        )
        let servers = ServerRoster.running(
            entries: entries,
            now: now,
            callerSession: session,
            callerTree: ServerRoster.processTree(),
            lastAnswered: lastAnswered,
            isRunning: isRunning
        )

        guard stop else {
            StandardStreams.emit(ServerRosterReport.listing(servers, now: now, evidence: evidence))
            return
        }

        let selection = ServerRoster.select(from: servers, pids: pids, root: root)
        guard yes else {
            StandardStreams.emit(ServerRosterReport.plan(selection, now: now, evidence: evidence))
            return
        }

        let outcome = ServerRoster.stopAll(selection, stop: send)
        StandardStreams.emit(ServerRosterReport.outcome(outcome, evidence: evidence))
        // Nonzero where any part of what was asked did not happen — a guard held one back, the kernel refused
        // one, or a named pid was not there. A script that reaps by root needs to tell those from a clean run,
        // and the alternative is parsing prose.
        guard outcome.didEverythingAsked else {
            throw ExitCode(1)
        }
    }
}

extension ServersCommand {
    /// Everything that comes off the command line, and nothing that does not.
    ///
    /// Spelled out for the reason ``RunCommand``'s keys are: `ParsableCommand` is `Decodable` with a synthesized conformance, so a stored property that is not an argument would have to be decodable too — and a function is not something a decoder can produce. Naming the keys leaves ``send`` at its default on the parse path, which is what the parse path wants.
    enum CodingKeys: String, CodingKey {
        case stop
        case pids
        case root
        case yes
        case file
        case usageFile
    }
}
