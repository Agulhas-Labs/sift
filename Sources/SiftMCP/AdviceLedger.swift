//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Decides whether a Swift lookup gets advised, and makes sure a session can never be stuck behind the advice.
///
/// The other two deliveries are advisory — the path-scoped rule and the session primer — and advice is easy to ignore at scale. So this one refuses the command rather than commenting on it: at the moment of the miss, a denial is the only form the model has to answer. That is a sharper instrument than either, and it is bounded on three sides deliberately.
///
/// **A retry always passes.** The same command is denied once and allowed the second time, so no command is ever unavailable and no session can wedge — the worst case is one round trip. That property is what makes denial defensible at all: some Swift greps are genuinely text searches the index cannot serve (a comment, a string literal, a name in a `.md`), and those have to remain possible without the model reasoning its way around a wall.
///
/// It is kept *mechanically*, which is not the same as keeping it by construction. The promise rests on one record, and two hook processes from one parallel tool batch can each load the state before the other saves, so a denial written by one would be overwritten by the other and the re-run it had promised refused a second time. ``withExclusiveAccess(_:)`` closes the race; ``decided(session:command:)`` closes what remains of it from the other end, by refusing nothing it could not write down. Between them there is no path on which the sentence is printed and the record is not there to honour it.
///
/// **It stops only on a runaway.** Every denial it prints now carries an answer or a build's wrapping, so a context that keeps drawing them is being served rather than ignored, and there is no run of unheeded denials to quiet it. What is left is ``nudgeCap``, a guard against a classification bug, and the spell it opens expires.
///
/// **A sanctioned re-run spends nothing.** The re-run is this hook's own escape hatch, offered in the text of every refusal, so counting it would score following the stated protocol as defying it.
public struct AdviceLedger: Sendable {
    /// Denials in one stretch of work, whatever happens — a runaway guard, not a budget.
    ///
    /// Nearly redundant, and kept anyway: a distinct command is only ever denied once, so reaching this at all takes a hundred *different* real commands. It exists to bound a classification bug, not ordinary use, which is why it opens a quiet spell rather than ending the advice — a context still working after a hundred distinct lookups is doing an enormous amount of work, not looping. Counted from the end of the last spell rather than from the session's first denial, so that a spell it opened is a pause and not a new standing rate.
    public static let nudgeCap = 100

    /// The first quiet spell, and the unit every later one is a doubling of.
    ///
    /// A phase of work — a sweep, a bulk edit — runs five to thirty minutes, so this covers most of one without covering a session.
    public static let baseQuietPeriod: TimeInterval = 15 * 60

    /// The longest a quiet spell ever gets, however many have come before it.
    ///
    /// Uncapped doubling reaches "the rest of the day" in five spells, which is a permanent silence arrived at by a slower road. A ceiling means an all-day session is still re-offered the advice periodically, and the cost of being wrong about a context is bounded by it.
    public static let maximumQuietPeriod: TimeInterval = 2 * 60 * 60

    /// How long an index call is taken to be possibly still unanswered: the span in which a call noted by the hook can be one sent beside the lookup now being judged.
    ///
    /// A message's calls start within seconds of one another, and a call noted longer ago than this has had its result written or never will, so past it the transcript is not asked.
    public static let inFlightWindow: TimeInterval = 60

    /// How long a session's ledger is kept after its last denial.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Beside the usage log, the roots registry and the tally cache — one place a user can delete to reset everything this tool remembers.
    public static func standard() -> AdviceLedger {
        AdviceLedger(directory: standardDirectory())
    }

