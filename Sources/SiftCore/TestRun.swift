//
// Copyright © Agulhas Labs
//

import Foundation

/// One sharded test run, in the order the design gives it: sweep, validate, arm, build, enumerate and plan beside provisioning, run, merge, clean up.
///
/// **Every step that leaves the process is a seam** (``TestRunEnvironment``), because the thing that can be wrong here is the *order* — a device created before the watcher that promises to delete it, an answer rendered before the delete it reports, a cleanup that ran twice. Each part it sequences is tested on its own; this type is tested against a recording of what it asked for, in the order it asked.
///
/// **There is one teardown and it happens once.** A refusal, a failed build, a thrown error and a ``cancel(exitCode:)`` from another thread all reach the same lock-guarded path — end the shard sessions, delete every device the run recorded, let the watcher go — so that no two of them can interleave and no device is deleted twice or left behind once.
public final class TestRun: @unchecked Sendable {
    public typealias Request = TestRunRequest
    public typealias Environment = TestRunEnvironment
    public typealias Result = TestRunResult

    private let request: Request
    private let environment: Environment
    private let children: SetAsideChildren
    private let state = State()

    /// When this run began, which is the cut-off the crash reports beside a missing test are dated from.
    private let beganAt: Date

    /// A run whose every child — the build's and the enumeration's as much as the shards' — belongs to `children`, so that the one teardown ends the lot of them.
    public init(request: Request, environment: Environment, children: SetAsideChildren = SetAsideChildren()) {
        self.request = request
        self.environment = environment
        self.children = children
        beganAt = environment.now()
    }

    /// A run on the live tools, for a caller that has no reason to replace any of them.
    public convenience init(request: Request) {
        let children = SetAsideChildren()
        self.init(request: request, environment: TestRunEnvironment.live(for: request, children: children), children: children)
    }
}

public extension TestRun {
    /// Runs the whole sequence and answers with the one text to print and the one code to exit with.
    ///
    /// It never throws: every ending this run has is an answer somebody is owed, and an error escaping here would be the one ending with no devices line on it.
    func run() -> Result {
        var sweepLines: [String] = []
        do {
            let prefix = try ShardLedger.devicePrefix(in: request.repositoryRoot)
            // The sweep is first because it is the only actor left for a run that died without one, and it
            // is given no exclusion: this run has no record of its own yet, so there is nothing to exclude.
            sweepLines = ShardSweep.sweep(repositoryRoot: request.repositoryRoot, prefix: prefix, run: environment.simctl).sentences
            return try sequence(prefix: prefix, sweepLines: sweepLines)
        } catch let ending as Ending {
            return answer(ending, sweepLines: sweepLines)
        } catch {
            return answer(TestRun.refusal(error, exitCode: TestRun.failureExit), sweepLines: sweepLines)
        }
    }

    /// Ends the run from another thread — a signal handler's, or whatever else is watching the caller — and leaves nothing behind.
    ///
    /// **Call it from a thread, never from inside a signal handler**: it takes a lock, ends process sessions and spawns `simctl`, none of which is safe in a handler's context. A handler's whole job is to hand this over to a thread that is already running.
    ///
    /// The shards are ended first so that ``run()`` returns with whatever their logs already hold, and the same teardown the ordinary path uses then deletes every device and lets the watcher go. `exitCode` is what ``run()`` answers with — `130` for an interrupt, `128 + signal` for anything else the caller took.
    func cancel(exitCode: Int32 = 130) {
        let shards = state.cancelling(exitCode: exitCode)
        shards?.cancel()
        _ = state.teardown(children: children, simctl: environment.simctl, releasingWatcher: true)
    }
}

private extension TestRun {
    /// What a request that cannot be answered as asked exits with — the invocation, the device, the plan or the enumeration.
    static var usageExit: Int32 {
        64
    }

    /// What a run that broke rather than refused exits with.
    static var failureExit: Int32 {
        1
    }

