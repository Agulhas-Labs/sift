//
// Copyright © Agulhas Labs
//

import Foundation

/// Every step of a sharded run that leaves this process, as one injected seam each, so the sequence itself is a unit test rather than a simulator.
///
/// The sequence is the thing that can be wrong here — the order of a sweep, a watcher, a create, a build and a delete — and every part it orders is already tested on its own. So the seams are closures with live defaults rather than protocols: a test hands each one a recorder that appends to a single event log, and the order is then something to assert rather than something to read.
public struct TestRunEnvironment: Sendable {
    /// How every `simctl` call this run makes is spawned, including the ones the sweep and the cleanup make.
    public let simctl: @Sendable (String, [String]) throws -> SimulatorAccessibility.Output

    /// How one `xcodebuild` is run and answered for.
    public let launch: Launch

    /// How `-showBuildSettings` is run and answered for, with stdout and stderr never merged — the one caller that decodes JSON out of what a build printed, so a warning on stderr must never land inside it.
    public let buildSettings: Launch

    /// How the watcher is started: the executable to start, the run it watches, and the repository holding that run's record.
    public let armWatcher: @Sendable (URL, String, URL) throws -> Watcher

    /// How the shards are run, given the children every one of them is started under.
    public let shardRunner: @Sendable (SetAsideChildren) -> Shards

    /// What is in a directory, with the modification date the `.xctestrun` choice is made on.
    public let listDirectory: @Sendable (URL) -> [Entry]

    /// What this machine can run at once, which is where the default shard count comes from.
    public let hostFacts: @Sendable () -> HostFacts

    /// The crash reports written since the moment handed in, by name.
    public let crashReports: @Sendable (Date) -> [String]

    /// Now, as everything in this run reads it.
    public let now: @Sendable () -> Date

    /// The tests the index declares, whose `@Test("…")` literals and conditional declarations the plan carries so the merge can attribute a quoted ending and decide a conditional test as the unsharded reconciliation does — and `nil` where there is no inventory to read.
    public let declaredInventory: @Sendable () -> TestInventory?

    public init(
        simctl: @escaping @Sendable (String, [String]) throws -> SimulatorAccessibility.Output,
        launch: @escaping Launch,
        buildSettings: @escaping Launch,
        armWatcher: @escaping @Sendable (URL, String, URL) throws -> Watcher,
        shardRunner: @escaping @Sendable (SetAsideChildren) -> Shards,
        listDirectory: @escaping @Sendable (URL) -> [Entry],
        hostFacts: @escaping @Sendable () -> HostFacts,
        crashReports: @escaping @Sendable (Date) -> [String],
        now: @escaping @Sendable () -> Date = { Date() },
        declaredInventory: @escaping @Sendable () -> TestInventory? = { nil }
    ) {
        self.simctl = simctl
        self.launch = launch
        self.buildSettings = buildSettings
        self.armWatcher = armWatcher
        self.shardRunner = shardRunner
        self.listDirectory = listDirectory
        self.hostFacts = hostFacts
        self.crashReports = crashReports
        self.now = now
        self.declaredInventory = declaredInventory
    }
}

public extension TestRunEnvironment {
    /// How one `xcodebuild` is run: the argv in, and what it exited with, what it is answered with, and what it printed.
    typealias Launch = @Sendable ([String]) throws -> Launched

    /// What one wrapped `xcodebuild` left behind.
    struct Launched: Sendable {
        /// The command's own exit code, passed through untouched.
        public let exitCode: Int32

        /// The `sift run`-style answer for this command, which is what a failed build is answered with.
        public let answer: String

        /// What the command printed where nothing was filtered, which is the only way `-showBuildSettings` reaches its reader.
        public let output: Data

        public init(exitCode: Int32, answer: String, output: Data = Data()) {
            self.exitCode = exitCode
            self.answer = answer
            self.output = output
        }
    }

    /// The owner's end of a watcher, as the sequence needs it: who it is, and how it is let go.
    ///
    /// A value over ``ShardGuardian/Handle`` because the release is the step the order of this run turns on — it is the last thing that happens, after the devices are gone — and a test has to be able to see it happen.
    struct Watcher: Sendable {
        /// The watcher as the run's record names it.
        public let identity: ShardLedger.Identity

        private let releasing: @Sendable () -> Bool
        private let watching: @Sendable () -> Bool

        public init(
            identity: ShardLedger.Identity,
            watching: @escaping @Sendable () -> Bool = { true },
            release: @escaping @Sendable () -> Bool
        ) {
            self.identity = identity
            self.watching = watching
            releasing = release
        }

        /// Tells the watcher the devices are gone, and answers whether it was still there to be told.
        @discardableResult
        public func release() -> Bool {
            releasing()
        }