    /// `~/.sift/advice`, or the directory `SIFT_ADVICE_DIR` names: where the ledger, the suppression log and the in-place answer's back-off are kept.
    ///
    /// An override for the same reason `SIFT_USAGE_LOG` is one: a test or a manual run that drives the built binary must leave no trace in the record a human reads. Empty is unset.
    public static func standardDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SIFT_ADVICE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return SiftPaths.home.appendingPathComponent("advice", isDirectory: true)
    }

    /// How long the `quiets`-th quiet spell lasts.
    ///
    /// Shifted rather than raised to a power, and clamped well below the point where the shift could overflow — the ceiling has already bitten by the fourth spell, so the clamp is arithmetic hygiene rather than a second policy.
    static func quietPeriod(after quiets: Int) -> TimeInterval {
        let doublings = min(max(0, quiets - 1), 20)
        return min(baseQuietPeriod * Double(1 << doublings), maximumQuietPeriod)
    }

    /// Whether to advise on `command` in `session`.
    ///
    /// **The query alone: what a denial costs this context is written down by ``noteDenial(session:command:)``, and only where a denial is actually printed.** The hook answers a lookup in place or lets it through, so `.advise` says the lookup is worth speaking about, not that anything was said — and a nudge is a fact about what the context was told. Charging them here would have every allowed lookup spending a budget nothing was bought with. What this does still write is the bookkeeping of a quiet spell it has just come out of, since the spell ends whether or not the lookup that ended it draws a word.
    ///
    /// A state directory that cannot be prepared resolves to `.allow`. Without somewhere to record what was denied, every command would be a first sighting and every one refused — the one outcome worse than the hook not existing.
    ///
    /// `offering` is the call the refusal would name, written as it would be typed and one element per line of it. Where this context has already made every one of them, the refusal has nothing to offer and the command is allowed — see ``noteIndexCall(session:calls:)``. Empty asks the ordinary question, which is what every caller holding no suggestion wants.
    ///
    /// **Where every offered call is made, the lookup may still be held back.** A call noted within ``inFlightWindow`` whose `tool_result` is not in the tail of the context's own transcript was sent beside this lookup and is not yet answered, so the lookup is `.pointAt` it rather than allowed (``ToolResultProbe/standing(ofToolUse:inTranscript:tailBytes:)``). Whether its `tool_use` line is written yet does not matter: the harness writes that late as well, and the tail is long enough that a result written within the window is inside it. `transcript` is the hook payload's `transcript_path` and `agent` its `agent_id`; the transcript read is the context's own (``ServerPresence/subagentTranscript(ofSession:agent:)``), so a subagent whose file is missing, a transcript that does not exist or cannot be read, and a call with no transcript at all, can never be held. `tailBytes` is how much of the transcript's end is read. The ledger's lock covers the state only: the transcript is read after it is released, since the file read is the slow part and nothing it decides is written back.
    public func decide(session: String, command: String, offering calls: [String] = [], transcript: String? = nil, agent: String? = nil, tailBytes: Int = ToolResultProbe.tailBytes) -> Decision {
        switch withExclusiveAccess({ decided(session: session, command: command, offering: calls, reads: transcript != nil) }) {
        case let .settled(decision):
            return decision
        case let .unanswered(candidates):
            guard let own = ServerPresence.subagentTranscript(ofSession: transcript, agent: agent) else { return .allow }
            let waiting = candidates.filter { candidate in
                switch ToolResultProbe.standing(ofToolUse: candidate.id, inTranscript: own, tailBytes: tailBytes) {
                case .answered, .unreadable: false
                case .unanswered, .unwritten: true
                }
            }
            return waiting.isEmpty ? .allow : .pointAt(waiting.map(\.call), hookMade: Set(waiting.filter(\.hookMade).map(\.call)))
        }
    }

    /// Which of `keys` this session's re-run allowance already covers: the lookups a refusal or an answer in place has been recorded for (``noteDenial(session:command:)``), whose identical re-run ``decide(session:command:offering:)`` allows.
    ///
    /// **A query and nothing more — it writes nothing and spends nothing.** Asked before `decide` by a caller holding a line of several lookups, so the advice is about the first of them this context has not already been answered on, rather than an allowance one lookup inherits from the lookup in front of it. Empty where the session has no state, which leaves the caller on the line's first lookup, as it always was.
    public func rerunsAllowed(session: String, among keys: [String]) -> Set<String> {
        withExclusiveAccess {
            guard let state = load(session) else { return [] }
            return Set(keys.filter { state.denied.contains(Self.key(for: $0)) })
        }
    }

    private func decided(session: String, command: String, offering calls: [String], reads: Bool = false) -> Outcome {
        guard var state = load(session) else { return .settled(.allow) }
        let original = state
        let moment = now().timeIntervalSince1970

        // A quiet spell held to its end, deliberately not lifted early by observed compliance: the cap that
        // opened it bounds a classification bug, and one index call is not evidence the bug has gone.
        if let until = state.quietUntil {
            guard moment >= until else { return .settled(.allow) }
            state.quietUntil = nil
            // Out of the spell with a full cap to spend again. A count that only ever rose would mean that
            // past the hundredth denial *every* decision re-entered the cap branch below and opened another
            // spell, so the advice would settle at one nudge per two hours for the rest of the session —
            // a permanent silence, arrived at by a different road. What survives
            // is the escalation: `quiets` is not reset, so each spell is longer than the last.
            state.nudges = 0
        }

        let key = Self.key(for: command)
        // The escape hatch this hook offers in the text of every refusal: re-run the exact command and it
        // is allowed. Taking it is following the protocol, not defying it, so it spends nothing — and it
        // is anyway indistinguishable from the legitimate case it exists for, a search for something the
        // index does not record.
        if state.denied.contains(key) {
            if state != original {
                save(state, session: session)
            }
            return .settled(.allow)
        }

        // **An offer this context has already taken up buys nothing, and a refusal that buys nothing is the
        // most expensive thing here.** A refusal alone in its turn costs a whole round trip — the context is
        // re-sent to say one sentence — and where the answer it points at is already in that context, the
        // sentence is one the context has read and acted on. Measured over a month of this machine's
        // sessions, a large minority of such refusals were followed by the identical command re-run
        // unchanged: the hook spent a round trip to be told again what it had already been told.
        //
        // The test is the *offered call*, never the symbol. A context that ran `digest Gizmo` and then greps
        // for what calls it is asking a question `digest` did not answer, and the `where Gizmo` the hook
        // offers is news; only a `where Gizmo` already made makes it not. Every line of the offer has to have
        // been made, so an alternation answered in part, or an offer capped with a line saying how many more
        // calls it stands for, is still worth saying.
        //
        // Nothing is spent and nothing is written: this is not a nudge withheld under a budget, it is a
        // refusal that had no content. The shape it exists for is the one case the index cannot be asked
        // about — verifying the index itself, where the empty answer under investigation is exactly what the
        // hook keeps offering back.
        if !calls.isEmpty, calls.allSatisfy({ state.calls.contains(Self.key(for: $0)) }) {
            if state != original {
                save(state, session: session)
            }
            // Made is not answered: a call sent beside this lookup is in the transcript as a use and not yet as a
            // result. The state says which calls are recent enough to be that; the transcript says which are.
            let recent = reads ? calls.compactMap { call -> InFlightCandidate? in
                guard let note = state.callNotes[Self.key(for: call)], moment - note.noted < Self.inFlightWindow else { return nil }
                return InFlightCandidate(call: call, id: note.id, hookMade: note.hookMade)
            } : []
            return recent.isEmpty ? .settled(.allow) : .unanswered(recent)
        }

        // Nothing of the denial is recorded here — that is ``noteDenial(session:command:)``'s, and it runs
        // only where a denial is printed. What may still need writing is a quiet spell this decision came out
        // of at the top, and it goes under the same rule as everything else on this path: a fact that cannot
        // be written down is not acted on, so a spell whose ending will not persist leaves the command alone
        // rather than reopening a budget the next decision would find shut again.
        guard state == original || save(state, session: session) else { return .settled(.allow) }
        return .settled(.advise)
    }

    /// Records a denial the hook is about to print, answering whether the record landed.
    ///
    /// **The refusal promises that the identical re-run will be allowed, and this record is the only thing that can keep it.** A denial nothing wrote down is a promise made and then broken silently, which is the one failure this mechanism cannot absorb: the escape hatch is what makes denial defensible at all, and a context that has watched it fail once has no reason to believe any other line the hook prints. So the promise is not made unless it can be kept — `false` here means the caller lets the command through, because an advice hook may never fail closed, and least of all on the sentence it stakes its credibility on.
    ///
    /// Split from ``decide(session:command:offering:)`` because the hook now answers a lookup in place or allows it: every count here is a count of what a context was *told*, and a lookup let through was told nothing. Recorded where the denial is printed, so `denied` still carries the key the re-run is recognised by and `calls` still carries what the answer served — which is what keeps rule 1 and the escape hatch working exactly as they did.
    @discardableResult
    public func noteDenial(session: String, command: String) -> Bool {
        withExclusiveAccess { notedDenial(session: session, command: command) }
    }

    private func notedDenial(session: String, command: String) -> Bool {
        guard var state = load(session) else { return false }
        state.denied.insert(Self.key(for: command))
        state.nudges += 1
        if state.nudges >= Self.nudgeCap {
            state.quiets += 1
            state.quietUntil = now().timeIntervalSince1970 + Self.quietPeriod(after: state.quiets)
        }
        // On the context's first denial, and at most once more per quiet spell after that: a directory that
        // grows by a file per session and never shrinks is the kind of thing that gets a tool uninstalled,
        // and a denial that has already paid for a write is where a listing costs least.
        if state.nudges == 1 {
            pruneSessions(olderThan: Self.retention)
        }
        return save(state, session: session)
    }

    /// Records the index calls `session` made, so a later refusal can tell whether the call it would offer is already answered in this context.
    ///
    /// Not a stat of `usage.jsonl` and `run.jsonl`: those logs record `tool`, `target` and `root` and no conversation identity at all — a subagent's MCP calls are indistinguishable from its parent's at the server, and no filter over them could be per context. The hook's payload *does* carry one, so the observation lives there: this is the only place on the machine where an index call and the conversation that made it are visible at the same moment. What it costs is the `PreToolUse` matcher covering this server's own tools, so the hook fires on them at all — a few milliseconds per index call, paid on the calls the whole mechanism exists to encourage.
    ///
    /// `calls` is what was asked, spelled the way a suggestion spells a call (``IndexSuggestion/callsMade(toolName:input:)``) — one element per target, so a `digest` of three files is three calls made and not one long name nothing will ever match. That record is what lets ``decide(session:command:offering:)`` tell a refusal with something to say from one offering a call this context has already made.
    ///
    /// `digests` is the digest targets among them, filed by the repository each is answered from — what lets a later whole read of a file this context has been served the digest of go through (``digests(session:)``).
    ///
    /// The last argument but one is the call's id from the payload, filed with the moment under each call's key (``State/callNotes``): what lets a later lookup ask whether the call has been answered yet (``decide(session:command:offering:transcript:agent:)``). A call made with no id leaves its key with none, so the question is never asked of it.
    ///
    /// The last argument says the hook made the calls itself, answering a lookup in place, rather than the context: they are filed under the lookup's own id, and a pointer at one is worded as an answer given beside the lookup, never as a call the context made.
    public func noteIndexCall(session: String, calls: [String] = [], digests: [String: [String]] = [:], toolUseID: String? = nil, madeByHook: Bool = false) {
        withExclusiveAccess { noted(session: session, calls: calls, digests: digests, toolUseID: toolUseID, madeByHook: madeByHook) }
    }

    private func noted(session: String, calls: [String], digests: [String: [String]], toolUseID: String?, madeByHook: Bool) {
        guard var state = load(session) else { return }
        let original = state
        // This is the one write here that can create a file, and a compliant context may never take the
        // denial whose prune would otherwise sweep the directory: pruned once, where the file is first written.
        let first = original == State()
        for call in calls {
            let spelling = Self.key(for: call)
            guard !spelling.isEmpty else { continue }
            state.calls.insert(spelling)
            state.callNotes[spelling] = toolUseID.flatMap { $0.isEmpty ? nil : CallNote(id: $0, noted: now().timeIntervalSince1970, hookMade: madeByHook) }
        }
        for (root, targets) in digests where !root.isEmpty {
            state.digests[root, default: []].formUnion(targets.filter { !$0.isEmpty })
        }
        guard state != original else { return }
        save(state, session: session)
        if first {
            pruneSessions(olderThan: Self.retention)
        }
    }

    /// Takes back digest targets ``noteIndexCall(session:calls:digests:)`` recorded, for a digest whose answer turned out to resolve nothing.
    ///
    /// The note is made when the call is about to run, before any answer exists, so a digest that missed has already been recorded as held; a context that was served nothing of the file must not be let read a window of it on that record. Only the targets named are removed, and only from the root named, so what other digests of the context recorded stays.
    public func forgetDigests(session: String, digests: [String: [String]]) {
        withExclusiveAccess {
            guard var state = load(session) else { return }
            let original = state
            for (root, targets) in digests {
                guard var held = state.digests[root] else { continue }
                held.subtract(targets)
                state.digests[root] = held.isEmpty ? nil : held
            }
            guard state != original else { return }
            save(state, session: session)
        }
    }

    /// Records a file `session` wrote or edited, so a later read of it is let through as the revisit it is.
    ///
    /// Kept by path, spelled out in full and standardised, because the question is about this one file and never about a name: ``holds(_:session:)`` asks it the same way.
    public func noteWritten(session: String, path: String) {
        let file = Self.heldPath(path)
        withExclusiveAccess {
            guard var state = load(session) else { return }
            let first = state == State()
            guard state.written.insert(file).inserted, save(state, session: session), first else { return }
            pruneSessions(olderThan: Self.retention)
        }
    }

    /// Whether `session` wrote or edited the file at `path`, which puts its text in that context already.
    public func holds(_ path: String, session: String) -> Bool {
        guard let data = try? Data(contentsOf: url(for: session)),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return false }
        return state.written.contains(Self.heldPath(path))
    }

    /// A path as the written set keeps it: standardised, so a dot segment on either side does not make the same file two.
    private static func heldPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The digest targets `session` has asked for, keyed by the repository each was answered from; empty where nothing is recorded.
    ///
    /// Read without the lock: nothing here is written back, and a write racing it leaves either the old file or the new one to read, never half of one.
    public func digests(session: String) -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: url(for: session)),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return [:] }
        return state.digests
    }

    /// Whitespace-collapsed, so a re-run that differs only in formatting still counts as the same command.
    static func key(for command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The key a shell command is remembered by: what it runs, with its comments taken out (``ShellSyntax/withoutComments(_:)``) as well as its formatting.
    ///
    /// A refused command is often re-run with a comment dropped or reworded, and nothing it runs has changed — so to the promise that the identical re-run passes it is the identical command. Only a shell command is read this way: a `Grep` key holds a pattern, where a `#` is the text being looked for.
    public static func key(forShell command: String) -> String {
        key(for: ShellSyntax.withoutComments(command))
    }

    /// The name of the one file in the state directory that is a lock rather than a session.
    ///
    /// A fixed name, not one per session: there is exactly one of it, so nothing has to prune it, and it is not a `.json` so ``pruneSessions(olderThan:)`` never sees it. A per-session lock file would be a file per session that nothing ever removes, which is the shape of leak that gets a tool uninstalled — the very thing the prune exists to prevent. What a directory-wide lock costs is that two *different* sessions serialise on a critical section of one small read and one small write, against a hook process that already costs milliseconds.
    private static var lockFileName: String {
        ".lock"
    }

    /// Runs `body` with an exclusive lock on this ledger's state held.
    ///
    /// **Every entry point here is a load, a mutation and a save, and the save being atomic does not make the three of them atomic.** One assistant message carrying `mcp__sift__digest Foo` and `Read Bar.swift` as parallel calls — the shape this tool's own guidance asks for — starts two hook processes against the same session at once: `noteIndexCall` records the digest, and `decide`, holding the snapshot it loaded before that, writes the state back without it. The call is lost, and the next refusal offers this context a call it has already made.
    ///
    /// `flock` rather than an exclusive-create lock file, because the kernel releases it when the descriptor closes — including when the process dies holding it — so there is no stale lock to time out and no wedged hook. It blocks rather than spinning: the critical section is one small read and one small write, and the only thing that can hold it is another hook process doing the same.
    ///
    /// **Unavailable is not fatal.** A directory that cannot be created or a lock that cannot be taken runs the body anyway, unserialised — an advice hook may never fail closed.
    private func withExclusiveAccess<T>(_ body: () -> T) -> T {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else {
            return body()
        }
        let descriptor = open(directory.appendingPathComponent(Self.lockFileName).path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            // A signal interrupting the wait is not a failure to lock; anything else is, and runs unlocked.
            guard errno == EINTR else { return body() }
        }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    /// The session's state, or `nil` when there is nowhere to keep it.
    private func load(_ session: String) -> State? {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        guard let data = try? Data(contentsOf: url(for: session)),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else {
            return State()
        }
        return state
    }

    /// Writes the session's state, answering whether it landed.
    ///
    /// The answer is what ``decided(session:command:)`` gates a refusal on, so it is a return value rather than a swallowed `try?`. Every other caller here is recording an observation — compliance, a cleared spell — where a lost write costs a nudge; only the denial has a promise riding on it.
    @discardableResult
    private func save(_ state: State, session: String) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try data.write(to: url(for: session), options: .atomic)
        } catch {
            return false
        }
        return true
    }

    /// Forgets sessions untouched for `age`, and reuse-nudge marks claimed that long ago alongside them.
    ///
    /// Long enough that a session resumed the next morning keeps what it has learned, and short enough that the directory stays a handful of files. A session older than this being forgotten costs one nudge, which is the mechanism working. The `reuse` subdirectory is the same shape of leak the ledger itself guards against — a file per nudge given that nothing else ever removes — so it gets the same retention in the same pass, by mtime rather than extension: a mark carries no session identity of its own to key a session's forgetting on.
    func pruneSessions(olderThan age: TimeInterval) {
        let cutoff = now().addingTimeInterval(-age)
        prune(directory, keeping: { $0.pathExtension == "json" }, olderThan: cutoff)
        prune(directory.appendingPathComponent("reuse", isDirectory: true), keeping: { _ in true }, olderThan: cutoff)
    }

    /// Removes every entry of `directory` that `keeping` admits and whose modification date is before `cutoff`, ignoring a directory that does not exist.
    private func prune(_ directory: URL, keeping: (URL) -> Bool, olderThan cutoff: Date) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for entry in entries where keeping(entry) {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func url(for session: String) -> URL {
        // A session id arrives from someone else's payload, so it is not trusted as a file name.
        let safe = session.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("\(safe.isEmpty ? "unknown" : safe).json")
    }
}

