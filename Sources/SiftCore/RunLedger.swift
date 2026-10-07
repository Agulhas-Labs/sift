//
// Copyright © Agulhas Labs
//

import Foundation

/// Which trees a command has already been proved green on, so a gate does not run a suite whose answer for this exact tree is already known.
///
/// The verify loop this repository asks for ends in `swift test`, and the `pre-push` hook then runs the same suite over the same bytes. Measured across one session that was six re-runs in the main checkout and one per subagent push, at 70–110 seconds each — half an hour of a suite whose result was already in hand. Worse than the wall clock: a second execution of a suite with a known race is a second roll of the dice, and it is most likely to land on a busy machine, which is exactly when several agents are pushing.
///
/// **Only a green run proves, and every doubt is resolved toward running.** A record is written for a run that passed with nothing unaccounted for (``RunOutcome/provedGreen(testBundles:selector:)``), keyed on the content of the tree it ran on and refused the moment anything the key cannot see is in question: a different toolchain, or simply age. A red run of tests is filed too, but in a sibling file (``failedRuns``), never in this one: a green run older than a red one of the same command on the same content proves nothing, and an absent record is a run.
///
/// **What the key covers is what git can see, and the window is what covers the rest.** A gitignored build directory, this tool's own state under `.sift` and `~/.sift`, an environment variable the suite branches on and the machine itself are all outside ``TreeKey`` by construction. None of them is folded in — a key over the build directory would change on every build and prove nothing, and an environment allowlist would be a guess at which variables matter. The bound is what makes their absence safe: ``trustWindow`` is short enough that a record can only ever stand for a tree still on the machine that proved it, in the session that proved it.
///
/// **One ledger per repository, shared by every worktree of it**, under the git directory they all share (`git rev-parse --git-common-dir`) rather than in any one checkout's cache. The key is content, and identical content in two worktrees is one tree: a suite proved green in an agent's worktree stands for the same tree pushed from the primary checkout, where a ledger per checkout would run it again. Each record names the checkout it ran in, so a proof standing on another worktree's run still says where that run happened. The transcripts stay where each run wrote them, under its own checkout's `.sift/runs`. Nothing the ledger holds can reach a tracked file, and it dies with the repository.
public struct RunLedger: Sendable {
    /// How long a green run may stand for its tree before the suite is run again.
    ///
    /// An hour, and the argument for it is what the record does *not* cover rather than what it does. The saving exists for a gap measured in minutes — verify, commit, push — and the longest real gap is a review round of tens of minutes, so an hour buys every case the feature was built for and nothing beyond. What an hour costs, in exchange, is bounded: a toolchain switch, an `xcode-select`, an edit to a gitignored file a test reads, or a changed environment variable can each make a record wrong, and after an hour none of them can, because the suite simply runs. A day would cover no case anyone has and would make every one of those a live hazard overnight.
    public static let trustWindow: TimeInterval = 60 * 60

    /// How many records the file keeps.
    ///
    /// A record outlives its usefulness at ``trustWindow`` anyway, and expired ones are dropped whenever the file is written, so this is a bound on a pathological case rather than a retention policy: a machine writing green runs faster than they expire. Sixty covers every tree the worktrees of one repository plausibly hold within an hour — several agents' worktrees at a few green runs each, and a branch switched back and forth keeping both sides proved — at some tens of kilobytes.
    public static let keptRecords = 60

    /// The stamp this sift puts on every record it writes, and the least a green record must carry to prove anything.
    ///
    /// **A green written or rewritten by an older sift is not a proof.** An older sift filing a green clears the reds of that run whatever their date, under a lock of its own, so during a deploy its green can delete a red that finished after it. No reader can see a deletion, but a sift from before the stamp existed writes records without one: its coding is synthesized and drops a field it does not know on the whole file it rewrites. A later sift keeps the stamp a record carries when it rewrites the file, so after a format bump an older stamped sift leaves the newer stamps alone and stamps its own greens with its own, lower format, which a newer reader refuses. So a green without the stamp is read as absent and the suite runs. Losing this field turns a proof into a refusal, never the reverse, which is why it may live on the records when a red never could. Raised whenever a writer's rules for clearing a red change.
    public static let writerFormat = 2

