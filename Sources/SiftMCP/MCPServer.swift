//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The MCP stdio face: a newline-delimited JSON-RPC 2.0 loop over the engine.
///
/// The output handle carries protocol JSON and *nothing else* — one stray write corrupts the stream, so all diagnostics go through `log` (stderr in production). The official Swift SDK was weighed and skipped for v1: it is pre-1.0 with a moving API against this repo's exact-pin policy, and the framing here is ~150 lines — revisit at SDK 1.0 (Docs/Design.md §2).
///
/// Startup is instant: engines are created lazily per root on the first tool call, and indexing happens inside that call (a full build of a small repository takes about a second, far inside tool timeouts).
public actor MCPServer {
    private let input: FileHandle
    private let output: FileHandle
    private let defaultRoot: URL
    private let log: @Sendable (String) -> Void
    private let usage: UsageLog?
    /// Where the `PreToolUse` hook leaves the identity of the context making a call — injectable so a test can put it somewhere disposable.
    private let callers: CallAttribution
    /// The conversation this server is serving, which is what a slip is filed under.
    ///
    /// Read from the environment Claude Code sets, exactly as the log's own `session` field is and through the same accessor, so the two can never name different conversations. Injectable only so a test need not mutate a process-wide variable that every other test in the run would see.
    private let session: String?
    private let registry: RootsRegistry?
    private var engines: [String: SiftEngine] = [:]
    /// Where this process's executable lives and what it looked like at startup — statted per request so a replaced binary is taken over in place (``ServerReexec``), or, where it cannot be, announces itself instead of serving superseded answers silently.
    private let binaryPath: String
    private let binaryIdentity: BinaryIdentity?
    /// Hands the session to a replaced binary; `nil` for a server that has no process to replace, which is every one a test runs in-process.
    private let reexec: ServerReexec?
    /// Replacements already tried and not taken over, and when each may be tried again (``ServerReexec/Attempts``).
    private var replacementAttempts = ServerReexec.Attempts()
    /// The protocol version agreed at `initialize`, or carried from the image this one replaced — the negotiated part of a session, which an exec must not make the client repeat.
    private var protocolVersion: String?
    /// Input an earlier image of this process read and did not answer, delivered before anything is read.
    private let carried: Data
    /// The tool list `tools/list` serves, marked to load up front or not once, at startup, rather than per request.
    private let toolList: [[String: Any]]

    public init(
        input: FileHandle,
        output: FileHandle,
        defaultRoot: URL,
        log: @escaping @Sendable (String) -> Void,
        usage: UsageLog? = nil,
        registry: RootsRegistry? = nil,
        callers: CallAttribution = .standard(),
        session: String? = UsageLog.currentSession,
        binaryPath: String = BinaryIdentity.executablePath,
        resuming handedOver: ServerHandover.Session? = nil,
        reexec: ServerReexec? = nil,
        loadToolsUpFront: Bool = true
    ) {
        self.input = input
        self.output = output
        self.defaultRoot = defaultRoot
        self.log = log
        self.usage = usage
        self.callers = callers
        self.session = session
        self.registry = registry
        self.binaryPath = binaryPath
        binaryIdentity = BinaryIdentity.capture(at: binaryPath)
        self.reexec = reexec
        protocolVersion = handedOver?.protocolVersion
        carried = handedOver?.unread ?? Data()
        toolList = MCPToolCatalog.tools(loadUpFront: loadToolsUpFront)
    }

    /// Reads requests until the input closes (or stdout dies); every response is a single JSON line.
    ///
    /// Returns *why* it stopped. This loop is the one place that knows the answer, and a process that simply ends leaves no account of itself anywhere. The caller writes it to ``ServerLifecycleLog``.
    @discardableResult
    public func run() async -> ServerStop {
        signal(SIGPIPE, SIG_IGN)
        let lines = LineInput(descriptor: input.fileDescriptor, carried: carried)
        while let line = await lines.next() {
            if outputBroken {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            handOverIfReplaced(line, input: lines)
            await handle(line: trimmed)
            // Checked again here as well as at the top: a server whose stdout died mid-answer would otherwise wait
            // for a request that is never coming before noticing, which is one more way to be alive and useless.
            if outputBroken {
                break
            }
        }
        if outputBroken {
            return .outputClosed(detail: outputFailure ?? "write failed")
        }
        return switch lines.closure {
        case .endOfInput: .inputClosed
        case let .readFailed(code): .inputFailed(code: code)
        }
    }

    /// Hands the session to the binary now on disk when it is no longer the one this process loaded: before `line` is answered, so the answer comes from the code that was installed.
    ///
    /// Returns only when this image carries on — nothing replaced, an input that has already ended (there is no session left to hand over), a replacement not yet due to be tried again, or one that could not be taken over, whose answers then carry the notice as they always did.
    private func handOverIfReplaced(_ line: String, input: LineInput) {
        guard let reexec, binaryIdentity != nil, !input.hasEnded,
              let onDisk = BinaryIdentity.capture(at: binaryPath),
              onDisk != binaryIdentity, replacementAttempts.allow(onDisk, at: Date())
        else { return }
        var unread = Data(line.utf8)
        unread.append(0x0A)
        unread.append(input.unread)
        let outcome = reexec.replace(
            handing: ServerHandover.Session(protocolVersion: protocolVersion, unread: unread),
            expecting: onDisk
        )
        let retry = replacementAttempts.record(outcome, for: onDisk, at: Date())
        log("sift mcp: the binary on disk was replaced and could not take this session over (\(outcome.reason)) — serving on from the old code, \(retry)")
    }

    private func handle(line: String) async {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            emit(errorID: NSNull(), code: -32700, message: "parse error")
            return
        }
        // A message without an id is a notification — the protocol forbids responding to it, whatever the method.
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        switch method {
        case "initialize":
            guard let id else { return }
            let params = message["params"] as? [String: Any]
            let requested = params?["protocolVersion"] as? String ?? "2025-06-18"
            protocolVersion = requested
            emit(resultID: id, result: [
                "protocolVersion": requested,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "sift", "version": SiftVersion.current],
            ])
        case "notifications/initialized", "notifications/cancelled":
            break
        case "ping":
            guard let id else { return }
            emit(resultID: id, result: [String: Any]())
        case "tools/list":
            guard let id else { return }
            emit(resultID: id, result: ["tools": toolList])
        case "tools/call":
            guard let id else { return }
            await handleToolCall(id: id, params: message["params"] as? [String: Any] ?? [:])
        default:
            if id != nil {
                emit(errorID: id ?? NSNull(), code: -32601, message: "method not found: \(method)")
            }
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) async {
        let name = params["name"] as? String ?? ""
        // The call exactly as it arrived, which is what the `PreToolUse` hook saw when it left its slip — so it
        // is what the slip is claimed with (`recordUsage`).
        let sent = params["arguments"] as? [String: Any] ?? [:]
        // Mutated in place by dispatch — the alias healing and the inline `root:` lift both belong here, so
        // the log below records what the call actually resolved to rather than what it was literally sent
        // under (Docs/Design.md §4: a healed `path:` must log as the `target:` it was read as).
        var arguments = sent
        let started = Date()
        // Filled in by dispatch as it learns it, so a call that fails after resolving still logs where it resolved.
        var root = defaultRoot.standardizedFileURL.path
        do {
            let answer = try await dispatch(tool: name, arguments: &arguments, root: &root)
            var text = answer.text
            if let notice = BinaryIdentity.replacementNotice(path: binaryPath, original: binaryIdentity) {
                // Under the header like every other note, not above it — the header leads every answer.
                text = Freshness.placing([notice], under: text)
            }
            // Counted here rather than where the engine built its answer, because Docs/Design.md §4 says the log records what
            // was *served*: the freshness header, an alias note, an adopted-root line and the replacement
            // notice are all bytes the caller paid for, and leaving them out would bias every savings figure
            // the one direction a savings figure must never be biased.
            //
            // Recorded for *every* answered call, not only the ones carrying a denominator. The served size
            // is the length of this string and needs no counterfactual at all, so withholding it from `where`
            // and `search` would leave a large share of the log recording nothing, while a savings figure
            // summed over the rest read as a statement about all of it. The denominator stays absent for them
            // — see `AnswerBytes`.
            recordUsage(
                tool: name,
                sent: sent,
                resolved: arguments,
                root: root,
                started: started,
                succeeded: true,
                answer: AnswerBytes(served: text.utf8.count, source: answer.bytes?.source),
                // What a `where` or `search` answer listed locates those files for a later window, unless it
                // answered as of another revision, whose files are not today's.
                located: arguments["at"] == nil ? DigestedFiles.locatedFiles(inAnswer: text, tool: name, parts: answer.parts) : [],
                miss: name == "digest" && DigestMiss.isMiss(inAnswer: text),
                parts: answer.parts
            )
            emit(resultID: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        } catch {
            recordUsage(tool: name, sent: sent, resolved: arguments, root: root, started: started, succeeded: false, error: "\(error)")
            emit(resultID: id, result: [
                "content": [["type": "text", "text": "\(error)"]],
                "isError": true,
            ])
        }
    }

    /// Logged after dispatch, before emission — a slow or failing log write can delay a response but can never corrupt one, and the entry reflects what actually happened rather than what was hoped.
    ///
    /// The caller is looked up rather than known: `tools/call` carries nothing that names the context that made it, and a subagent's calls arrive under its parent's session id. The `PreToolUse` hook that ran a moment ago does know, and left a slip keyed on this session naming the tool and target it saw (``CallAttribution``); it is claimed here only if it names *this* call, so a slip belonging to another call still in flight is left for it.
    ///
    /// The slip is claimed with the call as `sent` and the line logs it as `resolved`, and the two must not be swapped. The hook runs before this server heals anything, so it read its target from the raw arguments: claimed with the resolved ones, a `digest path:` healed to `target:`, or a `search` whose query had a `root:` lifted out of it, names a different target from its own slip, is never matched, and the subagent that made it goes unnamed — and ``DigestedFiles`` then refuses that subagent's whole read of a file it did digest. The log, though, records what was served: the resolved target is the one a later reader of the log matches a file against.
    ///
    /// `root` is the repository the answer was computed against, never the directory the call named: a rootless call is routinely answered from another repository, and every per-repository figure read off this log trusts the field.
    private func recordUsage(
        tool: String,
        sent: [String: Any],
        resolved: [String: Any],
        root: String,
        started: Date,
        succeeded: Bool,
        error: String? = nil,
        answer: AnswerBytes? = nil,
        located: [String] = [],
        miss: Bool = false,
        parts: [MeasuredAnswer.Part] = []
    ) {
        guard let usage else { return }
        let agent = session.flatMap { callers.take(session: $0, tool: tool, target: IndexCallTarget.of(sent, tool: tool)) }
        usage.record(
            tool: tool,
            target: IndexCallTarget.of(resolved, tool: tool),
            targets: IndexCallTarget.all(resolved),
            root: root,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000),
            succeeded: succeeded,
            error: error,
            answer: answer,
            agent: agent,
            located: located,
            miss: miss,
            parts: parts
        )
    }

    /// Answers one call, reporting through `root` the directory it was asked about and then, once an engine is resolved, the repository that engine answers from — and through `arguments`, the call as it was actually resolved, so a caller logging it afterwards (`recordUsage`) records what was served rather than what was literally sent.
    private func dispatch(tool: String, arguments: inout [String: Any], root: inout String) async throws -> MeasuredAnswer {
        // refused, and a search's inline root: is lifted out — through the one reading the transcript audit
        // names the same call by (`ArgumentAlias.resolved`), so the log and the audit cannot disagree. A
        // digest naming its targets under `targets:` has sent them where they go, so nothing is healed into
        // `target:` beside them — but a stray name-shaped key sent alongside `targets:` (`symbol:`, most often,
        // off a run of `where`) is refused rather than silently dropped: healing it would answer a call the
        // caller never made, and dropping it quietly would answer one target short of what was asked. The same
        // whether or not `target:` came too: the stray key is asked about as though `target:` were absent, since
        // a `target:` beside it stops it being healed, not being dropped.
        if tool == "digest", arguments["targets"] != nil,
           let stray = ArgumentAlias.resolve(tool: tool, arguments: arguments.filter { $0.key != "target" })
        {
            let carriers = arguments["target"] == nil ? "targets: already carries" : "target: and targets: already carry"
            throw MCPError(message: "digest was sent both targets: and \(stray.given): — \(stray.given): is only read as target: when target: is missing, and \(carriers) every target here; drop \(stray.given): or fold it into targets:.")
        }
        let aliasNote: String?
        if tool == "digest", arguments["targets"] != nil {
            aliasNote = nil
        } else {
            let resolution = ArgumentAlias.resolved(tool: tool, arguments: arguments)
            arguments = resolution.arguments
            aliasNote = resolution.healed.map { "read \($0.given): as \($0.wanted): — \(tool) names its argument \($0.wanted)." }
        }
        // The target has to be known *before* the engine is built, because in a session rooted above every
        // repo it is what decides which root answers (see `RootResolver`). A search carries a name too when
        // it asks about one, so it resolves like the other two rather than refusing what `digest` would heal;
        // a malformed query probes nothing and is rejected downstream, by the parse that knows what is wrong
        // with it.
        let digestTargets = tool == "digest" ? try Self.digestTargets(in: arguments) : []
        let probeTarget: String? = switch tool {
        case "digest": digestTargets.first
        case "where": arguments["symbol"] as? String
        case "search": (arguments["query"] as? String).flatMap { try? StructuralQuery($0).probeName }
        default: nil
        }
        let directory = (arguments["root"] as? String).map { URL(fileURLWithPath: $0) } ?? defaultRoot
        root = directory.standardizedFileURL.path
        let (engine, note) = try engine(for: directory, probing: probeTarget, namedExplicitly: arguments["root"] is String)
        root = engine.repoRoot.path
        let freshness = try await engine.ensureFresh()
        let body = try await answer(tool: tool, arguments: arguments, engine: engine, freshness: freshness)
        // Only the denominator rides through the framing untouched — the source this answer stands in for is
        // settled here and cannot change. What was served is counted once, at emission, where the last note
        // has been placed. Notes go under the header rather than above it: every answer here opens with one.
        return MeasuredAnswer(
            text: Freshness.placing([aliasNote, note], under: body.text),
            bytes: body.bytes,
            parts: body.parts
        )
    }

    private func answer(tool: String, arguments: [String: Any], engine: SiftEngine, freshness: Freshness) async throws -> MeasuredAnswer {
        switch tool {
        case "digest":
            let targets = try Self.digestTargets(in: arguments)
            guard !targets.isEmpty else {
                throw MCPError(message: ArgumentAlias.missingArgumentMessage(
                    tool: "digest", wanted: "target", arguments: arguments
                ))
            }
            let options = DigestOptions(
                includeAllAccess: arguments["all"] as? Bool ?? false,
                signaturesOnly: arguments["signaturesOnly"] as? Bool ?? false,
                offset: arguments["offset"] as? Int ?? 0,
                spelling: .toolCall
            )
            if let revision = try Self.atRevision(tool: "digest", arguments: arguments) {
                return try MeasuredAnswer(text: engine.digest(targets: targets, at: revision, options: options))
            }
            let digest = try engine.measuredDigest(targets: targets, options: options)
            let answer = freshness.noting(digest).headerLine + "\n" + digest.text
            return MeasuredAnswer(
                text: Freshness.placing([Self.spacedTargetNote(arguments: arguments, missed: digest.missed)], under: answer),
                bytes: digest.bytes,
                parts: digest.parts
            )
        case "where":
            guard let symbol = arguments["symbol"] as? String else {
                throw MCPError(message: ArgumentAlias.missingArgumentMessage(
                    tool: "where", wanted: "symbol", arguments: arguments
                ))
            }
            let options = WhereOptions(
                includeReferences: arguments["refs"] as? Bool ?? false,
                offset: arguments["offset"] as? Int ?? 0
            )
            if let revision = try Self.atRevision(tool: "where", arguments: arguments) {
                return try await MeasuredAnswer(text: engine.lookup(symbol: symbol, at: revision, options: options))
            }
            // No measurement past this point: a symbol lookup, a structural search and a catalog trace
            // stand in for a grep, not for a run of source, so there is no honest denominator to record.
            return try await MeasuredAnswer(text: engine.lookup(symbol: symbol, freshness: freshness, options: options))
        case "search":
            guard let query = arguments["query"] as? String else {
                throw MCPError(message: ArgumentAlias.missingArgumentMessage(
                    tool: "search", wanted: "query", arguments: arguments
                ))
            }
            return try await MeasuredAnswer(text: engine.search(
                query: query,
                offset: arguments["offset"] as? Int ?? 0,
                count: arguments["count"] as? Bool ?? false
            ))
        case "strings":
            guard let query = arguments["query"] as? String else {
                throw MCPError(message: ArgumentAlias.missingArgumentMessage(
                    tool: "strings", wanted: "query", arguments: arguments
                ))
            }
            return try MeasuredAnswer(text: engine.strings(query: query))
        default:
            throw MCPError(message: "unknown tool: \(tool)")
        }
    }

    /// The engine for this call, plus the line an adopted root has to announce itself with.
    ///
    /// Cached on the *resolved* root rather than the requested directory: the same session asking about two repos must get two engines, and the second must not be served the first one's index.
    private func engine(for directory: URL, probing target: String?, namedExplicitly: Bool) throws -> (SiftEngine, String?) {
        let resolved = try RootResolver.resolve(directory: directory, registry: registry, probing: target, namedExplicitly: namedExplicitly)
        let key = resolved.url.standardizedFileURL.path
        // A cached engine is reopened when its database file has gone — a `.sift/` wiped by a `git clean`, or a worktree removed and recreated at this path. The dead handle would otherwise answer every later call in the session with `SQLITE_IOERR`, permanently, while a fresh process on the same repo works perfectly (the index is a rebuildable cache, so reopening simply reindexes).
        if let cached = engines[key] {
            if cached.isUsable {
                return (cached, resolved.note)
            }
            engines[key] = nil
        }
        let engine = try SiftEngine(directory: resolved.url, registry: registry)
        engines[key] = engine
        return (engine, resolved.note)
    }

    /// Every target a `digest` call named: `target` as one, whatever it holds, then each of `targets` in order.
    ///
    /// `target` is never split. A path with a space in it — Xcode puts an app's sources under `My App/` by default — is one target, and splitting it answered a call that had always worked with two misses. Several targets have their own argument for exactly that reason, and a caller who sends both gets both.
    static func digestTargets(in arguments: [String: Any]) throws -> [String] {
        let single = (arguments["target"] as? String).map { [$0] } ?? []
        guard let several = arguments["targets"] else { return single }
        guard let targets = several as? [String] else {
            throw MCPError(message: "digest's targets: takes an array of strings, one target each — [\"Type.a\", \"Type.b\"]")
        }
        return single + targets
    }

    /// The revision an `at:` argument names, or `nil` when it is absent — never silently, when it is sent but isn't a string.
    static func atRevision(tool: String, arguments: [String: Any]) throws -> String? {
        guard let value = arguments["at"] else { return nil }
        guard let revision = value as? String else {
            throw MCPError(message: "\(tool)'s at: takes a revision name as a string, e.g. \"HEAD\" or a commit hash.")
        }
        return revision
    }

    /// The line a `target` with whitespace in it carries when it named nothing: that it was read as one target, and how several are sent.
    ///
    /// Only on a miss. A spaced path that resolves is exactly what `target` is for, and a note beside it would second-guess an answer that is right; a spaced value that names nothing is, far more often than not, several names sent where one goes.
    ///
    /// A path-shaped target — one with a `/`, a `.swift` suffix, or a line range — never gets the note, missed or not: a gitignored file with a space in its path answers correctly (the exclusion, not a miss — see `unindexedFileAnswer`) and the note above it would second-guess a right answer, while a mistyped spaced path is still one path wrongly spelled, not several names run together, and the advice to split it on whitespace is simply wrong.
    static func spacedTargetNote(arguments: [String: Any], missed: Bool) -> String? {
        guard missed, arguments["targets"] == nil,
              let target = arguments["target"] as? String, target.contains(where: \.isWhitespace),
              !target.contains("/"), !target.hasSuffix(".swift"), DigestLineRange.parse(target) == nil
        else { return nil }
        let pieces = target.split(whereSeparator: \.isWhitespace).map { "\"\($0)\"" }
        return "read target: as one name, whitespace included — several targets go in targets: [\(pieces.joined(separator: ", "))]"
    }

    // MARK: Emission (protocol JSON only)

    private func emit(resultID: Any?, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": resultID ?? NSNull(), "result": result])
    }

    private func emit(errorID: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": errorID, "error": ["code": code, "message": message]])
    }

    private var outputBroken = false
    /// What the failing write said, kept so the lifecycle entry names the cause rather than only the category.
    private var outputFailure: String?

    /// Writes through the throwing API — the ObjC-exception-raising `write(_:)` would kill the process the moment the client closes stdout; here a dead pipe just ends the session.
    private func write(_ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            log("sift mcp: failed to encode a response")
            return
        }
        data.append(0x0A)
        do {
            try output.write(contentsOf: data)
        } catch {
            outputBroken = true
            outputFailure = "\(error)"
            log("sift mcp: stdout closed — shutting down (\(error))")
        }
    }
}
