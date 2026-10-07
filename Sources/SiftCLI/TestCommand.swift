//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `sift test` — one scheme's tests across several simulators at once, answered with counts of this tool's own, and `--analyse`, which runs nothing and answers how many were supposed to.
struct TestCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "test",
            abstract: "Run a scheme's tests across several simulators at once, or a SwiftPM package's across several swift test processes.",
            discussion: """
            Builds the scheme once, splits the tests its plan enumerates across N simulators, runs one \
            xcodebuild per shard, and answers with one reconciliation — expected · ran · passed · failed · \
            skipped · missing · duplicated — counted against the enumerated set rather than read off the \
            tallies the runners printed. A test the plan assigned that never reported an ending, and one \
            that reported twice, make the run not green whatever xcodebuild said, and are named with the \
            shard they belong to. `sift help test-output` reads the answer line by line.

            The simulators are this tool's own: one per shard, created of the device type named, booted, \
            and deleted when the run ends — after a signal and after a crash too, by a watcher started \
            beside the run, and failing that by the next run's sweep. A device sift did not create is \
            never touched.

            **In a SwiftPM package, with no `--scheme` and no `--device`, it runs no simulator at all**: \
            it splits the package's `swift test` by suite across processes, `--shards N` sets how many, \
            and the answer is the same reconciliation, with the `slowest:` tests named on a green run too. \
            `--os`, `--plan`, `--only`, `--skip`, `--project`, `--workspace` and everything after `--` are \
            refused there, since they name nothing a `swift test` process takes.

            `--analyse` is the other half and shares none of that: it builds nothing, boots nothing and \
            runs nothing. It reads the index for every declared test, reads the `.xctestplan` files off \
            disk, and answers with the difference — how many tests are supposed to run, which of them \
            never will, and which plan exclusions do nothing at all. `--plan <name>` narrows it to one \
            plan.

            `--analyse --against <log>` closes the join at the other end: it reads a run's own output \
            back and reconciles it against that same declared inventory, so a test that never started \
            is named as missing instead of vanishing from the tally. It builds and boots nothing either \
            — the run already happened, and the file is all it reads. The expected set is bounded by \
            this package's test targets, and the run is not green with anything missing or duplicated, \
            whatever its own summary line said.

            Examples:
              sift test --scheme Gizmo --device "iPhone 17" --plan Unit --shards 3
              sift test --analyse
              sift test --sweep
              swift test > run.log 2>&1; sift test --analyse --against run.log
            """
        )
    }

    @Flag(name: .customLong("analyse"), help: "Answer how many tests are supposed to run, from the index and the plans. Builds nothing, boots nothing, runs nothing.")
    var analyse: Bool = false

    @Flag(name: .customLong("sweep"), help: "Delete the simulators left by this checkout's runs that are no longer running, and run nothing.")
    var sweep: Bool = false

    @Option(name: .customLong("scheme"), help: "The scheme to build and run.")
    var scheme: String?

    @Option(name: .customLong("device"), help: "The device type to create the simulators of, as `simctl list devicetypes` spells it.")
    var device: String?

    @Option(name: .customLong("os"), help: "The runtime version to create them on. Defaults to the newest installed one that runs the device type.")
    var osVersion: String?

    @Option(name: .customLong("plan"), help: "The test plan to run. One run runs one plan.")
    var plan: String?

    @Option(name: .customLong("against"), help: "Reconcile a finished run's output against the declared inventory: the file `swift test` wrote, or a log kept under .sift/runs/. Needs --analyse.")
    var against: String?

    @Option(name: .customLong("only"), help: "Run only this Target, Target/Class or Target/Class/test. Repeatable.")
    var only: [String] = []

    @Option(name: .customLong("skip"), help: "Leave out this Target, Target/Class or Target/Class/test. Repeatable.")
    var skip: [String] = []

    @Option(name: .customLong("shards"), help: "How many simulators to split the tests across. Defaults to what this host can run at once.")
    var shards: Int?

    @Option(name: .customLong("shard-timeout"), help: "The floor under a shard's bound, in seconds. Defaults to 600 (ten minutes); refused below 30.")
    var shardTimeout: Int?

    @Option(name: .customLong("project"), help: "The .xcodeproj the scheme lives in. Found in the working directory or the repository root when neither this nor --workspace is given.")
    var project: String?

    @Option(name: .customLong("workspace"), help: "The .xcworkspace the scheme lives in, instead of --project.")
    var workspace: String?

    @Argument(parsing: .postTerminator, help: "Everything after --, handed to xcodebuild untouched.")
    var passThrough: [String] = []

    /// The watcher a sharded run starts to delete its simulators if it is killed; never typed by a person.
    @Option(name: .customLong("guard-shards"), help: .private)
    var guardShards: String?

    @OptionGroup var rootOptions: RootOptions

    /// Where the answer goes, injected so a test can read what the command printed.
    var output: CommandOutput = .standard

    /// How `--sweep` spawns `simctl`, injected so a test deletes nothing real.
    var simctl: @Sendable (String, [String]) throws -> SimulatorAccessibility.Output = TestRunEnvironment.liveSimctl()

    /// The directory the command reads its repository from: the process's own unless a test names another.
    var startingDirectory: URL?

    /// The least `--shard-timeout` will set the bound to — low enough to matter, high enough that it can never fire on a shard that only just launched `xcodebuild`.
    static let minimumShardTimeoutSeconds = 30

    /// The refusals `--analyse` is owed before anything is opened, since every flag below describes a build or a run it will not do.
    ///
    /// Each one is a sentence rather than a usage dump: a caller who pasted a working `sift test` line and added `--analyse` has asked for two different commands at once, and the thing they need told is which half this flag drops.
    func validate() throws {
        if sweep {
            try validateSweep()
        }
        guard analyse else {
            guard against == nil else {
                throw ValidationError("--against reads a run that has already happened and reconciles it against the index, which is --analyse's half of this command. Pass --analyse --against <log>, or drop --against to run the tests.")
            }
            return
        }
        guard against == nil || plan == nil else {
            throw ValidationError("--against and --plan bound the expected set two different ways: --plan narrows to one .xctestplan's container, and --against reconciles a `swift test` run, which reads no plan and covers this package's test targets. Drop one of the two.")
        }
        let refused: [(name: String, given: Bool)] = [
            ("--scheme", scheme != nil),
            ("--device", device != nil),
            ("--os", osVersion != nil),
            ("--shards", shards != nil),
            ("--shard-timeout", shardTimeout != nil),
            ("--only", !only.isEmpty),
            ("--skip", !skip.isEmpty),
            ("--project", project != nil),
            ("--workspace", workspace != nil),
            ("--guard-shards", guardShards != nil),
            ("everything after --", !passThrough.isEmpty),
        ]
        guard let first = refused.first(where: \.given) else {
            return
        }
        throw ValidationError("--analyse and \(first.name) ask for two different things: --analyse reads the index and the test plans and starts no build, boots no simulator and runs no test, so there is nothing for \(first.name) to name. Drop one of the two.")
    }

    func run() async throws {
        let workingDirectory = startingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if sweep {
            guard let repositoryRoot = GitContext.discoverRoot(from: workingDirectory) else {
                throw ValidationError("sift test --sweep runs inside a git repository: the records of which simulators its runs created live in that repository's .sift/.")
            }
            let report = try ShardSweep.sweep(repositoryRoot: repositoryRoot, prefix: ShardLedger.devicePrefix(in: repositoryRoot), run: simctl)
            output.emit(report.answer)
            guard report.exitCode == 0 else {
                throw ExitCode(report.exitCode)
            }
            return
        }
        if analyse {
            let (answer, isGreen) = try await analysis(workingDirectory: workingDirectory)
            output.emit(answer)
            guard isGreen else {
                throw ExitCode(1)
            }
            return
        }
        if let guardShards {
            throw ExitCode(ShardGuardian.watch(runID: guardShards, repositoryRoot: workingDirectory))
        }
        if let package = try packageRun(in: workingDirectory) {
            let interruptions = TestInterruptions()
            interruptions.arm { package.cancel(exitCode: 128 + $0) }
            let started = Date()
            let result = withExtendedLifetime(interruptions) { package.run() }
            output.emit(result.answer)
            if let repositoryRoot = GitContext.discoverRoot(from: workingDirectory) {
                record(result, milliseconds: Int(Date().timeIntervalSince(started) * 1000), repositoryRoot: repositoryRoot)
            }
            guard result.exitCode == 0 else {
                throw ExitCode(result.exitCode)
            }
            return
        }
        let request = try request(in: workingDirectory)
        let run = TestRun(request: request)
        // Armed before the run rather than after it starts: between the two is exactly the window in which a
        // device has been created and nothing is yet listening for the signal that would otherwise leave it.
        let interruptions = TestInterruptions()
        interruptions.arm { run.cancel(exitCode: 128 + $0) }
        let started = Date()
        let result = withExtendedLifetime(interruptions) { run.run() }
        output.emit(result.answer)
        record(result, milliseconds: Int(Date().timeIntervalSince(started) * 1000), repositoryRoot: request.repositoryRoot)
        guard result.exitCode == 0 else {
            throw ExitCode(result.exitCode)
        }
    }

    /// `--sweep` refuses every flag that describes a run, and `--analyse`, by name, since it builds, boots and runs nothing.
    private func validateSweep() throws {
        let refused: [(name: String, given: Bool)] = [
            ("--analyse", analyse),
            ("--scheme", scheme != nil),
            ("--device", device != nil),
            ("--os", osVersion != nil),
            ("--plan", plan != nil),
            ("--against", against != nil),
            ("--shards", shards != nil),
            ("--shard-timeout", shardTimeout != nil),
            ("--only", !only.isEmpty),
            ("--skip", !skip.isEmpty),
            ("--project", project != nil),
            ("--workspace", workspace != nil),
            ("--guard-shards", guardShards != nil),
            ("everything after --", !passThrough.isEmpty),
        ]
        guard let first = refused.first(where: \.given) else {
            return
        }
        throw ValidationError("--sweep and \(first.name) ask for two different things: --sweep deletes the simulators left by this checkout's runs that are no longer running, and builds, boots and runs nothing. Drop one of the two.")
    }

    /// `--analyse`'s whole answer, header first and any adopted-root note under it.
    ///
    /// The engine is opened the way every index-reading command opens it, because this half of `test` is a query over the index rather than a run: it needs the same freshening, and it owes the same header.
    ///
    /// The verdict is `true` for the static answer, which reports what is declared and passes judgement on no run.
    func analysis(workingDirectory: URL, registry: RootsRegistry = .standard()) async throws -> (answer: String, isGreen: Bool) {
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        let freshness = try await engine.ensureFresh()
        guard let against else {
            return try (Freshness.placing([note], under: engine.analyseTests(plan: plan, freshness: freshness)), true)
        }
        let logURL = URL(fileURLWithPath: against, relativeTo: workingDirectory).standardizedFileURL
        let reconciliation = try engine.reconcileTests(against: logURL, freshness: freshness)
        return (Freshness.placing([note], under: reconciliation.answer), reconciliation.isGreen)
    }

    /// The SwiftPM run these flags describe — no `--scheme`, no `--device`, and a `Package.swift` in the working directory — or `nil` where they describe a simulator run.
    ///
    /// Every flag that names a simulator, a plan or an `xcodebuild` argument is refused by name, since a package's shards are `swift test` processes and there is nothing for it to name.
    func packageRun(in workingDirectory: URL) throws -> PackageTestRun? {
        guard scheme == nil, device == nil, FileManager.default.fileExists(atPath: workingDirectory.appendingPathComponent("Package.swift").path) else {
            return nil
        }
        let refused: [(name: String, given: Bool)] = [
            ("--os", osVersion != nil),
            ("--plan", plan != nil),
            ("--only", !only.isEmpty),
            ("--skip", !skip.isEmpty),
            ("--project", project != nil),
            ("--workspace", workspace != nil),
            ("everything after --", !passThrough.isEmpty),
        ]
        if let first = refused.first(where: \.given) {
            throw ValidationError("sift test with no --scheme runs this SwiftPM package's `swift test` split by suite across processes, and \(first.name) names nothing there. Pass --scheme and --device for a simulator run, or drop \(first.name).")
        }
        if let shards, !(1 ... ShardPlanner.maximumShards).contains(shards) {
            throw ValidationError("--shards \(shards) is not a count of `swift test` processes sift will run: it takes 1 to \(ShardPlanner.maximumShards), and 1 splits nothing.")
        }
        if let shardTimeout, shardTimeout < Self.minimumShardTimeoutSeconds {
            throw ValidationError("--shard-timeout \(shardTimeout) is below \(Self.minimumShardTimeoutSeconds): a bound that low fires on a healthy shard before swift test has even loaded its bundle.")
        }
        guard let repositoryRoot = GitContext.discoverRoot(from: workingDirectory) else {
            throw ValidationError("sift test runs inside a git repository: the shard logs and the test durations live in that repository's .sift/.")
        }
        return PackageTestRun(
            packageDirectory: workingDirectory,
            repositoryRoot: repositoryRoot,
            requestedShards: shards,
            shardTimeoutSeconds: shardTimeout.map(TimeInterval.init)
        )
    }

    /// The request these flags describe, or the refusal the caller is owed before anything is launched.
    ///
    /// Not `private`: the bound checks below run before any filesystem or process work, so a test reaches them directly through `@testable import` rather than through `run()`, which would otherwise have to build and boot to exercise them.
    func request(in workingDirectory: URL) throws -> TestRunRequest {
        guard let scheme else {
            throw ValidationError("sift test needs --scheme <name>: it builds and runs one scheme.")
        }
        guard let device else {
            throw ValidationError("sift test needs --device \"<device type>\", as `simctl list devicetypes` spells it: it names both what is created and what the one build is made for.")
        }
        if let shards, shards < 1 {
            throw ValidationError("--shards \(shards) is not a count of simulators: it takes 1 or more, and 1 splits nothing.")
        }
        if let shards, shards > ShardPlanner.maximumShards {
            throw ValidationError("--shards \(shards) is more than sift will ever plan onto: each shard is a booted simulator — roughly 2–4 GB and a core or two — so \(ShardPlanner.maximumShards) is the most, and this host's own default never goes above 3.")
        }
        if let shardTimeout, shardTimeout < Self.minimumShardTimeoutSeconds {
            throw ValidationError("--shard-timeout \(shardTimeout) is below \(Self.minimumShardTimeoutSeconds): a bound that low fires on a healthy shard before xcodebuild has even launched, and costs the whole suite it was given.")
        }
        guard let repositoryRoot = GitContext.discoverRoot(from: workingDirectory) else {
            throw ValidationError("sift test runs inside a git repository: the ledger that says which simulators to delete, the shard logs and the test durations all live in that repository's .sift/.")
        }
        guard let executable = Bundle.main.executableURL else {
            throw ValidationError("this process cannot name its own executable, and the watcher that deletes this run's simulators after a kill is a detached copy of it.")
        }
        return try TestRunRequest(
            scheme: scheme,
            deviceTypeName: device,
            osVersion: osVersion,
            plan: plan,
            only: only,
            skip: skip,
            container: container(workingDirectory: workingDirectory, repositoryRoot: repositoryRoot),
            passThrough: passThrough,
            requestedShards: shards,
            shardTimeoutSeconds: shardTimeout.map(TimeInterval.init),
            workingDirectory: workingDirectory,
            repositoryRoot: repositoryRoot,
            executable: executable
        )
    }

    /// The project or workspace to build: the one named, the one the working directory and then the repository root decide on, or `nil` for a SwiftPM package — `xcodebuild` resolves a package's own scheme from its manifest with neither flag.
    ///
    /// The refusals arrive as this command's own validation errors so that a caller who has to add a flag is shown which one, under the usage that lists it.
    private func container(workingDirectory: URL, repositoryRoot: URL) throws -> TestInvocation.Container? {
        if let project {
            guard workspace == nil else {
                throw ValidationError("--project and --workspace name the same thing two ways: give one.")
            }
            return .project(project)
        }
        if let workspace {
            return .workspace(workspace)
        }
        let workingDirectoryNames = (try? FileManager.default.contentsOfDirectory(atPath: workingDirectory.path)) ?? []
        let sameDirectory = repositoryRoot.standardizedFileURL == workingDirectory.standardizedFileURL
        let repositoryRootNames = sameDirectory ? [] : (try? FileManager.default.contentsOfDirectory(atPath: repositoryRoot.path)) ?? []
        do {
            return try TestContainerChoice.chosen(
                inWorkingDirectory: workingDirectory,
                names: workingDirectoryNames,
                andRepositoryRoot: sameDirectory ? nil : repositoryRoot,
                names: repositoryRootNames
            )
        } catch let error as TestContainerError {
            throw ValidationError(error.description)
        }
    }

    /// Files this run in the per-user run log, after the answer has already gone out, as a wrapped `sift run` files itself.
    ///
    /// It files under its own name rather than under the `xcodebuild test-without-building` its shards ran: one sharded run is one thing that happened, and the several commands inside it are already kept, in full, under `.sift/runs/`. The failing tests are left unsaid — the shards' own logs name them, and a count of them taken from this answer would be a second spelling of a number the reconciliation already owns.
    private func record(_ result: TestRunResult, milliseconds: Int, repositoryRoot: URL) {
        RunUsageLog.standard(note: { StandardStreams.emitError($0) }).record(
            logKey: "sift test",
            exitCode: result.exitCode,
            answer: RunUsageLog.Answer(lines: result.answer.split(separator: "\n", omittingEmptySubsequences: false).count),
            repositoryRoot: repositoryRoot,
            milliseconds: milliseconds
        )
    }
}

extension TestCommand {
    /// Only the flags, options and arguments come off the command line.
    ///
    /// Spelled out for the reason ``RunCommand``'s keys are: a stored property that is not an argument would otherwise have to be `Decodable` too, and neither an output nor a `simctl` runner is something a decoder can produce.
    enum CodingKeys: String, CodingKey {
        case analyse
        case sweep
        case scheme
        case device
        case osVersion
        case plan
        case against
        case only
        case skip
        case shards
        case shardTimeout
        case project
        case workspace
        case passThrough
        case guardShards
        case rootOptions
    }
}