public extension AdviceLedger {
    /// What to do with a lookup.
    enum Decision: Equatable, Sendable {
        /// First sighting: worth speaking about — answered in place where the shape allows one, and otherwise let through.
        case advise
        /// A retry, a quiet spell, or nowhere to keep state — let it through without a word.
        case allow
        /// Every call the refusal would have offered is made, but these were sent beside the lookup and are not yet answered: hold it back with a pointer at them, each as it was offered.
        ///
        /// `hookMade` is the subset the hook made itself, answering a lookup in place, which the context never called.
        case pointAt([String], hookMade: Set<String> = [])
    }
}

extension AdviceLedger {
    /// What the locked half of a decision settled: a ``Decision``, or the offered calls that may still be in flight and need the transcript to say.
    enum Outcome {
        case settled(Decision)
        case unanswered([InFlightCandidate])
    }

    /// An offered call noted recently enough to be unanswered still: its spelling, the id its result is looked for under, and whether the hook made it.
    struct InFlightCandidate {
        var call: String
        var id: String
        var hookMade: Bool
    }

    /// One file per conversation, for the same reason as the usage log: concurrent sessions each run their own hooks, and a shared file would have them overwriting each other's counts.
    ///
    /// A subagent gets its own, keyed by `AdviceContext`, rather than sharing its parent's on the argument that the parent and its subagents are one piece of work, so one of them proving the advice unwanted proves it for all. That argument is sound about *intent* and wrong about *knowledge*: the ledger exists to avoid telling a context something it has already been told, and a subagent has not been told anything. It starts empty and cannot see what the parent was offered, so inheriting only the verdict would have a parent that waved off three suggestions spawning subagents that were mute before their first tool call.
    ///
    /// Subagents are where the heaviest whole-file reading happens, which makes them the worst possible context to silence by inheritance.
    ///
    /// **Retired fields are not read back**: `ignoredKeys`, the set of sanctioned re-runs, and `silenced`, the permanent latch it fed; and the unheeded-run count, the refusal count and the reached and diagnosed flags, which fed a run-based quiet spell and a diagnosis of a context that could not reach the index, both retired once the hook began answering lookups in place. Decoding ignores them, so a ledger that still carries them keeps its `denied` set and its counts and simply stops being silent, rather than losing state — and the files age out inside a week regardless.
    ///
    /// **The same goes for `usageStamp`**, a machine-wide log modification time. Whether the advice is landing is decided by an index call seen in *this* context (``AdviceLedger/noteIndexCall(session:)``), so there is no stamp to keep. A ledger holding one decodes without it and keeps everything else.
    ///
    /// **Every field is decoded as optional-with-a-default, and that is the whole reason `init(from:)` is written out.** Synthesised decoding fails outright on a key that is merely absent, so adding a field would make every ledger written before it undecodable. A ledger that fails to decode is read as a fresh one, which means a context's whole `denied` set vanishes and the next fifteen commands it has already been refused are refused again. That is the exact failure this hook cannot afford, and it would ship silently: nothing about it is visible except a run of repeat denials in someone else's session. A field added to this struct must never be able to do that.
    struct State: Codable, Equatable {
        var denied: Set<String> = []
        var nudges = 0
        /// When the advice may speak again, or `nil` when it is not in a quiet spell.
        var quietUntil: Double?
        /// Quiet spells this context has been through, which is what makes the next one longer.
        var quiets = 0
        /// The index calls this context has made, each spelled the way a suggestion spells its call.
        ///
        /// The one thing a refusal cannot know from its own side: whether the call it is about to offer is already answered in the window it is interrupting. Never cleared by a quiet spell beginning and ending — a call answered inside one still answered it. It does go stale the way the rest of this state does: an auto-compacted or resumed session keeps the same session id with a context that no longer holds what it asked for, and this file lives the same seven days as everything else here (``denied`` included, which accepts the same staleness).
        var calls: Set<String> = []