    /// The environment variable that turns the ledger off: no green run is written and no question is answered *proved*.
    ///
    /// **A red run of tests is still filed, and still deletes the green it contradicts.** The switch is read per process, so a green filed with it on would otherwise outlive a red run with it off and prove the tree to the next process that has it on. Both writes can only refuse, so honouring them costs at most one suite run.
    public static var switchName: String {
        "SIFT_RUN_LEDGER"
    }

    public let fileURL: URL

    /// The sidecar file whose lock serialises every writer of the ledger: `<file>.lock` beside it, and for ``failedRuns`` the ledger's own, so one lock covers both files.
    private let lockURL: URL

    private let note: @Sendable (String) -> Void

    public init(fileURL: URL, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(fileURL: fileURL, lockURL: fileURL.appendingPathExtension("lock"), note: note)
    }

    private init(fileURL: URL, lockURL: URL, note: @escaping @Sendable (String) -> Void) {
        self.fileURL = fileURL
        self.lockURL = lockURL
        self.note = note
    }
}

public extension RunLedger {
    /// The ledger every worktree of the repository at `repositoryRoot` shares: `<git-common-dir>/sift/proved-runs.json`.
    ///
    /// Where git names no common directory — a directory that is not a repository at all, which is what a test scoping its writes hands in — the ledger is the one in that directory's own cache instead. No tree key can be taken outside a repository, so nothing real is ever asked of that file.
    static func inRepository(at repositoryRoot: URL, note: @escaping @Sendable (String) -> Void = { _ in }) -> RunLedger {
        let directory = GitContext.commonDirectory(of: repositoryRoot).map { $0.appendingPathComponent(sharedDirectoryName) }
            ?? SiftPaths.cache(in: repositoryRoot)
        return RunLedger(fileURL: directory.appendingPathComponent(fileName), note: note)
    }

    /// What the ledger is called inside its directory.
    static var fileName: String {
        "proved-runs.json"
    }

    /// The red runs of tests beside this ledger: `failed-runs.json` in the same directory, which ``trust(tree:command:toolchain:workingDirectory:now:environment:)`` reads so a green run a later red one contradicts proves nothing.
    ///
    /// **A sibling file, never a field on this file's records.** A sift from before red runs were filed decodes this file and rewrites it whole on its next green run, dropping any field it does not know; a red record marked by a field would come back from that rewrite as a proof.
    ///
    /// **It takes this ledger's lock, not one of its own**, because a red and a green each write both files and a red must never land between a green's two writes: see ``recordGreen(_:)``.
    var failedRuns: RunLedger {
        RunLedger(fileURL: fileURL.deletingLastPathComponent().appendingPathComponent(Self.failedRunsFileName), lockURL: lockURL, note: note)
    }

    /// What ``failedRuns`` is called inside the ledger's directory.
    static var failedRunsFileName: String {
        "failed-runs.json"
    }

    /// The trees green `sift run` builds and tests have run on in the checkout at `checkoutRoot`: `<checkout>/.sift/green-builds.json`, which is what the stop gate reads before it asks for a build.
    ///
    /// **A second file, never a record in the proved ledger.** A build proves no suite, and a record there would answer `sift run --proved` and the `pre-push` hook for a tree no test read, or push a real proof out of its bounded slots. **One per checkout, not shared**, because a build answers for the checkout it compiled: a linked worktree holding the same content has built nothing, and records the shared file keys on content alone would replace each other across worktrees. Its records name no toolchain — the gate asks only which tree a green run saw, and a `swift --version` per build would buy nothing.
    static func greenBuilds(inCheckout checkoutRoot: URL) -> RunLedger {
        RunLedger(fileURL: SiftPaths.cache(in: checkoutRoot).appendingPathComponent(greenBuildsFileName))
    }