    /// What the answer owes when the armed watcher answers that it stopped watching — this run's own promise that a device outliving it is ever deleted, silently no longer kept.
    static var watcherAbandonedNote: String {
        "the run's watcher exited early; a device this run leaves is swept by the next run or sift test --sweep"
    }

    /// An ending that is one piece of text and one exit code: every refusal, and every outcome that never reaches a reconciliation.
    struct Ending: Error {
        let text: String
        let exitCode: Int32
    }

    /// A part's own sentence, under this command's headline.
    static func refusal(_ error: Error, exitCode: Int32) -> Ending {
        Ending(text: "✘ sift test — \(error)", exitCode: exitCode)
    }

    /// The one ending a cancelled run has, so that every place the sequence notices a cancellation answers with the same sentence and the code the caller's signal asked for.
    static func interrupted(exitCode: Int32) -> Ending {
        Ending(text: "✘ sift test — \(TestRunError.interrupted)", exitCode: exitCode)
    }

    /// Whatever `work` throws, as the ending it is answered with.
    func ending<Value>(_ exitCode: Int32, _ work: () throws -> Value) throws -> Value {
        do {
            return try work()
        } catch {
            // A step that broke because the run was being torn down under it is the interruption, not a refusal of its own.
            try throwIfInterrupted()
            throw TestRun.refusal(error, exitCode: exitCode)
        }
    }

    /// Ends the sequence where a cancellation has already arrived, because every step after one would launch a process nothing is left to end or write into a directory the teardown has already removed.
    func throwIfInterrupted() throws {
        guard let exitCode = state.interruption else {
            return
        }
        throw TestRun.interrupted(exitCode: exitCode)
    }

    /// The answer for an ending: what it said, then the housekeeping every answer carries — what the sweep found, and what became of this run's devices.
    ///
    /// The teardown is here rather than at each `throw` so that there is exactly one place an ending cleans up, and it is the same one the ordinary path uses.
    func answer(_ ending: Ending, sweepLines: [String]) -> Result {
        let cleanup = state.teardown(children: children, simctl: environment.simctl, releasingWatcher: true)
        var tail = sweepLines
        if let cleanup, let line = cleanup.summary {
            tail.append(line)
        }
        let text = [[ending.text], tail]
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
        return Result(answer: text, exitCode: ending.exitCode)
    }
}

private extension TestRun {
    /// The run itself, from the validation that refuses before anything is launched to the reconciliation that is the answer.
    ///
    /// **A cancellation is noticed between every step, not only after the shards.** ``cancel(exitCode:)`` arrives on another thread and tears down where it lands — the devices deleted and `.sift/shards/<runid>/` gone — so a step after it either launches something nothing is left to end, or writes into a directory that is no longer there and answers the caller a file-system error where it is owed the interruption it asked for.
    func sequence(prefix: String, sweepLines: [String]) throws -> Result {
        let (invocation, resolution) = try validated()
        let facts = environment.hostFacts()
        let requested = max(1, request.requestedShards ?? ShardPlanner.defaultShardCount(performanceCores: facts.performanceCores, memoryGB: facts.memoryGB))
        let ledger = try armed(prefix: prefix)
        var durations = TestDurationStore(repositoryRoot: request.repositoryRoot)
        let prepared = try plannedWhileProvisioning(invocation, shards: requested, resolution: resolution, in: ledger) { tests in
            // The plan carries the inventory's display-name literals because a shard's tests are identifiers, and an
            // identifier is the one thing a test that declares its own `@Test("…")` name does not log under: without
            // them the merge reports a test that passed as missing, and the shard's durations are thrown away with it.
            // It carries the conditional tests so a switched-off one reads undecided, as it does unsharded, not missing.
            let inventory = environment.declaredInventory()
            return ShardPlanner.plan(
                tests: tests,
                shards: requested,
                displayNames: inventory?.displayNames ?? [:],
                conditional: inventory?.conditionalTests ?? [],
                duration: { durations.median(for: $0.enumerated) }
            )
        }
        let plan = prepared.plan
        // A plan that pays for fewer shards than were provisioned owes the surplus devices their delete now,
        // rather than at the end: they are a booted simulator's worth of memory each, beside the shards
        // that are about to run.
        state.deleteSurplus(beyond: plan.shards.count, simctl: environment.simctl)
        try throwIfInterrupted()
        var notes: [String] = []
        if state.watcherStoppedWatching() == true {
            notes.append(TestRun.watcherAbandonedNote)
        }
        let shardsBegan = environment.now()
        let outcomes = try run(plan, invocation: invocation, xctestrun: prepared.xctestrun, in: ledger)
        let shardsEnded = environment.now()
        try throwIfInterrupted()
        return merged(plan, outcomes: outcomes, durations: &durations, sweepLines: sweepLines, notes: notes) {
            prepared.phases(shardsBegan: shardsBegan, shardsEnded: shardsEnded, tornDown: $0)
        }
    }