        /// Whether the watcher is still there, asked without telling it anything.
        public func isWatching() -> Bool {
            watching()
        }
    }

    /// The shard runner, as the sequence uses it: run the assignments, or end them where the run is cancelled under it.
    struct Shards: Sendable {
        private let running: @Sendable ([ShardRunner.Assignment]) -> [ShardOutcome]
        private let cancelling: @Sendable () -> Void

        public init(
            run: @escaping @Sendable ([ShardRunner.Assignment]) -> [ShardOutcome],
            cancel: @escaping @Sendable () -> Void
        ) {
            running = run
            cancelling = cancel
        }

        public func run(_ assignments: [ShardRunner.Assignment]) -> [ShardOutcome] {
            running(assignments)
        }

        public func cancel() {
            cancelling()
        }
    }

    /// One file in the products directory: its name, and when it was last written.
    ///
    /// The date is what tells this build's `.xctestrun` from one an earlier build of another plan left in the same directory, which is the only thing standing between an unnamed plan and a run of the wrong set of targets.
    struct Entry: Sendable, Equatable {
        public let name: String
        public let modified: Date

        public init(name: String, modified: Date) {
            self.name = name
            self.modified = modified
        }
    }

    /// What the host can run at once, as the default shard count reads it.
    struct HostFacts: Sendable, Equatable {
        public let performanceCores: Int
        public let memoryGB: Int

        public init(performanceCores: Int, memoryGB: Int) {
            self.performanceCores = performanceCores
            self.memoryGB = memoryGB
        }
    }
}

public extension TestRunEnvironment {
    /// The environment a real run has: every seam on the tool it names.
    ///
    /// `children` is the run's own set-aside, and every `xcodebuild` here is started under it — the build and the enumeration as much as the shards — because the teardown ends exactly what it holds, and a child outside it is one a killed run leaves behind.
    static func live(for request: TestRunRequest, children: SetAsideChildren) -> TestRunEnvironment {
        let workingDirectory = request.workingDirectory
        let repositoryRoot = request.repositoryRoot
        return TestRunEnvironment(
            simctl: liveSimctl(),
            launch: liveLaunch(workingDirectory: workingDirectory, repositoryRoot: repositoryRoot, children: children),
            buildSettings: liveBuildSettings(workingDirectory: workingDirectory),
            armWatcher: { executable, runID, root in
                let handle = try ShardGuardian.arm(executable: executable, runID: runID, repositoryRoot: root)
                return Watcher(identity: handle.watcher, watching: { handle.isWatching() }, release: { handle.release() })
            },
            shardRunner: { children in
                let runner = ShardRunner(
                    workingDirectory: workingDirectory,
                    repositoryRoot: repositoryRoot,
                    children: children
                )
                return Shards(run: { runner.run($0) }, cancel: { runner.cancel() })
            },
            listDirectory: liveListing,
            hostFacts: liveHostFacts,
            crashReports: liveCrashReports,
            declaredInventory: { liveInventory(repositoryRoot: repositoryRoot) }
        )
    }

    /// The tests this repository's index declares, and `nil` where there is no index or it cannot be read.
    ///
    /// **Nothing here creates or freshens an index.** A run is a run and not a query: it reads the database where one is already sitting, and a repository that has never been indexed loses only an attribution it could never have made — every count it had before stands unchanged, with the quoted ending stated and the test it named reported missing. An index that is behind the working tree costs the same way and no worse, for a literal written since it was last built.
    ///
    /// The read is failure-tolerant for the same reason: a database this process cannot open is a run that should go on running, not a run that refuses after its simulators are already booted.
    static func liveInventory(repositoryRoot: URL) -> TestInventory? {
        let databasePath = SiftPaths.cache(in: repositoryRoot).appendingPathComponent(SiftPaths.indexFileName).path
        guard FileManager.default.fileExists(atPath: databasePath),
              let store = try? IndexStore(databasePath: databasePath)
        else {
            return nil
        }
        return try? TestInventory.read(store: store, repositoryRoot: repositoryRoot)
    }

    /// Every `simctl` a run makes, each bounded by what the operation it names may honestly cost.
    ///
    /// `spawn` is a parameter so that the choosing can be watched: the bug it is here to prevent is invisible from outside — one seam standing for create, boot and delete alike takes whichever bound was written into it, and a boot ended after a listing's five seconds fails a run that was doing nothing wrong.
    static func liveSimctl(
        spawn: @escaping @Sendable (String, [String], TimeInterval) throws -> SimulatorAccessibility.Output
            = { try SimulatorAccessibility.spawn($0, $1, deadline: $2) }
    ) -> @Sendable (String, [String]) throws -> SimulatorAccessibility.Output {
        { executable, arguments in
            try spawn(executable, arguments, ShardDevices.deadline(of: arguments))
        }
    }