    /// What ``greenBuilds(inCheckout:)`` is called inside the checkout's cache.
    static var greenBuildsFileName: String {
        "green-builds.json"
    }

    /// The directory the ledger sits in under the git common directory, named for this tool.
    static var sharedDirectoryName: String {
        "sift"
    }

    /// Whether the switch in `environment` leaves the ledger working.
    ///
    /// Off for `0` alone, so a variable set to anything else — including the empty string a shell leaves behind — reads as on rather than as a silent opt-out nobody meant.
    static func isOn(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[switchName] != "0"
    }

    /// One run that passed, and the tree it passed on.
    struct Record: Sendable, Equatable, Codable {
        /// The tree object the working tree's visible content hashed to.
        public let tree: String
        /// The wrapped command, as argv was spelled — two different invocations prove two different things.
        public let command: String
        /// How the toolchain that ran it named itself.
        public let toolchain: String
        /// When the run finished.
        public let finishedAt: Date
        /// The transcript's file name under `.sift/runs`, so the skip can name the run it is trusting; `nil` where no log was opened.
        public let log: String?
        /// How long the run took, which is what a skip saves and therefore what it may claim.
        public let milliseconds: Int
        /// The working tree the run happened in, since the ledger is shared by every worktree of the repository and a proof must say where it was earned; `nil` in a record written before the ledger was shared.
        public let checkout: String?
        /// The command's working directory, relative to the repository root — `"."` for the root itself (the same spelling ``TreeContentHash/invocation(of:in:repositoryRoot:)`` uses), `"Packages/Foo"` for a nested package.
        ///
        /// So a suite run from inside a package never stands for one run from the whole repository, or the reverse, while the same relative directory in a second worktree still matches. `nil` in a record written before this field existed; such a record cannot say where it really ran, so it is treated as the root — matching only a lookup that asks about the root, never one asking about anywhere else.
        public let workingDirectory: String?
        /// The ``RunLedger/writerFormat`` of the sift that wrote the record; `nil` where an older sift wrote or rewrote it.
        public let writerFormat: Int?

        public init(tree: String, command: String, toolchain: String, finishedAt: Date, log: String?, milliseconds: Int, checkout: String? = nil, workingDirectory: String? = nil) {
            self.tree = tree
            self.command = command
            self.toolchain = toolchain
            self.finishedAt = finishedAt
            self.log = log
            self.milliseconds = milliseconds
            self.checkout = checkout
            self.workingDirectory = workingDirectory
            writerFormat = RunLedger.writerFormat
        }

        /// Whether `other` records the same run — the same tree, command, toolchain and working directory — whenever it finished.
        ///
        /// A missing working directory is the root here as everywhere else the ledger reads one, so a red filed from the root deletes a green an older sift filed without the field.
        func isSameRun(as other: Self) -> Bool {
            tree == other.tree && command == other.command && toolchain == other.toolchain
                && (workingDirectory ?? ".") == (other.workingDirectory ?? ".")
        }
    }

    /// Whether this tree and this command may stand on a run already made, and why not when they may not.
    enum Trust: Sendable, Equatable {
        /// A green run of this command on this tree content, under this toolchain, inside the window.
        case proved(Record)
        /// No such run, with the reason a reader has to act on.
        case notProved(Reason)
    }