    /// The invocation, or the refusal the caller is owed before anything at all is launched.
    ///
    /// The flags are checked before the device type is resolved, because resolving spawns `simctl`: a caller whose pass-through names something a flag already names is owed that sentence and no processes.
    func validated() throws -> (invocation: TestInvocation, resolution: ShardDevices.Resolution) {
        try ending(TestRun.usageExit) {
            try TestInvocation.check(only: request.only, skip: request.skip, passThrough: request.passThrough)
        }
        let resolution = try ending(TestRun.usageExit) {
            try ShardDevices.resolve(deviceTypeName: request.deviceTypeName, osVersion: request.osVersion, run: environment.simctl)
        }
        let invocation = try ending(TestRun.usageExit) {
            try TestInvocation(
                scheme: request.scheme,
                deviceType: request.deviceTypeName,
                osVersion: resolution.osVersion,
                plan: request.plan,
                only: request.only,
                skip: request.skip,
                container: request.container,
                passThrough: request.passThrough
            )
        }
        return (invocation, resolution)
    }

    /// The run's record, with its watcher armed and written into it.
    ///
    /// **The watcher is recorded on this value, not only on disk.** ``ShardGuardian/arm(executable:runID:repositoryRoot:timeout:)`` writes the watcher into the record itself, and a ledger value taken before that would erase the line at its next write — the record is rewritten whole from memory every time a udid reaches it.
    ///
    /// **A watcher that cannot be armed refuses the run.** No watcher is no promise that a device outliving this process is ever deleted, so the record is removed and nothing is created.
    func armed(prefix: String) throws -> ShardLedger {
        var ledger = try ending(TestRun.failureExit) {
            try ShardLedger(repositoryRoot: request.repositoryRoot, prefix: prefix, owner: ShardLedger.Identity.current())
        }
        state.began(with: ledger)
        do {
            let watcher = try environment.armWatcher(request.executable, ledger.runID, request.repositoryRoot)
            try ledger.recordWatcher(watcher.identity)
            state.armed(watcher, ledger: ledger)
            return ledger
        } catch {
            state.forgetLedger()
            try? ledger.remove()
            throw TestRun.refusal(error, exitCode: TestRun.failureExit)
        }
    }

