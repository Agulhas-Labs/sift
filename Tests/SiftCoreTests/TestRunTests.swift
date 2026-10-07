//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the order a sharded run happens in, through recording seams — no test here spawns `simctl`, runs `xcodebuild`, or starts a watcher.
///
/// Every seam appends to one event log, so what this suite asserts is the sequence itself: the sweep before the first create, the watcher before it, the devices deleted before the answer is rendered and the watcher let go after, and one teardown however the run ends.
@Suite(.temporaryDirectories)
struct TestRunTests {
    /// The sweep runs before anything of this run's exists: it is the only actor left for a run that died without one, and a device it deletes is one this machine is otherwise carrying for good.
    @Test
    func theSweepRunsBeforeTheFirstDeviceIsCreated() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()

        let result = TestRun(request: Self.request(in: root), environment: Fake(root: root).environment(events)).run()

        let sequence = events.taken()
        let swept = try #require(sequence.firstIndex(of: "simctl list devices"))
        let created = try #require(sequence.firstIndex(where: { $0.hasPrefix("simctl create") }))

        #expect(swept < created)
        #expect(result.answer.contains("2 simulators created, 2 deleted"))
    }

    /// No watcher, no promise that a device outliving this process is ever deleted — so the watcher is armed first, and its identity survives every udid written after it.
    @Test
    func theWatcherIsArmedBeforeTheFirstCreateAndSurvivesEveryUdidRecordedAfterIt() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()

        _ = TestRun(request: Self.request(in: root), environment: Fake(root: root).environment(events)).run()

        let sequence = events.taken()
        let armed = try #require(sequence.firstIndex(of: "watcher armed"))
        let created = try #require(sequence.firstIndex(where: { $0.hasPrefix("simctl create") }))

        #expect(armed < created)
        // Read off the record on disk at the first boot, which is after the last create recorded its udid.
        #expect(sequence.contains("ledger names its watcher"))
        #expect(!sequence.contains("ledger has no watcher"))
    }

    /// A watcher that cannot be armed refuses the run where it stands: the record goes, and nothing is created for nobody to delete.
    @Test
    func aWatcherThatCannotBeArmedCreatesNoDevice() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        var fake = Fake(root: root)
        fake.armFails = true

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        #expect(!events.taken().contains(where: { $0.hasPrefix("simctl create") }))
        #expect(result.answer.contains("no watcher for this run"))
        #expect(result.exitCode == 1)
        let records = try FileManager.default.contentsOfDirectory(atPath: ShardLedger.directory(in: root).path)
        #expect(records.isEmpty)
    }

    /// A failed build is answered exactly as `sift run` answers one — and the devices provisioned beside it are deleted before that answer is handed over.
    @Test
    func aFailedBuildDeletesEveryDeviceItProvisionedAndExitsWithTheBuildsCode() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        var fake = Fake(root: root)
        fake.buildExit = 65

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        #expect(result.exitCode == 65)
        #expect(result.answer.contains("✘ sift run — xcodebuild build-for-testing failed"))
        #expect(result.answer.contains("2 simulators created, 2 deleted"))
        #expect(Self.deleted(events.taken()) == [Self.firstUdid, Self.secondUdid])
    }

    /// A plan that pays for fewer shards than were provisioned owes the surplus devices their delete at once, rather than a booted simulator's memory each for the length of the run.
    @Test
    func theSurplusDevicesGoAsSoonAsThePlanLowersTheShardCount() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let fake = Fake(root: root)

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        let sequence = events.taken()
        let surplus = try #require(sequence.firstIndex(of: "simctl delete \(Self.secondUdid)"))
        let ran = try #require(sequence.firstIndex(of: "shards run"))

        #expect(surplus < ran)
        // One shard ran, on the one device that was kept, and both devices are still answered for.
        #expect(sequence.filter { $0.hasPrefix("shard ") } == ["shard 1 on \(Self.firstUdid)"])
        #expect(result.answer.contains("2 simulators created, 2 deleted"))
    }

    /// The devices line says what happened rather than what was about to, and the watcher is the last thing to go — until it does, something is still there to delete whatever a kill leaves.
    @Test
    func theDevicesGoBeforeTheAnswerIsRenderedAndTheWatcherAfterIt() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let fake = Fake(root: root)

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        let sequence = events.taken()
        let deleted = try #require(sequence.lastIndex(where: { $0.hasPrefix("simctl delete") }))
        // The crash reports are read between the last delete and the render, so they date the render itself.
        let rendered = try #require(sequence.firstIndex(of: "crash reports read"))
        let released = try #require(sequence.firstIndex(of: "watcher released"))

        #expect(deleted < rendered)
        #expect(rendered < released)
        #expect(result.answer.contains("2 simulators created, 2 deleted"))
    }

    /// `Handle.isWatching()` is asked before the shards launch and once more at teardown; a watcher that answers it has stopped owes the answer one note, not two, however early it stopped.
    @Test
    func aWatcherThatStoppedWatchingOwesTheAnswerOneNoteNotTwo() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let clock = ScriptedClock(seconds: [0, 0, 12, 19, 56, 256, 262])
        var fake = Fake(root: root)
        fake.clock = { clock.read() }
        fake.whileBooting = { clock.wait(forReads: 4) }
        fake.watcherIsWatching = false

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        let note = "the run's watcher exited early; a device this run leaves is swept by the next run or sift test --sweep"

        #expect(result.answer.contains(note))
        #expect(result.answer.components(separatedBy: note).count == 2)
    }

    /// The enumeration and the plan run while the devices boot, and the answer charges the devices only for what the run waited on beyond the build and the enumeration they overlapped.
    ///
    /// Every boot waits until the plan has read the clock, so a run that joined provisioning before enumerating would sit out that wait and read the clock in another order: the run's start, the build's start and end, the plan, the shards' start and end, and the teardown.
    @Test
    func theEnumerationAndThePlanRunWhileTheDevicesBoot() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let clock = ScriptedClock(seconds: [0, 0, 12, 19, 56, 256, 262])
        var fake = Fake(root: root)
        fake.clock = { clock.read() }
        fake.whileBooting = { clock.wait(forReads: 4) }

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        let sequence = events.taken()
        let enumerated = try #require(sequence.firstIndex(of: "enumerate"))
        let booted = try #require(sequence.firstIndex(where: { $0.hasPrefix("simctl boot") }))

        #expect(enumerated < booted)
        #expect(result.answer.contains("\nbuild 12s · enumerate 7s · devices ready +37s · shards 200s · teardown 6s\n"))
    }

    /// A run that ends before the join still waits its boots out, so the teardown never deletes a device a boot is still working on.
    @Test
    func aRunEndedBeforeTheJoinWaitsOutItsBootsBeforeDeletingTheDevices() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        var fake = Fake(root: root)
        fake.tests = []
        fake.whileBooting = { Thread.sleep(forTimeInterval: 0.3) }

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        let sequence = events.taken()
        let lastBoot = try #require(sequence.lastIndex(where: { $0.hasPrefix("simctl boot") }))
        let firstDelete = try #require(sequence.firstIndex(where: { $0.hasPrefix("simctl delete") }))

        #expect(lastBoot < firstDelete)
        #expect(result.answer.contains("the plan enumerated no tests"))
    }

    /// The build and the enumeration write their result bundles into the run's own directory beside the shards', so they go when it does rather than piling up in the default derived data.
    @Test
    func theBuildAndTheEnumerationWriteTheirResultBundlesIntoTheRunsDirectory() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()

        _ = TestRun(request: Self.request(in: root), environment: Fake(root: root).environment(events)).run()

        let launches = events.launches()
        let build = try #require(launches.first { $0.contains("build-for-testing") })
        let enumeration = try #require(launches.first { $0.contains("-enumerate-tests") })
        let buildBundle = try #require(Self.bundlePath(in: build))
        let enumerationBundle = try #require(Self.bundlePath(in: enumeration))
        let runDirectory = buildBundle.deletingLastPathComponent()

        #expect(buildBundle.lastPathComponent == "build.xcresult")
        #expect(enumerationBundle.lastPathComponent == "enumeration.xcresult")
        #expect(enumerationBundle.deletingLastPathComponent() == runDirectory)
        #expect(runDirectory.deletingLastPathComponent().standardizedFileURL == ShardLedger.directory(in: root).standardizedFileURL)
    }

    /// A cancellation from another thread ends in one teardown: every device deleted once, the watcher let go once, and an answer that says what happened.
    @Test
    func aCancellationDuringTheShardRunEndsInExactlyOneTeardown() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let holder = RunHolder()
        var fake = Fake(root: root)
        fake.shards = { _ in
            events.append("shards run")
            let cancelled = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                holder.take()?.cancel(exitCode: 130)
                cancelled.signal()
            }
            cancelled.wait()
            return []
        }
        let run = TestRun(request: Self.request(in: root), environment: fake.environment(events))
        holder.put(run)

        let result = run.run()

        let sequence = events.taken()

        #expect(result.exitCode == 130)
        #expect(result.answer.contains("the run was interrupted"))
        #expect(result.answer.contains("2 simulators created, 2 deleted"))
        // The surplus device went when the plan lowered the count, the other at the teardown: each once.
        #expect(Self.deleted(sequence).sorted() == [Self.firstUdid, Self.secondUdid].sorted())
        #expect(sequence.filter { $0 == "watcher released" }.count == 1)
        #expect(sequence.contains("shards cancelled"))
    }

    /// A pass-through word that names something a flag already names is refused before anything is launched — before the `simctl` the device type would have been resolved with.
    @Test
    func aRefusedFlagIsAnsweredBeforeAnythingIsResolvedOrCreated() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        var request = Self.request(in: root)
        request = TestRunRequest(
            scheme: request.scheme,
            deviceTypeName: request.deviceTypeName,
            passThrough: ["-scheme", "Other"],
            workingDirectory: root,
            repositoryRoot: root,
            executable: request.executable
        )

        let result = TestRun(request: request, environment: Fake(root: root).environment(events)).run()

        #expect(result.exitCode == 64)
        #expect(result.answer.hasPrefix("✘ sift test — "))
        #expect(!events.taken().contains("simctl list devicetypes"))
    }

    /// The `.xctestrun` is found through a seam that keeps `-showBuildSettings`'s stdout apart from `xcodebuild`'s stderr, so a warning the build itself prints never lands inside the JSON the build directory is read out of.
    @Test
    func theXCTestRunIsFoundEvenWhenXcodebuildWritesAWarningAlongsideTheBuildSettings() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()

        _ = TestRun(request: Self.request(in: root), environment: Fake(root: root).environment(events)).run()

        let sequence = events.taken()
        let settings = try #require(sequence.firstIndex(of: "build settings"))
        let enumerated = try #require(sequence.firstIndex(of: "enumerate"))

        #expect(settings < enumerated)
    }

    /// A cancellation that lands before the shards start ends the run where it lands, because its teardown has already taken `.sift/shards/<runid>/` with it: a step after it launches what nothing is left to end, or writes into a directory that is gone and answers a file-system error where the caller is owed the interruption it asked for.
    @Test
    func aCancellationDuringTheBuildReachesNoBuildSettingsNoEnumerationAndNoShards() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let holder = RunHolder()
        var fake = Fake(root: root)
        fake.whileBuilding = { holder.cancelFromAnotherThread(exitCode: 128 + SIGTERM) }
        let run = TestRun(request: Self.request(in: root), environment: fake.environment(events))
        holder.put(run)

        let result = run.run()

        let sequence = events.taken()

        #expect(result.exitCode == 128 + SIGTERM)
        #expect(result.answer.contains("the run was interrupted"))
        #expect(!sequence.contains("build settings"))
        #expect(!sequence.contains("enumerate"))
        #expect(!sequence.contains("shards run"))
    }

    /// A build the teardown's own kill ended is answered as the interruption rather than as a broken build, since its non-zero code is that kill's echo and the caller asked for the code its signal named.
    @Test
    func aBuildEndedByTheCancellationIsAnsweredAsTheInterruption() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let holder = RunHolder()
        var fake = Fake(root: root)
        fake.buildExit = 65
        fake.whileBuilding = { holder.cancelFromAnotherThread(exitCode: 128 + SIGHUP) }
        let run = TestRun(request: Self.request(in: root), environment: fake.environment(events))
        holder.put(run)

        let result = run.run()

        #expect(result.exitCode == 128 + SIGHUP)
        #expect(result.answer.contains("the run was interrupted"))
        #expect(!result.answer.contains("build-for-testing failed"))
    }

    /// An enumeration the teardown's own kill ended is answered as the interruption, with the code the signal named — measured live on 17 Sep 2026 as exit 143 under the enumeration's command line where SIGINT had asked for 130.
    @Test
    func anEnumerationEndedByTheCancellationIsAnsweredAsTheInterruption() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let holder = RunHolder()
        var fake = Fake(root: root)
        fake.whileEnumerating = { holder.cancelFromAnotherThread(exitCode: 128 + SIGINT) }
        let run = TestRun(request: Self.request(in: root), environment: fake.environment(events))
        holder.put(run)

        let result = run.run()

        #expect(result.exitCode == 128 + SIGINT)
        #expect(result.answer.contains("the run was interrupted"))
        #expect(!result.answer.contains("test-without-building"))
    }

    /// A runner made after the cancellation looked for one is ended where it is handed over, because nothing else ever will: the teardown that would have stopped it has run, and shards started now would drive devices that are already deleted.
    @Test
    func aRunnerMadeAfterTheCancellationIsEndedRatherThanStarted() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let holder = RunHolder()
        var fake = Fake(root: root)
        fake.whileMakingTheRunner = { holder.cancelFromAnotherThread(exitCode: 128 + SIGTERM) }
        let run = TestRun(request: Self.request(in: root), environment: fake.environment(events))
        holder.put(run)

        let result = run.run()

        let sequence = events.taken()

        #expect(result.exitCode == 128 + SIGTERM)
        #expect(result.answer.contains("the run was interrupted"))
        #expect(!sequence.contains("shards run"))
        #expect(sequence.contains("shards cancelled"))
    }

    /// The state answers a runner's arrival with the cancellation that beat it, which is the one moment that decides whether the shards can still be stopped — `cancel` takes the runner the state holds, and the slot was empty when it looked.
    @Test
    func theStateAnswersARunnerThatArrivesAfterACancellationWithItsCode() {
        let cancelled = TestRun.State()
        _ = cancelled.cancelling(exitCode: 128 + SIGTERM)

        #expect(cancelled.willRun(Self.runner()) == 128 + SIGTERM)
        #expect(TestRun.State().willRun(Self.runner()) == nil)
    }

    /// A create reached after the teardown has run is a device nobody will delete — the teardown keeps the cleanup it already answered with and the watcher is gone — so the refusal happens under the one lock the teardown takes, where a caller asking first and creating second is asking across two of them.
    @Test
    func noDeviceIsCreatedOnceTheRunIsCancelledOrTornDown() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        let simctl = Fake(root: root).simctl(events)
        let cancelled = try Self.state(in: root)
        _ = cancelled.cancelling(exitCode: 130)
        let tornDown = try Self.state(in: root)
        _ = tornDown.teardown(children: SetAsideChildren(), simctl: simctl, releasingWatcher: true)

        try cancelled.create(shard: 0, resolution: Self.resolution, simctl: simctl)
        try tornDown.create(shard: 0, resolution: Self.resolution, simctl: simctl)

        #expect(!events.taken().contains(where: { $0.hasPrefix("simctl create") }))
    }

    /// A failed run's re-run line is a whole command, not a claim the reader has to finish: the invocation's own scheme and device, `--shards 1` so it never re-shards, and `--only` for the failure.
    @Test
    func aFailedRunsAnswerCarriesARunnableRerunCommand() throws {
        let root = try TemporaryDirectory.make("test-run")
        let events = Recorder()
        var fake = Fake(root: root)
        fake.tests = ["DemoUnitTests/CalculatorTests/testAddition()"]
        fake.shards = { assignments in
            events.append("shards run")
            var outcomes = RunTestOutcomes()
            outcomes.read("Test Case '-[DemoUnitTests.CalculatorTests testAddition]' started.")
            outcomes.read("Test Case '-[DemoUnitTests.CalculatorTests testAddition]' failed (0.001 seconds).")
            return assignments.map { _ in
                ShardOutcome(outcomes: outcomes, exitCode: 1, wallSeconds: 1, logPath: "/dev/null")
            }
        }

        let result = TestRun(request: Self.request(in: root), environment: fake.environment(events)).run()

        let line = try #require(result.answer.split(separator: "\n").first { $0.hasPrefix("  sift test --scheme ") })

        #expect(line.contains(" --shards 1 --only "))
    }

    /// A rendered command is only safe to paste when every word that holds a space or a shell-special character is quoted, and a quote of its own escaped rather than left to end the word early.
    @Test
    func shellQuotedWrapsOnlyWhatTheShellWouldSplitOrExpand() {
        #expect(TestRunRequest.shellQuoted("iPhone 17") == "'iPhone 17'")
        #expect(TestRunRequest.shellQuoted("TestDemo") == "TestDemo")
        #expect(TestRunRequest.shellQuoted("O'Brien") == "'O'\\''Brien'")
    }

    /// The rerun prefix names the scheme and device every time, and the OS, plan and container only when the caller gave them — never a flag for something never asked for.
    @Test
    func theRerunPrefixCarriesOnlyWhatTheCallerGave() throws {
        let root = try TemporaryDirectory.make("test-run")
        let bare = Self.request(in: root)

        #expect(bare.rerunCommandPrefix == "sift test --scheme TestDemo --device 'iPhone 17'")

        let detailed = TestRunRequest(
            scheme: "TestDemo",
            deviceTypeName: "iPhone 17",
            osVersion: "17.0",
            plan: "Default",
            container: .project("/path/Demo.xcodeproj"),
            workingDirectory: root,
            repositoryRoot: root,
            executable: bare.executable
        )

        #expect(detailed.rerunCommandPrefix == "sift test --scheme TestDemo --device 'iPhone 17' --os 17.0 --plan Default --project /path/Demo.xcodeproj")
    }
}