    /// Why a question was not answered *proved* — different facts, which a reader acts on differently.
    enum Reason: Sendable, Equatable {
        /// Nothing in the ledger has this command passing on this tree's content, from any directory.
        case noRecord
        /// A green run of this tree, command and toolchain exists, but only from a different working directory.
        case noRecordHere(here: String, recorded: [String])
        /// A green run of this tree exists, under a toolchain that is not the one asking.
        case otherToolchain(recorded: String)
        /// A green run of this tree under this toolchain exists, and is older than the window allows.
        case tooOld(age: TimeInterval)
        /// The same run, dated after the clock reading it — a record no age can be computed from, and so one nothing may stand on.
        case aheadOfTheClock
        /// A green run of this tree under this toolchain exists inside the window, and a red run of the same command on the same content, from the same directory, finished `age` ago, no earlier than it; `log` is the red run's transcript.
        case laterRunFailed(age: TimeInterval, log: String?)
        /// The ledger was switched off in this environment.
        case switchedOff
        /// The question itself could not be put: no repository, no tree key, or no toolchain to name.
        case cannotAsk(String)
    }

    /// Appends `record`, dropping what has expired and keeping the newest ``keptRecords``.
    ///
    /// Best-effort on the same terms as every other ledger this tool keeps: a record is a note about work already done, never a precondition for it, so a failure notes itself once and changes nothing the caller saw. Losing a record costs one suite run, which is the direction every failure here resolves in.
    ///
    /// Written whole and renamed into place rather than appended to, because a reader must never see half a file: the cost of rewriting is a few kilobytes once per green run.
    ///
    /// **The read, the rewrite and the rename happen under one exclusive lock**, because every worktree of the repository shares the file and two green runs finishing together would otherwise each read the old file and each rename their own version over it, losing one record. A lost record is not a cheap re-run: the pre-push hook refuses a tree it cannot find proved, so the loser pays a whole second suite and a turn for a tree it had just proved. Readers take no lock — the rename already guarantees they see a whole file. A lock that cannot be had notes itself and the write goes ahead unserialised, as it did before there was one.
    func record(_ record: Record) {
        guard makeDirectory() else {
            return
        }
        whileLocked { rewrite(adding: record) }
    }

    /// Drops every record of the same run as `record` — same tree, command, toolchain and working directory — leaving the rest; a file with nothing to drop is not written.
    ///
    /// What a green run does to ``failedRuns`` through ``recordGreen(_:)``, once no red of that run on file is dated to the green's second or later. And what a red run does to this ledger, through `recordFailure(_:)`.
    func forget(runOf record: Record) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        whileLocked { drop(runOf: record) }
    }

    /// Files `red` in ``failedRuns`` after dropping every green record of the same run from this ledger.
    ///
    /// **The green goes, not only outranked.** ``failedRuns`` keeps ``keptRecords`` like this file, and every worktree files its reds there, so enough reds on other trees inside the window push this one out while the green it contradicted is still here; a gate asking afterwards would stand on that green. Deleting it adds no field, so a sift from before red runs were filed reads the file as before. Dropped first, so a write cut short between the two leaves the tree refused. **Both writes under one hold of the lock** ``recordGreen(_:)`` takes too.
    func recordFailure(_ red: Record) {
        guard makeDirectory() else {
            return
        }
        whileLocked {
            drop(runOf: red)
            failedRuns.rewrite(adding: red)
        }
    }

    /// Files `green` in this ledger and drops the red records of the same run from ``failedRuns`` — unless a red of that run finished after it, when neither file changes.
    ///
    /// **Both writes under one hold of the lock ``recordFailure(_:)`` takes**, so a red can never land between them. And a green is checked against the reds already on file, because holding the lock orders the writes, not the runs: a green that finished before a red but reached the lock after it would otherwise delete that red and stand as the proof of a tree whose newest run failed. **A red in the same whole second as the green counts as after it**: the file keeps whole seconds, so a red dated to the green's second may have finished after the green, and the two cannot be told apart. The green is compared by its own second, never its fraction, and refused; a red followed by a green inside one second costs one more suite run, the direction every failure here takes.
    func recordGreen(_ green: Record) {
        guard makeDirectory() else {
            return
        }
        let greenSecond = Date(timeIntervalSince1970: green.finishedAt.timeIntervalSince1970.rounded(.down))
        whileLocked {
            let failed = failedRuns
            guard !failed.records().contains(where: { $0.isSameRun(as: green) && $0.finishedAt >= greenSecond }) else {
                return
            }
            rewrite(adding: green)
            failed.drop(runOf: green)
        }
    }

    /// Every record on file, newest first, or nothing at all where the file is missing or will not parse.
    ///
    /// A file that will not parse is read as an empty ledger, which runs the suite. There is no repair path and none is wanted: the next green run rewrites it whole.
    func records() -> [Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([Record].self, from: data)
        else {
            return []
        }
        return decoded.sorted { $0.finishedAt > $1.finishedAt }
    }
}