    /// The one build, the enumeration and the plan, with this run's devices created and booted beside all three.
    ///
    /// Products built for one destination are accepted by any device of the same type and runtime, which is what lets the provisioning overlap the build at all; the enumeration names that destination rather than a device and starts nothing, which is what lets it overlap the boots too. Provisioning is joined only once the plan is made, where the shards are about to need it.
    ///
    /// **Provisioning is always waited out**, whatever fails before the join: an answer given while a create or a boot was still running would leave it to finish over a teardown already deleting the devices under it.
    func plannedWhileProvisioning(
        _ invocation: TestInvocation,
        shards: Int,
        resolution: ShardDevices.Resolution,
        in ledger: ShardLedger,
        plan: ([TestIdentifier]) -> ShardPlan
    ) throws -> TestRunPreparation {
        let began = environment.now()
        let provisioned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            self.provision(count: shards, resolution: resolution)
            provisioned.signal()
        }
        let prepared: TestRunPreparation
        do {
            let built = try build(invocation, in: ledger)
            let xctestrun = try foundXCTestRun(invocation, since: began)
            try throwIfInterrupted()
            let tests = try enumerated(invocation, xctestrun: xctestrun, in: ledger)
            guard !tests.isEmpty else {
                throw Ending(text: "✔ sift test — the plan enumerated no tests, so there was nothing to run", exitCode: 0)
            }
            let shardPlan = plan(tests)
            prepared = TestRunPreparation(began: began, built: built, planned: environment.now(), xctestrun: xctestrun, plan: shardPlan)
        } catch {
            provisioned.wait()
            try throwIfInterrupted()
            throw error
        }
        provisioned.wait()
        // Before provisioning's verdict, because a cancellation is what ended it: the devices the teardown
        // deletes are what a boot then fails against.
        try throwIfInterrupted()
        if let failure = state.provisionFailure {
            throw TestRun.refusal(failure, exitCode: TestRun.failureExit)
        }
        return prepared
    }

    /// The one build, which writes its result bundle into the run's own directory so that it goes when that directory does.
    ///
    /// Answers when the build exited, or — where it failed — with the build's own `sift run` answer, exactly as `sift run -- xcodebuild build-for-testing` would have given it.
    func build(_ invocation: TestInvocation, in ledger: ShardLedger) throws -> Date {
        let arguments = invocation.buildForTestingArguments(resultBundle: ledger.directory.appendingPathComponent("build.xcresult"))
        let launched = try ending(TestRun.failureExit) { try environment.launch(arguments) }
        let built = environment.now()
        // Before the build's own verdict, because a cancellation is what ended it: the teardown kills the build.
        try throwIfInterrupted()
        guard launched.exitCode == 0 else {
            throw Ending(text: launched.answer, exitCode: launched.exitCode)
        }
        return built
    }

    /// Creates this run's devices and boots them.
    ///
    /// **Created one at a time, booted all at once.** A create is seconds and a boot is minutes, and a create is also the one step that writes the record — the ledger is a value that rewrites its file whole, so two creates at once would each write from a copy that never saw the other's udid. Serialising the cheap step is what keeps the record a single writer.
    func provision(count: Int, resolution: ShardDevices.Resolution) {
        do {
            for index in 0 ..< count {
                guard !state.isCancelled else {
                    return
                }
                try state.create(shard: index, resolution: resolution, simctl: environment.simctl)
            }
        } catch {
            state.provisioning(failed: error)
            return
        }
        boot(state.udids())
    }

    /// Boots every device at once, since a boot is a wait rather than work.
    func boot(_ udids: [String]) {
        let booted = DispatchSemaphore(value: 0)
        for udid in udids {
            Thread.detachNewThread {
                if !self.state.isCancelled {
                    do {
                        try ShardDevices.boot(udid: udid, run: self.environment.simctl)
                    } catch {
                        self.state.provisioning(failed: error)
                    }
                }
                booted.signal()
            }
        }
        for _ in udids {
            booted.wait()
        }
    }

    /// The `.xctestrun` this run's shards run from.
    ///
    /// With a plan named, the file that plan wrote. Without one, only the files this build wrote are considered — an earlier build of another plan leaves its own in the same directory, and running it would put a combination of targets on a device that nobody asked for.
    func foundXCTestRun(_ invocation: TestInvocation, since began: Date) throws -> URL {
        let settings = try ending(TestRun.usageExit) { try environment.buildSettings(invocation.buildSettingsArguments) }
        try throwIfInterrupted()
        guard settings.exitCode == 0 else {
            throw Ending(text: settings.answer, exitCode: settings.exitCode)
        }
        let path = try ending(TestRun.usageExit) { try TestInvocation.buildDirectory(inBuildSettings: settings.output) }
        let directory = URL(fileURLWithPath: path)
        let entries = environment.listDirectory(directory)
        if let plan = invocation.plan {
            let name = try ending(TestRun.usageExit) { try TestInvocation.xctestrunName(among: entries.map(\.name), plan: plan) }
            return directory.appendingPathComponent(name)
        }
        let written = entries.filter { $0.name.hasSuffix(".xctestrun") && $0.modified >= began }.map(\.name).sorted()
        guard let name = written.first else {
            throw TestRun.refusal(TestRunError.noXCTestRun(entries.map(\.name)), exitCode: TestRun.usageExit)
        }
        guard written.count == 1 else {
            throw TestRun.refusal(TestRunError.severalXCTestRuns(written), exitCode: TestRun.usageExit)
        }
        return directory.appendingPathComponent(name)
    }

    /// The expected set: the tests `xcodebuild` itself says the plan will run, which every count in the answer is reconciled against.
    func enumerated(_ invocation: TestInvocation, xctestrun: URL, in ledger: ShardLedger) throws -> [TestIdentifier] {
        let outputPath = ledger.directory.appendingPathComponent("enumerated.json")
        let arguments = invocation.enumerationArguments(
            xctestrun: xctestrun,
            outputPath: outputPath,
            resultBundle: ledger.directory.appendingPathComponent("enumeration.xcresult")
        )
        let enumeration = try ending(TestRun.usageExit) { try environment.launch(arguments) }
        // The teardown ends this command with the rest of the run's children, and what it then exits with is the signal's doing.
        try throwIfInterrupted()
        guard enumeration.exitCode == 0 else {
            throw Ending(text: enumeration.answer, exitCode: enumeration.exitCode)
        }
        return try ending(TestRun.usageExit) { () -> [TestIdentifier] in
            guard let data = FileManager.default.contents(atPath: outputPath.path) else {
                throw TestRunError.unreadableEnumeration("nothing was written to \(outputPath.path)")
            }
            return try TestEnumeration.read(data).enabledTests
        }
    }

    /// Runs one `xcodebuild` per planned shard, each on the device provisioned for it.
    ///
    /// The plan's shards and this run's devices are the same length by the time this is called — the surplus was deleted the moment the plan lowered the count — so shard `k` runs on the `k`th device recorded.
    ///
    /// **A runner the cancellation beat here is ended rather than started.** ``cancel(exitCode:)`` ends whatever runner the state holds, so one handed over after it looked is one no teardown will ever reach: the children were ended already and the watcher let go, and the shards would run on devices that are gone with nothing left to stop them.
    func run(_ plan: ShardPlan, invocation: TestInvocation, xctestrun: URL, in ledger: ShardLedger) throws -> [ShardOutcome] {
        children.record(into: ShardGuardian.sessionsFile(for: ledger))
        let shards = environment.shardRunner(children)
        if let exitCode = state.willRun(shards) {
            shards.cancel()
            throw TestRun.interrupted(exitCode: exitCode)
        }
        let assignments = zip(plan.shards, state.udids()).map { shard, udid in
            ShardRunner.Assignment(
                index: shard.index,
                argv: invocation.shardArguments(
                    xctestrun: xctestrun,
                    deviceUDID: udid,
                    tests: shard.tests,
                    resultBundle: ledger.directory.appendingPathComponent("\(shard.index).xcresult")
                ),
                bound: request.shardTimeoutSeconds.map { ShardRunner.bound(forPredicted: shard.predictedSeconds, minimumSeconds: $0) }
                    ?? ShardRunner.bound(forPredicted: shard.predictedSeconds)
            )
        }
        return shards.run(assignments)
    }

    /// The answer: the reconciliation, the timings it is worth keeping, and — before a word of it is rendered — the devices gone.
    ///
    /// `phases` is the run's timing given the moment the devices were deleted, which is the one phase boundary this function sees.
    ///
    /// **The devices are deleted before the answer is rendered and the watcher is let go after it.** The devices line says what actually happened rather than what was about to, and the watcher is the last thing to go because until it does something is still there to delete what a kill might leave.
    func merged(
        _ plan: ShardPlan,
        outcomes: [ShardOutcome],
        durations: inout TestDurationStore,
        sweepLines: [String],
        notes: [String],
        phases: (Date) -> ShardPhases
    ) -> Result {
        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: outcomes, shardTimeoutSeconds: request.shardTimeoutSeconds)
        for shard in plan.shards {
            guard let recording = reconciliation.recording(forShard: shard.index) else {
                continue
            }
            durations.record(recording)
        }
        let cleanup = state.teardown(children: children, simctl: environment.simctl, releasingWatcher: false)
        // Asked here, before the watcher is released below, so the answer reports what happened during
        // the run rather than the release itself reading as an early exit.
        var notes = notes
        if state.watcherStoppedWatching() == true, !notes.contains(TestRun.watcherAbandonedNote) {
            notes.append(TestRun.watcherAbandonedNote)
        }
        let phases = phases(environment.now())
        let rendered = ShardAnswerRenderer(
            phases: phases,
            devicesLine: cleanup?.summary,
            crashReports: environment.crashReports(beganAt),
            sweepLines: sweepLines,
            rerunCommand: request.rerunCommandPrefix, rerunSuffix: request.rerunCommandSuffix
        )
        .render(reconciliation, plan: plan)
        let answer = ([rendered] + notes).joined(separator: "\n\n")
        _ = state.teardown(children: children, simctl: environment.simctl, releasingWatcher: true)
        return Result(answer: answer, exitCode: reconciliation.exitCode)
    }
}