private extension TestRunTests {
    static var firstUdid: String {
        "11111111-2222-3333-4444-555555555555"
    }

    static var secondUdid: String {
        "66666666-7777-8888-9999-000000000000"
    }

    static func request(in root: URL) -> TestRunRequest {
        TestRunRequest(
            scheme: "TestDemo",
            deviceTypeName: "iPhone 17",
            requestedShards: 2,
            workingDirectory: root,
            repositoryRoot: root,
            executable: root.appendingPathComponent("sift")
        )
    }

    /// What a run's devices would be made for, which a create that never happens never reads.
    static var resolution: ShardDevices.Resolution {
        ShardDevices.Resolution(
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            osVersion: "27.0"
        )
    }

    /// A state holding a record of its own, which is what a teardown and a create both answer for.
    static func state(in root: URL) throws -> TestRun.State {
        let ledger = try ShardLedger(repositoryRoot: root, prefix: "abcdef", owner: ShardLedger.Identity.current())
        let state = TestRun.State()
        state.began(with: ledger)
        return state
    }

    /// A runner that does nothing, for the orderings that are about the moment it is handed over rather than about what it runs.
    static func runner() -> TestRunEnvironment.Shards {
        TestRunEnvironment.Shards(run: { _ in [] }, cancel: {})
    }