private extension RunLedger {
    /// Creates the ledger's directory, noting a failure once; `false` where it could not be made.
    func makeDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            return true
        } catch {
            note("sift run: proved-run ledger write failed (\(error))")
            return false
        }
    }

    /// Drops every record of the same run as `record` from the file, unlocked — the caller holds the lock.
    func drop(runOf record: Record) {
        let kept = records()
        let surviving = kept.filter { !$0.isSameRun(as: record) }
        if surviving.count != kept.count {
            write(surviving)
        }
    }

    /// Runs `body` holding an exclusive lock on ``lockURL``, or unlocked after one note when the lock cannot be had.
    ///
    /// `flock` for the reason ``FileLock`` gives — the kernel lets go when the descriptor closes, however the holder ends — and a blocking wait rather than a deadline, because the only holder is another writer doing one small read and one small write, and this runs after a suite, never between a tool call and its answer.
    ///
    /// **Never nested**: a second open of the same file takes a lock of its own, so `body` locking again — directly, or through ``failedRuns``, which shares this lock — would wait on itself forever. Inside it, `rewrite(adding:)` and `drop(runOf:)` write unlocked.
    func whileLocked(_ body: () -> Void) {
        let descriptor = open(lockURL.path, O_CREAT | O_RDONLY | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            note("sift run: proved-run ledger lock unavailable (\(String(cString: strerror(errno))))")
            return body()
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            // A signal interrupting the wait is not a failure to lock; anything else is, and writes unlocked.
            guard code == EINTR else {
                note("sift run: proved-run ledger lock unavailable (\(String(cString: strerror(code))))")
                return body()
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        body()
    }

    /// Reads the file, puts `record` at its head in place of any record for the same run, trims it and renames the result into place.
    func rewrite(adding record: Record) {
        var kept = records()
        kept.removeAll { $0.isSameRun(as: record) }
        kept.insert(record, at: 0)
        let cutoff = record.finishedAt.addingTimeInterval(-Self.trustWindow)
        write(Array(kept.filter { $0.finishedAt > cutoff }.prefix(Self.keptRecords)))
    }

    /// Encodes `surviving` and renames it into place, noting a failure once.
    func write(_ surviving: [Record]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(surviving) else {
            note("sift run: proved-run ledger entry failed to encode")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            note("sift run: proved-run ledger write failed (\(error))")
        }
    }
}

public extension RunLedger {
    /// The newest green run of `command` from `workingDirectory` on record, whatever tree or toolchain it ran on — what a question that was not answered *proved* is measured against.
    ///
    /// Only a green ``trust(tree:command:toolchain:workingDirectory:now:environment:)`` would read: one an older sift wrote is as absent here as there, or the answer would cite it as the last green of a tree it calls unrecorded.
    func lastGreen(of command: String, workingDirectory: String = ".") -> Record? {
        provingRecords().first { $0.command == command && ($0.workingDirectory ?? ".") == workingDirectory }
    }

    /// The newest green run of a *different* command on exactly this tree content from `workingDirectory`: what a refusal names so a reader sees which proof exists and why it does not stand for the command asked.
    func nearestGreen(tree: TreeKey, otherThan command: String, workingDirectory: String = ".") -> Record? {
        provingRecords().first { $0.tree == tree.value && $0.command != command && ($0.workingDirectory ?? ".") == workingDirectory }
    }

    /// Whether `command` run from `workingDirectory` (repository-relative, `"."` for the root) on `tree` under `toolchain` stands on a run already made.
    ///
    /// The reasons are worked out in the order a reader needs them: nothing for this tree at all is a different fact from a run under another toolchain, which is a different fact again from a run that has simply aged out, and each sends the reader somewhere else. A record for the same tree and command but a different directory is not "for this tree at all" here — a nested package's suite and the whole repository's are different runs, however identical their argv.
    ///
    /// Last comes the newest evidence: a red run of the same command on the same content, toolchain and directory in ``failedRuns``, finished no earlier than the green one, refuses it. A red filed through `recordFailure(_:)` has already dropped that green, and ``recordGreen(_:)`` files no green a red on file outdates, so this check is the backstop for a writer that took neither path — a sift from before both took one lock. The environment can differ between two runs of one tree, but a gate standing on the older answer when the newer one is a failure is a gate that let a red tree through.
    func trust(
        tree: TreeKey,
        command: String,
        toolchain: ToolchainIdentity,
        workingDirectory: String = ".",
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Trust {
        guard Self.isOn(environment: environment) else {
            return .notProved(.switchedOff)
        }
        let all = provingRecords()
        let forThisTree = all.filter {
            $0.tree == tree.value && $0.command == command && ($0.workingDirectory ?? ".") == workingDirectory
        }
        guard !forThisTree.isEmpty else {
            let elsewhere = Set(all.filter {
                $0.tree == tree.value && $0.command == command && $0.toolchain == toolchain.description
            }.map { $0.workingDirectory ?? "." })
            guard elsewhere.isEmpty else {
                return .notProved(.noRecordHere(here: workingDirectory, recorded: elsewhere.sorted()))
            }
            if let red = redRun(tree: tree, command: command, toolchain: toolchain, workingDirectory: workingDirectory) {
                return .notProved(.laterRunFailed(age: max(0, now.timeIntervalSince(red.finishedAt)), log: red.log))
            }
            return .notProved(.noRecord)
        }
        guard let newest = forThisTree.first(where: { $0.toolchain == toolchain.description }) else {
            return .notProved(.otherToolchain(recorded: forThisTree[0].toolchain))
        }
        let age = now.timeIntervalSince(newest.finishedAt)
        guard age >= 0 else {
            return .notProved(.aheadOfTheClock)
        }
        guard age <= Self.trustWindow else {
            return .notProved(.tooOld(age: age))
        }
        // No earlier than the green, not strictly after: records are dated to the second, and a green that
        // follows a red clears it from the file rather than outdating it.
        let laterRed = redRun(tree: tree, command: command, toolchain: toolchain, workingDirectory: workingDirectory)
        if let red = laterRed, red.finishedAt >= newest.finishedAt {
            return .notProved(.laterRunFailed(age: max(0, now.timeIntervalSince(red.finishedAt)), log: red.log))
        }
        return .proved(newest)
    }
}

private extension RunLedger {
    /// The records on file that may stand as a proof, newest first: those stamped with this ``writerFormat`` or a later one, since a green an older sift wrote may have cleared a red that finished after it.
    func provingRecords() -> [Record] {
        records().filter { ($0.writerFormat ?? 0) >= Self.writerFormat }
    }

    /// The newest red run in ``failedRuns`` of this command on this content, toolchain and directory, which is also what a tree with no green on file answers with: a red deletes the green it contradicts, so the failure is the only record left of the run.
    func redRun(tree: TreeKey, command: String, toolchain: ToolchainIdentity, workingDirectory: String) -> Record? {
        failedRuns.records().first {
            $0.tree == tree.value && $0.command == command && $0.toolchain == toolchain.description
                && ($0.workingDirectory ?? ".") == workingDirectory
        }
    }
}