extension TestRun {
    /// Everything the sequence and a cancellation both touch, behind one lock.
    ///
    /// The lock is the whole point: ``TestRun/cancel(exitCode:)`` arrives on another thread at any moment, and the two must not both delete this run's devices, nor delete them while a create is still recording one.
    ///
    /// It is visible to the module rather than the file so that the orderings the sequence cannot be stopped at — a runner handed over after a cancellation, a create reached after the teardown — are asserted on directly, where driving them through the seams would be a race a test cannot win reliably.
    final class State: @unchecked Sendable {
        private let gate = NSLock()
        private var ledger: ShardLedger?
        private var watcher: Environment.Watcher?
        private var shards: Environment.Shards?
        private var surplus: [ShardDevices.Deletion] = []
        private var cleanup: ShardDevices.Cleanup?
        private var endedChildren = false
        private var releasedWatcher = false
        private var cancellation: Int32?
        private var failure: Error?

        /// Takes the run's record, from which moment a teardown is answerable for whatever it holds.
        func began(with ledger: ShardLedger) {
            gate.withLock { self.ledger = ledger }
        }

        /// Takes the watcher, and the record that now names it.
        func armed(_ watcher: Environment.Watcher, ledger: ShardLedger) {
            gate.withLock {
                self.watcher = watcher
                self.ledger = ledger
            }
        }