    /// The result bundle an argument vector names, if it names one.
    static func bundlePath(in argv: [String]) -> URL? {
        guard let flag = argv.firstIndex(of: "-resultBundlePath"), flag + 1 < argv.count else {
            return nil
        }
        return URL(fileURLWithPath: argv[flag + 1])
    }

    /// The udids `simctl delete` was asked for, in the order it was asked.
    static func deleted(_ events: [String]) -> [String] {
        events.compactMap { $0.hasPrefix("simctl delete ") ? String($0.dropFirst("simctl delete ".count)) : nil }
    }
}

private extension TestRunTests {
    /// One shared event log, appended to from every seam and from the threads a run provisions and cancels on.
    final class Recorder: @unchecked Sendable {
        private let gate = NSLock()
        private var events: [String] = []
        private var launched: [[String]] = []
        private var created = 0

        func append(_ event: String) {
            gate.withLock { events.append(event) }
        }

        func taken() -> [String] {
            gate.withLock { events }
        }

        /// Takes the argument vector of one launch, whatever it launched.
        func launch(_ arguments: [String]) {
            gate.withLock { launched.append(arguments) }
        }

        /// Every argument vector launched, in the order it was launched.
        func launches() -> [[String]] {
            gate.withLock { launched }
        }

        /// The next udid `simctl create` prints, so two creates never print one device.
        func nextUdid(from udids: [String]) -> String {
            gate.withLock {
                defer { created += 1 }
                return created < udids.count ? udids[created] : "00000000-0000-0000-0000-\(String(format: "%012d", created))"
            }
        }
    }
}

