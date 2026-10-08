//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift session-start` — the body of the Claude Code `SessionStart` and `SubagentStart` hooks.
///
/// Claude Code runs this itself and injects the result into the context, which is the property the path-scoped rule cannot offer: it lands before the model's first turn rather than on first contact with a Swift file. Registered for subagents too, because they get neither the rule nor a session start of their own. Register both with `sift install-hook`.
///
/// At a subagent's start it also says so when the session's sift server is proven not to be running (`ServerPresence.isProvenAbsent`), because that is the moment the loss costs most: a subagent handed the primer's tool names with no tools behind them spends its first refusals finding out.
///
/// Two invariants, both because a hook that misbehaves degrades every session on the machine: it always exits 0 (a broken primer must never look like a failed session start), and it prints nothing at all when there is no Swift in view.
struct SessionStartCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "session-start",
            abstract: "Emit the session primer (run by Claude Code's SessionStart/SubagentStart hooks; silent outside Swift work)."
        )
    }

    @Option(name: .customLong("cwd"), help: "Directory to resolve against. Passing it skips the stdin payload entirely; without it, the payload is read, then the process directory.")
    var cwd: String?

    @Option(name: .customLong("event"), help: "Hook event being served (defaults to the stdin payload's hook_event_name; plain text when neither is given).")
    var event: String?

    @Option(name: .customLong("agent"), help: "The harness whose hook protocol to read and answer in: claude or cursor (default claude). Set by the registration, never guessed from the payload.")
    var agent: HookAgent = .claude

    func run() {
        // `--cwd` means "I am driving this by hand", and it has always meant stdin is left alone: a pipe
        // that is open but never closed would otherwise block the read forever. Pass `--event` alongside it
        // to choose the output shape.
        let payload = cwd == nil ? hookPayload() : [:]
        guard agent == .claude else {
            answerCursor(payload)
            return
        }
        guard !CursorHookPayload.recognises(payload) else { return }
        guard let output = Self.output(payload: payload, cwd: cwd, event: event, runLedgerURL: RunUsageLog.standardFileURL) else {
            return
        }
        StandardStreams.emit(output)
    }

    /// Everything this hook prints for `payload` — the primer, then the resumption block where the payload's `source` earns one — or `nil` for silence.
    ///
    /// Apart from `run()` so the wiring itself is under test without a subprocess: the payload's `source` reaching ``SessionResumeBlock/applies(hookEvent:source:context:)``, the block landing after the primer, and a gather past its deadline costing only the block.
    static func output(
        payload: [String: Any],
        cwd: String?,
        event: String?,
        runLedgerURL: URL,
        serverLogURL: URL = ServerLifecycleLog.standard().fileURL,
        permission: (_ directory: String?) -> WrappedRunPermission = WrappedRunPermission.standard(in:),
        resumptionDeadline: TimeInterval = SessionResumeGatherer.defaultDeadline,
        declarationParseBudget: TimeInterval = SessionResumeGatherer.defaultDeclarationParseBudget
    ) -> String? {
        // Resolved once, for the repository below as well as the primer, so the "where you left off" block
        // reads the same repository the primer names.
        let directory = SessionPrimer.sessionDirectory(
            cwd
                ?? (payload["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.currentDirectoryPath
        )
        let hookEvent = event ?? payload["hook_event_name"] as? String

        let repository = SessionPrimer.enclosingRepository(of: directory)
        let context = SessionPrimer.context(at: directory, knownRoots: RootsRegistry.standard().knownRoots())
        let audience: SessionPrimer.Audience = hookEvent == "SubagentStart" ? .subagent : .session
        // Asked only at a subagent's start, and only where the primer will say anything. At a session's start
        // the server is being launched beside this hook, so its absence from the log proves nothing yet; by the
        // time a subagent is spawned it has had the whole first turn to appear.
        let serverAbsent = audience == .subagent && context != .none && ServerPresence.isProvenAbsent(
            session: payload["session_id"] as? String,
            transcript: payload["transcript_path"] as? String,
            lifecycleLog: serverLogURL
        )
        // Read only where the primer will say anything, and from the settings Claude Code applies to the session.
        let lookupsFromBash = context != .none && permission(directory).allowsLookups()
        let primer = SessionPrimer.render(
            context,
            audience: audience,
            moduleHealth: moduleHealth(of: context),
            serverAbsent: serverAbsent,
            lookupsFromBash: lookupsFromBash
        )
        let resumeBlock = resumptionBlock(
            hookEvent: hookEvent,
            source: payload["source"] as? String,
            context: context,
            repository: repository
        ) { root in
            SessionResumeGatherer.gather(
                repositoryRoot: root,
                runLedgerURL: runLedgerURL,
                deadline: resumptionDeadline,
                declarationParseBudget: declarationParseBudget
            )
        }

        let combined = [primer, resumeBlock].compactMap(\.self).joined(separator: "\n\n")
        guard !combined.isEmpty else { return nil }
        return HookOutput.render(combined, event: hookEvent)
    }

    /// The "where you left off" block — only after a `/clear` or `/compact`, the two moments the conversation's own history was just thrown away.
    ///
    /// Strictly read-only: gathers facts about the working tree from git, the run ledger and blob content, and never opens the index. `gather` is called only where the block applies, and is bounded as a whole by its deadline: a gather still going when it passes returns `nil`, which leaves the block out, and the primer goes out on its own.
    private static func resumptionBlock(
        hookEvent: String?,
        source: String?,
        context: SessionContext,
        repository: String?,
        gather: (_ repositoryRoot: URL) -> SessionResumeFacts?
    ) -> String? {
        guard SessionResumeBlock.applies(hookEvent: hookEvent, source: source, context: context),
              let repository,
              let facts = gather(URL(fileURLWithPath: repository))
        else { return nil }
        return SessionResumeBlock.render(facts, now: Date())
    }

    /// How much of the resolved root's module resolution is guesswork, read straight from its index.
    ///
    /// Only for a session sitting *inside* one indexed repository. Above several there is no single answer, and an unindexed repository has nothing to read — in both cases the honest output is silence rather than a warning about the wrong repo. Strictly read-only: opening the index properly would let a session-start hook rebuild a schema.
    private static func moduleHealth(of context: SessionContext) -> SessionPrimer.ModuleHealth? {
        guard case let .insideRoot(root) = context,
              let snapshot = ReadOnlyIndex.snapshot(atRoot: root)
        else {
            return nil
        }
        return SessionPrimer.ModuleHealth(guessed: snapshot.guessedModules, files: snapshot.files)
    }

    /// Prints the primer for Cursor's `payload` as its `additional_context`, or nothing where the payload cannot be read or there is no Swift in view.
    ///
    /// `--event` is not read: the primer goes out as plain text inside the envelope, never Claude Code's subagent envelope.
    private func answerCursor(_ payload: [String: Any]) {
        guard let read = cwd == nil ? CursorSessionStart.claudePayload(from: payload) : [:],
              let primer = Self.output(payload: read, cwd: cwd, event: nil, runLedgerURL: RunUsageLog.standardFileURL),
              let response = CursorHookOutput.additionalContext(primer)
        else {
            return
        }
        StandardStreams.emit(response)
    }

    /// The `{"cwd": …, "hook_event_name": …, "source": …}` payload Claude Code writes to the hook's stdin.
    ///
    /// Guarded by `isatty` so running this by hand in a terminal returns immediately instead of blocking on a read that will never be satisfied.
    private func hookPayload() -> [String: Any] {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0,
              let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return payload
    }
}