        /// Drops a record nothing is going to watch, so a teardown after a failed arming owns nothing.
        func forgetLedger() {
            gate.withLock { ledger = nil }
        }

        /// Creates one shard's device, recording it as ``ShardDevices/create(shard:in:resolution:run:)`` does — intent first, udid the moment it is printed.
        ///
        /// **The refusal and the create are under the one lock the teardown takes.** A caller that asked whether the run was cancelled and then called this would be asking across two acquisitions, and a teardown completing between them leaves the device it creates for nobody: the teardown returns its cleanup unchanged once it has one, the watcher has been let go, and the answer says "N created, N deleted" while N + 1 exist.
        func create(shard index: Int, resolution: ShardDevices.Resolution, simctl: ShardDevices.Run) throws {
            try gate.withLock {
                guard cancellation == nil, cleanup == nil, var ledger else {
                    return
                }
                defer { self.ledger = ledger }
                try ShardDevices.create(shard: index, in: &ledger, resolution: resolution, run: simctl)
            }
        }

        /// Every udid this run has recorded, in shard order.
        func udids() -> [String] {
            gate.withLock { ledger?.udids ?? [] }
        }

        /// Takes the first reason provisioning could not finish; the ones after it are that one's consequences.
        func provisioning(failed error: Error) {
            gate.withLock {
                guard failure == nil else {
                    return
                }
                failure = error
            }
        }