private extension TestRunTests {
    /// The one `TestRun` a cancelling seam has to reach, which does not exist yet when its environment is built.
    final class RunHolder: @unchecked Sendable {
        private let gate = NSLock()
        private var run: TestRun?

        func put(_ run: TestRun) {
            gate.withLock { self.run = run }
        }

        func take() -> TestRun? {
            gate.withLock { run }
        }

        /// Cancels the run the way a caller's signal does — from a thread of its own — and returns once that cancellation has finished, so what a seam does next is what a step after a completed teardown does.
        func cancelFromAnotherThread(exitCode: Int32) {
            let cancelled = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                self.take()?.cancel(exitCode: exitCode)
                cancelled.signal()
            }
            cancelled.wait()
        }
    }
}

private extension TestRunTests {
    /// A clock that answers each read with the next of its scripted offsets from ``Fake/moment``, and the last one once they run out.
    final class ScriptedClock: @unchecked Sendable {
        private let gate = NSCondition()
        private let seconds: [Double]
        private var reads = 0

        init(seconds: [Double]) {
            self.seconds = seconds
        }

        func read() -> Date {
            gate.withLock {
                defer {
                    reads += 1
                    gate.broadcast()
                }
                return Fake.moment.addingTimeInterval(seconds[min(reads, seconds.count - 1)])
            }
        }