    /// One `xcodebuild` through the launcher `sift run` already answers a build with, so a failed build here reads exactly as a failed `sift run` does.
    ///
    /// **It is started under the run's `children`, in a session of its own.** A plain child is one `children.endAll()` cannot reach: a `SIGTERM` taken between the sweep and the shards would leave `sift test` blocked on the build's pipe until the build finished, and the interruption the caller asked for would arrive minutes late.
    static func liveLaunch(workingDirectory: URL, repositoryRoot: URL?, children: SetAsideChildren) -> Launch {
        { arguments in
            let outcome = try RunLauncher(workingDirectory: workingDirectory, repositoryRoot: repositoryRoot).run(arguments, children: children)
            let answer = outcome.filteredAnswer(workingDirectory: workingDirectory)?.text
                ?? "\(arguments.joined(separator: " ")) exited \(outcome.exitCode) and the filter found nothing that says why\(outcome.log.map { " — its log is at \($0.url.path)" } ?? "")"
            return Launched(exitCode: outcome.exitCode, answer: answer)
        }
    }

    /// `-showBuildSettings` alone, run through `/usr/bin/env` rather than the launcher — the one caller that reads JSON out of what a build printed, so stdout must reach it uncontaminated by anything `xcodebuild` writes to stderr, which the launcher's single pipe would otherwise merge in.
    static func liveBuildSettings(workingDirectory: URL) -> Launch {
        { arguments in
            let output = try SimulatorAccessibility.spawn("/usr/bin/env", arguments, deadline: 120, in: workingDirectory)
            let exitCode: Int32 = output.succeeded ? 0 : 1
            return Launched(exitCode: exitCode, answer: output.standardError, output: Data(output.standardOutput.utf8))
        }
    }

    /// What is in a directory, with each entry's modification date, and nothing at all where the directory cannot be read.
    static func liveListing(_ directory: URL) -> [Entry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.map { name in
            let attributes = try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return Entry(name: name, modified: attributes?[.modificationDate] as? Date ?? Date.distantPast)
        }
    }

    /// What the host can run at once: the performance cores, since the efficiency ones do not finish an `xcodebuild` in a time anybody planned for, and whole gigabytes of memory.
    static func liveHostFacts() -> HostFacts {
        var cores = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = ProcessInfo.processInfo.activeProcessorCount
        }
        let gigabytes = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        return HostFacts(performanceCores: max(1, cores), memoryGB: max(1, gigabytes))
    }

    /// The crash reports written since `date`, by name — a missing test is nearly always one of these, and the name is what a reader opens.
    static func liveCrashReports(since date: Date) -> [String] {
        let directory = SiftPaths.accountHome
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.filter { name in
            guard name.hasSuffix(".ips") else {
                return false
            }
            let url = directory.appendingPathComponent(name)
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            guard let modified = attributes?[.modificationDate] as? Date, modified >= date else {
                return false
            }
            return isTestCrashReport(named: name, header: firstLine(of: url), since: date)
        }
        .sorted()
    }

    /// A system process's crash report is still named this way where its header cannot be read at all — nothing in `Library/Logs/DiagnosticReports` guarantees the header survives intact — so a name on this list is the second tier `isTestCrashReport` falls to rather than the default of keeping what it cannot rule out.
    private static let systemProcessNamePrefixes = ["PosterBoard"]

    /// Whether a crash report is one a test run could have caused: stamped inside the run, and not one of the system's own daemons.
    ///
    /// The header's `is_first_party` decides whenever it carries the field: whatever the name is, that alone settles it (`chronod` and its kind carry no bundle identifier at all). ``systemProcessNamePrefixes`` decides instead whenever the header does not carry the field — nil, unparseable, or parsed with the field itself missing — since none of those cases has anything from the header to read. A bare `xctest` host is Apple's and is kept by name, since it is what a package's tests crash in.
    static func isTestCrashReport(named name: String, header: String?, since date: Date) -> Bool {
        let stamp = name.split(separator: "-").suffix(4).joined(separator: "-").prefix(17)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        if let stamped = formatter.date(from: String(stamp)), stamped < date.addingTimeInterval(-1) {
            return false
        }
        if name.hasPrefix("xctest") {
            return true
        }
        guard let header, let data = header.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isFirstParty = fields["is_first_party"] as? Int
        else {
            return !systemProcessNamePrefixes.contains { name.hasPrefix($0) }
        }
        return isFirstParty != 1
    }

    private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return String(data: head, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}