        /// Why this run has no devices to run on, or `nil` where it has them.
        var provisionFailure: Error? {
            gate.withLock { failure }
        }

        /// Whether the armed watcher answered that it had stopped watching, or `nil` where this run never armed one — asked without telling the watcher anything, so a caller can ask it more than once.
        func watcherStoppedWatching() -> Bool? {
            gate.withLock { watcher.map { !$0.isWatching() } }
        }

        /// Takes the runner, so that a cancellation arriving mid-run has something to end, and answers with the code of a cancellation that got here first — under the one lock, because a runner taken after ``cancelling(exitCode:)`` looked for one is a runner nothing will ever end.
        func willRun(_ shards: Environment.Shards) -> Int32? {
            gate.withLock {
                self.shards = shards
                return cancellation
            }
        }

        /// Whether a cancellation has begun — provisioning stops where it has.
        var isCancelled: Bool {
            gate.withLock { cancellation != nil }
        }

        /// What a cancelled run answers with, or `nil` where none arrived.
        var interruption: Int32? {
            gate.withLock { cancellation }
        }

        /// Records the cancellation and hands back the runner to end, if the shards had started.
        func cancelling(exitCode: Int32) -> Environment.Shards? {
            gate.withLock {
                if cancellation == nil {
                    cancellation = exitCode
                }
                return shards
            }
        }

        /// Deletes the devices a lowered plan has no shard for, and drops each one the record only once it is gone.
        ///
        /// A delete that failed keeps its entry, so the final cleanup — and the sweep after that — try it again.
        func deleteSurplus(beyond count: Int, simctl: ShardDevices.Run) {
            gate.withLock {
                guard var ledger else {
                    return
                }
                let recorded = ledger.shards.compactMap { shard in shard.udid.map { (index: shard.index, udid: $0) } }
                guard recorded.count > count else {
                    return
                }
                for device in recorded.dropFirst(count) {
                    let deletion = ShardDevices.delete(udid: device.udid, run: simctl)
                    guard deletion.failure == nil else {
                        continue
                    }
                    try? ledger.forget(shard: device.index)
                    surplus.append(deletion)
                }
                self.ledger = ledger
            }
        }

        /// The one teardown: the shard sessions ended, every device this run recorded deleted, and — when asked — the watcher let go.
        ///
        /// Each part happens once, whoever asks: the ordinary path deletes the devices before it renders and comes back for the release afterwards, and a cancellation does both at once. The sessions go first because an `xcodebuild` still driving a device that is being deleted wedges CoreSimulator.
        func teardown(children: SetAsideChildren, simctl: ShardDevices.Run, releasingWatcher: Bool) -> ShardDevices.Cleanup? {
            gate.withLock {
                if !endedChildren {
                    endedChildren = true
                    children.endAll()
                }
                if cleanup == nil, let ledger {
                    let deleted = ShardDevices.deleteAll(in: ledger, run: simctl)
                    cleanup = ShardDevices.Cleanup(
                        created: deleted.created + surplus.count,
                        deletions: surplus + deleted.deletions
                    )
                }
                if releasingWatcher, !releasedWatcher, let watcher {
                    releasedWatcher = true
                    watcher.release()
                }
                return cleanup
            }
        }
    }
}