        /// Blocks until the clock has been read `count` times, or ten seconds have passed.
        func wait(forReads count: Int) {
            let deadline = Date().addingTimeInterval(10)
            gate.withLock {
                while reads < count, gate.wait(until: deadline) {}
            }
        }
    }
}

private extension TestRunTests {
    /// Every seam a run reaches for, answered from memory and recorded in order.
    struct Fake {
        let root: URL
        var udids: [String] = [TestRunTests.firstUdid, TestRunTests.secondUdid]
        var armFails = false
        var watcherIsWatching = true
        var buildExit: Int32 = 0
        var tests: [String] = ["DemoUnitTests/CalculatorTests/t1()"]
        var shards: (@Sendable ([ShardRunner.Assignment]) -> [ShardOutcome])?

        /// What every seam reads as now, where a test scripts the clock.
        var clock: (@Sendable () -> Date)?

        /// What happens while the one build is running, which is where a signal reaches a run that has not started its shards yet.
        var whileBuilding: (@Sendable () -> Void)?

        /// What happens while each device is booting, before its boot is recorded.
        var whileBooting: (@Sendable () -> Void)?

        /// What happens while the enumeration is running — and, when set, the enumeration answers as a command the teardown ended: a signal's exit code and its own command line.
        var whileEnumerating: (@Sendable () -> Void)?