        /// The digest targets this context has asked for, by any route, keyed by the repository each was answered from.
        ///
        /// Kept apart from ``calls`` because it answers a different question — whether a whole read of a file would be handed a digest this context already holds — and takes in a Bash `sift digest`, which ``calls`` deliberately does not.
        var digests: [String: Set<String>] = [:]

        /// When and under which `tool_use_id` each of ``calls`` was last noted, by the same key.
        ///
        /// What tells a call sent beside a lookup from one answered long ago: recent, and its id without a result in the transcript. A call noted again replaces its note, and one noted with no id drops it.
        var callNotes: [String: CallNote] = [:]

        /// The files this context wrote or edited, by standardised path: text it holds already, so a read of one is a revisit.
        var written: Set<String> = []

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            denied = try container.decodeIfPresent(Set<String>.self, forKey: .denied) ?? []
            nudges = try container.decodeIfPresent(Int.self, forKey: .nudges) ?? 0
            quietUntil = try container.decodeIfPresent(Double.self, forKey: .quietUntil)
            quiets = try container.decodeIfPresent(Int.self, forKey: .quiets) ?? 0
            calls = try container.decodeIfPresent(Set<String>.self, forKey: .calls) ?? []
            digests = try container.decodeIfPresent([String: Set<String>].self, forKey: .digests) ?? [:]
            written = try container.decodeIfPresent(Set<String>.self, forKey: .written) ?? []
            callNotes = try container.decodeIfPresent([String: CallNote].self, forKey: .callNotes) ?? [:]
        }
    }

    /// An index call as noted: the id the harness gave it, and the moment the hook saw it.
    struct CallNote: Codable, Equatable {
        var id: String
        var noted: Double
        /// Whether the hook made the call, answering a lookup in place, rather than the context; a note written before this was kept reads as the context's.
        var hookMade = false

        init(id: String, noted: Double, hookMade: Bool = false) {
            self.id = id
            self.noted = noted
            self.hookMade = hookMade
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            noted = try container.decode(Double.self, forKey: .noted)
            hookMade = try container.decodeIfPresent(Bool.self, forKey: .hookMade) ?? false
        }
    }
}