        /// What happens while the shard runner is being made, which is the window in which a cancellation finds no runner to end.
        var whileMakingTheRunner: (@Sendable () -> Void)?

        /// Where a build would have written its products, which is what `BUILD_DIR` names.
        var products: URL {
            root.appendingPathComponent("Build/Products")
        }

        static var moment: Date {
            Date(timeIntervalSince1970: 1_000_000)
        }

        static var xctestrunName: String {
            "TestDemo_Default_iphonesimulator27.0-arm64.xctestrun"
        }

        func environment(_ events: Recorder) -> TestRunEnvironment {
            TestRunEnvironment(
                simctl: simctl(events),
                launch: launch(events),
                buildSettings: buildSettings(events),
                armWatcher: armWatcher(events),
                shardRunner: shardRunner(events),
                listDirectory: { _ in [TestRunEnvironment.Entry(name: Fake.xctestrunName, modified: Fake.moment)] },
                hostFacts: { TestRunEnvironment.HostFacts(performanceCores: 8, memoryGB: 32) },
                crashReports: { _ in
                    events.append("crash reports read")
                    return []
                },
                now: clock ?? { Fake.moment }
            )
        }
    }
}

private extension TestRunTests.Fake {
    func simctl(_ events: TestRunTests.Recorder) -> @Sendable (String, [String]) throws -> SimulatorAccessibility.Output {
        let root = root
        let udids = udids
        let whileBooting = whileBooting
        return { _, arguments in
            switch arguments.dropFirst().first {
            case "list" where arguments.contains("devicetypes"):
                events.append("simctl list devicetypes")
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: TestRunTests.Fake.catalogue)
            case "list":
                events.append("simctl list devices")
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: #"{ "devices": {} }"#)
            case "create":
                events.append("simctl create \(arguments.dropFirst(2).first ?? "")")
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: events.nextUdid(from: udids))
            case "boot":
                whileBooting?()
                // At the first boot every create has already recorded its udid, so this is where the
                // record is read to see whether arming's line survived being rewritten by all of them.
                events.append(TestRunTests.Fake.watcherLine(in: root))
                events.append("simctl boot \(arguments.dropFirst(2).first ?? "")")
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            case "delete":
                events.append("simctl delete \(arguments.dropFirst(2).first ?? "")")
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            default:
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
        }
    }

    func launch(_ events: TestRunTests.Recorder) -> TestRunEnvironment.Launch {
        let products = products
        let buildExit = buildExit
        let tests = tests
        let whileBuilding = whileBuilding
        let whileEnumerating = whileEnumerating
        return { arguments in
            events.launch(arguments)
            if arguments.contains("build-for-testing") {
                events.append("build")
                whileBuilding?()
                return TestRunEnvironment.Launched(
                    exitCode: buildExit,
                    answer: buildExit == 0 ? "✔ sift run — xcodebuild build-for-testing" : "✘ sift run — xcodebuild build-for-testing failed"
                )
            }
            if arguments.contains("-showBuildSettings") {
                // The launcher this fake stands for gives one pipe to stdout and stderr alike, so a
                // build's own warning lands inside what `-showBuildSettings` reaches its reader through —
                // the bug the `buildSettings` seam below exists to route around.
                events.append("build settings")
                let json = #"[{ "buildSettings": { "BUILD_DIR": "\#(products.path)" } }]"#
                return TestRunEnvironment.Launched(exitCode: 0, answer: "", output: Data("xcodebuild: WARNING: something\n\(json)".utf8))
            }
            events.append("enumerate")
            if let whileEnumerating {
                whileEnumerating()
                return TestRunEnvironment.Launched(exitCode: 128 + SIGTERM, answer: "xcodebuild test-without-building -xctestrun …")
            }
            if let flag = arguments.firstIndex(of: "-test-enumeration-output-path"), flag + 1 < arguments.count {
                let path = arguments[flag + 1]
                let identifiers = tests.map { #"{ "identifier": "\#($0)" }"# }.joined(separator: ", ")
                let document = #"{ "values": [{ "testPlan": "Default", "enabledTests": [\#(identifiers)] }] }"#
                try Data(document.utf8).write(to: URL(fileURLWithPath: path))
            }
            return TestRunEnvironment.Launched(exitCode: 0, answer: "")
        }
    }

    /// `-showBuildSettings` through the seam that keeps stdout and stderr apart, so the JSON `foundXCTestRun` decodes is never the noisy stream `launch(_:)` stands in for above.
    func buildSettings(_ events: TestRunTests.Recorder) -> TestRunEnvironment.Launch {
        let products = products
        return { _ in
            events.append("build settings")
            let json = #"[{ "buildSettings": { "BUILD_DIR": "\#(products.path)" } }]"#
            return TestRunEnvironment.Launched(exitCode: 0, answer: "", output: Data(json.utf8))
        }
    }

    func armWatcher(_ events: TestRunTests.Recorder) -> @Sendable (URL, String, URL) throws -> TestRunEnvironment.Watcher {
        let armFails = armFails
        let watcherIsWatching = watcherIsWatching
        return { _, _, _ in
            guard !armFails else {
                events.append("watcher refused")
                throw ShardError.watcher("no watcher for this run, so no device was created for it to delete")
            }
            events.append("watcher armed")
            return TestRunEnvironment.Watcher(
                identity: ShardLedger.Identity(pid: 4711, startMicroseconds: 111),
                watching: { watcherIsWatching },
                release: {
                    events.append("watcher released")
                    return true
                }
            )
        }
    }

    func shardRunner(_ events: TestRunTests.Recorder) -> @Sendable (SetAsideChildren) -> TestRunEnvironment.Shards {
        let shards = shards
        let whileMakingTheRunner = whileMakingTheRunner
        return { _ in
            whileMakingTheRunner?()
            return TestRunEnvironment.Shards(
                run: { assignments in
                    guard let shards else {
                        events.append("shards run")
                        for assignment in assignments {
                            events.append("shard \(assignment.index) on \(TestRunTests.Fake.device(in: assignment.argv))")
                        }
                        return assignments.map { _ in
                            ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 0, wallSeconds: 1, logPath: "/dev/null")
                        }
                    }
                    return shards(assignments)
                },
                cancel: { events.append("shards cancelled") }
            )
        }
    }

    /// Whether the record on disk still names the watcher that was armed for it.
    static func watcherLine(in root: URL) -> String {
        for runID in ShardLedger.runIDs(in: root) {
            guard case let .ledger(ledger) = ShardLedger.read(repositoryRoot: root, runID: runID, started: { _ in nil }) else {
                continue
            }
            return ledger.watcher == nil ? "ledger has no watcher" : "ledger names its watcher"
        }
        return "ledger has no watcher"
    }

    /// The device a shard's argv names, which is the one it was given.
    static func device(in argv: [String]) -> String {
        guard let destination = argv.first(where: { $0.hasPrefix("platform=iOS Simulator,id=") }) else {
            return "no device"
        }
        return String(destination.dropFirst("platform=iOS Simulator,id=".count))
    }

    /// What `simctl list devicetypes runtimes -j` prints, cut to the one device type and the one runtime a resolution needs.
    static var catalogue: String {
        """
        {
          "devicetypes": [
            { "name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17" }
          ],
          "runtimes": [
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": true, "platform": "iOS",
              "supportedDeviceTypes": [{ "name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17" }]
            }
          ]
        }
        """
    }
}
