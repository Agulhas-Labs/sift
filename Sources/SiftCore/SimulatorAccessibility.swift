//
// Copyright © Agulhas Labs
//

import Foundation

/// The simulator preference an in-process accessibility suite depends on, which every UI-test session switches off as it ends — and which a wrapped test run switches back on.
///
/// **A test run that leaves the device worse than it found it is a run that breaks the next one.** When a UI-test session ends, the test manager's teardown stores both `AccessibilityEnabled` and `ApplicationAccessibilityEnabled` as off on that device, within milliseconds of `xcodebuild` returning. It is one write per session, not a stream of them. `AccessibilityEnabled` is the key that decides whether a hosted view builds accessibility elements at all, so the *next* package run on the same simulator fails every test that reads one — hundreds of them, failing in a way that looks exactly like a code defect in code the UI suite never touched. Measured in a consuming project on 16 Sep 2026: 466 failures in 3068 tests straight after the UI suite, and 3068 passing after re-arming the preference.
///
/// **Read and written through the runtime's own `defaults`, never `/usr/bin/defaults`.** `simctl spawn` runs an absolute path from the host, so the absolute spelling is the host's own tool looking for a domain the simulator keeps in its own preference daemon: it writes nowhere the simulator reads, and reports that the domain does not exist. The bare name is resolved inside the runtime's root, which is why it is the one spelling that works.
///
/// **A write is only made over a preference seen off.** `sift run` returns after `xcodebuild` has exited, so a teardown has already landed by the time this reads; a key that reads on stays unwritten, and the run pays one short poll rather than a write and its confirmation.
///
/// **Every spawn's wait is bounded, so no restore can hold up the run it follows.** What is bounded is how long `sift run` waits, not the lifetime of everything a spawn started: the child itself is ended at the deadline, but the `defaults` that `simctl spawn` starts runs under CoreSimulator rather than as a descendant of the child, so no signal sent from here — to the child or to its process group — reaches it, and one that wedged is left to the service that owns it. A wedged simulator or a hung `CoreSimulator` service would otherwise block `sift run` forever *after* the wrapped command has already exited, and the exit code the caller is waiting on would never arrive. Each spawn gets ``spawnDeadline`` seconds of wall clock and is then ended — `SIGTERM`, then `SIGKILL` a moment later — and reports that it timed out, which the state machine reads as a failed read or a failed write like any other. Both waits above are clocks rather than counts of spawns, so the worst case for one device is its own budget plus the one spawn that was in flight when the budget ran out: at most about seven seconds in the poll (two seconds of budget and a five-second read) and about twenty-eight in the write loop (ten seconds of budget and a last round of two writes, the 2.5s confirmation delay and a read) — **about 35 seconds for a device whose every spawn wedges**, against a hang with no end at all before it. A run naming several simulators pays that per device, one after another.
public struct SimulatorAccessibility {
    /// The preference domain the simulator keeps it in.
    public static var domain: String {
        "com.apple.Accessibility"
    }

    /// The key a hosted view consults before it builds accessibility elements, measured rather than assumed.
    public static var key: String {
        "AccessibilityEnabled"
    }

    /// Every key the session teardown switches off, in the order a restore puts them back — the deciding one first.
    ///
    /// The second is restored as well although nothing here needs it, because the teardown took it in the same call and a restore that put back half of what was taken would leave the device other than it found it.
    public static var keys: [String] {
        [key, "ApplicationAccessibilityEnabled"]
    }

    /// How long any one spawn may take before it is ended and reported as timed out, in seconds of wall clock.
    ///
    /// Generous for the work — a `simctl spawn` of `defaults` is milliseconds — because the number is not a performance budget but the point at which a wedged service stops being worth waiting for. What it bounds is stated on the type.
    public static var spawnDeadline: TimeInterval {
        5
    }

    /// Re-arms the preference for every simulator `arguments` ran its tests on, in the order argv names them — and is empty where this invocation put no test run on a simulator.
    ///
    /// Whatever the run's exit code: a UI suite that failed tore its session down exactly as a green one does.
    ///
    /// **Every simulator destination on the command line, not just the first.** An invocation may carry several, and each one's session tears its own device down; restoring one of them and reading as a success would leave the rest off while the answer said the run was clean. They are restored one after another, in the order they were written, and each one gets its own line of the answer.
    ///
    /// - Parameters:
    ///   - arguments: the wrapped command, executable first — the same array recognition and the verdict contract read.
    ///   - log: the run's own transcript, read only when `arguments` carries no `-destination` at all — the one place a default destination Xcode resolved for itself shows.
    ///   - run: spawns a child and returns what it said; a script in a test, so nothing here spawns `simctl` under the suite.
    ///   - pause: waits, between two reads of the preference and before confirming a write.
    ///   - now: the clock both waits are bounded by, so a device whose preference never moves costs the budget rather than however many spawns fit in it.
    public static func restore(
        after arguments: [String],
        log: String? = nil,
        run: (String, [String]) throws -> Output = { try spawn($0, $1) },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Date = { Date() }
    ) -> [Restoration] {
        SimulatorDestination.simulatorsOfTestRun(arguments, log: log).map { destination in
            switch destination {
            case let .identified(udid):
                restore(udid: udid, run: run, pause: pause, now: now)
            case let .named(name, osVersion):
                if let udid = resolve(name: name, osVersion: osVersion, run: run) {
                    restore(udid: udid, run: run, pause: pause, now: now)
                } else {
                    Restoration(udid: nil, state: .undetermined(reason: "no single available simulator is named \(name)\(osVersion.map { " on OS \($0)" } ?? "")"))
                }
            case .unnamed:
                Restoration(udid: nil, state: .undetermined(reason: "the run named no device — a simulator platform with no device on it, or no -destination at all — so there is nothing to read the preference from; name the device with -destination id=<udid> to have it checked"))
            }
        }
    }

    /// Switches the preference back on for one device, and says what it did.
    ///
    /// The first read decides everything. Off is the teardown's own write, so both keys go back on and the write is confirmed a few seconds later — seeing a write land is not seeing it hold, and a late teardown is the case that tells them apart. On, still on after the short poll, is a device nothing has to be done to. A read that fails is one of three different things and is answered as whichever it is — see ``Restoration/State``.
    public static func restore(
        udid: String,
        run: (String, [String]) throws -> Output,
        pause: (TimeInterval) -> Void,
        now: () -> Date
    ) -> Restoration {
        switch waitForTeardown(udid: udid, run: run, pause: pause, now: now) {
        case let .value(value) where value == offValue:
            write(udid: udid, run: run, pause: pause, now: now)
        case .value:
            Restoration(udid: udid, state: .alreadyOn)
        case .never:
            Restoration(udid: udid, state: .neverSwitchedOff)
        case let .unreachable(reason):
            Restoration(udid: udid, state: .unreached(reason: reason))
        case let .unreadable(reason):
            Restoration(udid: udid, state: .unconfirmed(reason: reason))
        }
    }

    /// The one qualification a run's headline carries for however many devices it acted on: the worst of them.
    ///
    /// The worst, because the headline is one line and a run that left one device off is a run a reader has to act on whatever the others did — and a qualification is dropped only where *every* device is known fit. `nil` for a run that named no simulator at all.
    public static func qualification(of restorations: [Restoration]) -> String? {
        restorations.max { $0.severity < $1.severity }?.qualification
    }

    /// The `simctl` argument vectors that switch the preference back on for a device, one per key.
    ///
    /// **`defaults`, never `/usr/bin/defaults`**: `simctl spawn` runs an absolute path from the host, so the absolute spelling writes nowhere the simulator reads.
    public static func enableArguments(udid: String) -> [[String]] {
        keys.map { enableArguments(udid: udid, key: $0) }
    }

    /// The `simctl` argument vector that reads the deciding key through the runtime's own preference daemon.
    public static func readArguments(udid: String) -> [String] {
        ["simctl", "spawn", udid, runtimeDefaults, "read", domain, key]
    }

    /// The commands a person runs to do what a restore does, for the case where the restore could not.
    ///
    /// Generated from ``enableArguments(udid:)``, so the instruction cannot drift from what the tool itself would have run. A device this could not name is spelled with the placeholder the reader substitutes.
    public static func command(udid: String?) -> String {
        enableArguments(udid: udid ?? "<udid>").map { "\(xcrunName) \($0.joined(separator: " "))" }.joined(separator: " && ")
    }

    /// The child ``spawn(_:_:deadline:in:environment:)`` starts, its standard input the null device.
    ///
    /// **Never this process's own standard input.** `sift install` asks its questions on the terminal and then spawns `claude mcp add`; a child handed that terminal, in a process group that is not the terminal's foreground one, is stopped the moment it touches it, and waited on until its deadline. Every child here is asked a question by its arguments, never by a person.
    static func process(_ executable: String, _ arguments: [String], in directory: URL?, environment: [String: String]?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Spawns a child and returns what it said — the live runner, and the default of every entry point above.
    ///
    /// **Bounded, on every path out.** The wait for exit is a deadline rather than a `waitUntilExit`, the child is ended when it expires, and the pipes are drained on the reader's own queue rather than by a `readDataToEndOfFile` on this thread — because a grandchild that inherited the write end holds the pipe open long after the child is gone, and a read of it would extend a bounded wait into an unbounded one. What comes back from an expired call is a failed ``Output`` whose standard error says it timed out, which every caller above reads as a read or a write that did not succeed.
    ///
    /// - Parameters:
    ///   - deadline: how long the child may take before it is ended, in seconds of wall clock. The call itself returns within `deadline` plus a short grace for its read ends to close, and when the child is ended, plus the two short grace windows it is given to die in as well.
    ///   - directory: where the child is started, for a caller whose arguments are only correct relative to a directory of its own — a relative `-project` path, say. The host's own working directory where `nil`.
    ///   - environment: the child's whole environment, for a caller that must ask as another command would run. This process's own where `nil`.
    public static func spawn(
        _ executable: String,
        _ arguments: [String],
        deadline: TimeInterval = spawnDeadline,
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> Output {
        let process = process(executable, arguments, in: directory, environment: environment)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let started = Date()
        do {
            try process.run()
        } catch {
            ProcessStreams.abandon(output, errors)
            throw error
        }
        // Read from here on: what the child writes before the handlers are in place waits in the pipe for them.
        let streams = SpawnStreams(standardOutput: output, standardError: errors)
        guard exited.wait(timeout: .now() + deadline) == .success else {
            end(process, exited: exited)
            let collected = streams.collected()
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return Output(
                succeeded: false,
                standardOutput: collected.standardOutput,
                standardError: "\(collected.standardError)the spawn timed out: \(name) did not finish within \(seconds(deadline)) and was ended"
            )
        }
        // Exit is not end of output: the handlers may still owe the last bytes, and a grandchild may owe them
        // forever. What is left of the deadline is what they get.
        streams.waitForEnd(within: deadline - Date().timeIntervalSince(started))
        let collected = streams.collected()
        return Output(succeeded: process.terminationStatus == 0, standardOutput: collected.standardOutput, standardError: collected.standardError)
    }
}

private extension SimulatorAccessibility {
    /// What one read of the deciding key found.
    ///
    /// Four outcomes rather than two, because the three ways a read can fail are three different things to say — see ``SimulatorAccessibility/Restoration/State``.
    enum Reading: Equatable {
        /// The value the device's own `defaults` printed.
        case value(String)
        /// `defaults` says the domain or the key is not there, so no session has ever switched the preference off on this device and there is nothing to restore.
        case never
        /// No spawn can reach the device: it is not booted, or `simctl` knows no device of that identifier.
        case unreachable(reason: String)
        /// The read failed some other way, a spawn that hit its deadline included.
        case unreadable(reason: String)
    }

    /// Reads until the teardown's `0` shows or ``teardownBudget`` has elapsed, answering what the last read found.
    ///
    /// **The budget is short because the wait is nearly over before it starts.** `sift run` returns only once `xcodebuild` has exited, and the teardown's write lands within milliseconds of that, so the first read almost always settles it; what is left to wait for is a runner that outlives its `xcodebuild` by a moment. A clock rather than a count of reads, because each read is a `simctl spawn` whose cost varies — and this is paid by every simulator test run, including the ones that started no UI session at all.
    ///
    /// **A device nothing can reach ends the poll at once.** Polling exists to catch a teardown that has not landed yet; a device that is not booted, or that `simctl` does not know, will not answer the tenth read any better than the first, and making a failing run wait two seconds to be told so is two seconds spent on nothing. A *missing* domain keeps its poll, because a first-ever session on this device writes the domain into existence as it tears down.
    static func waitForTeardown(
        udid: String,
        run: (String, [String]) throws -> Output,
        pause: (TimeInterval) -> Void,
        now: () -> Date
    ) -> Reading {
        let deadline = now().addingTimeInterval(teardownBudget)
        while true {
            let reading = read(udid: udid, run: run)
            if reading == .value(offValue) {
                return reading
            }
            if case .unreachable = reading {
                return reading
            }
            guard now() < deadline else {
                return settled(reading)
            }
            pause(pollInterval)
        }
    }

    /// What the poll's last reading means once there is no time left to read again: anything that is neither the teardown's `0` nor a plain `1` is a key nobody read, whatever bytes came back.
    static func settled(_ reading: Reading) -> Reading {
        guard case let .value(value) = reading, value != onValue else {
            return reading
        }
        return .unreadable(reason: "\(domain) \(key) could not be read")
    }

    /// Writes both keys back on and confirms the write held, writing again for as long as ``confirmationBudget`` lasts if a late teardown undoes it.
    static func write(
        udid: String,
        run: (String, [String]) throws -> Output,
        pause: (TimeInterval) -> Void,
        now: () -> Date
    ) -> Restoration {
        let deadline = now().addingTimeInterval(confirmationBudget)
        // What the deciding key last read before the next write: off on the way in, since that is the reading
        // that got here, and off again whenever a confirmation read `0` — the two reads that make "left off" a
        // known state rather than a guess.
        var lastReadOff = true
        var writes = 0
        while true {
            for key in keys {
                guard let written = try? run(xcrunPath, enableArguments(udid: udid, key: key)), written.succeeded else {
                    // Known off only when the key that failed is the deciding one and it last read off. A failure
                    // on a later key comes after the deciding key was written and never read back, so that is
                    // unknown — as is a deciding key nobody has seen off.
                    let reason = "writing \(domain) \(key) did not succeed"
                    let knownOff = key == Self.key && lastReadOff
                    return Restoration(udid: udid, state: knownOff ? .failed(reason: reason) : .unconfirmed(reason: reason))
                }
            }
            writes += 1
            pause(confirmationDelay)
            guard case let .value(held) = read(udid: udid, run: run) else {
                return Restoration(udid: udid, state: .unconfirmed(reason: "\(domain) \(key) could not be read back"))
            }
            if held == onValue {
                return Restoration(udid: udid, state: .restored)
            }
            lastReadOff = held == offValue
            // Written, and off again a moment later: a teardown landed after the write. Write again, for as long
            // as the budget lasts — a teardown is one write per session, so this ends quickly or not at all.
            guard now() < deadline else {
                let plural = writes == 1 ? "" : "s"
                return Restoration(udid: udid, state: .failed(reason: "\(domain) \(key) was switched back off after \(writes) write\(plural)"))
            }
        }
    }

    /// The udid a named destination resolves to in `simctl`'s listing, or `nil` when the listing does not settle it.
    static func resolve(name: String, osVersion: String?, run: (String, [String]) throws -> Output) -> String? {
        guard let listing = try? run(xcrunPath, SimulatorDestination.listArguments), listing.succeeded else {
            return nil
        }
        return SimulatorDestination.device(named: name, osVersion: osVersion, inListing: Data(listing.standardOutput.utf8))
    }

    static func enableArguments(udid: String, key: String) -> [String] {
        ["simctl", "spawn", udid, runtimeDefaults, "write", domain, key, "-bool", "true"]
    }

    /// The deciding key's value as the device's own `defaults` reports it, or which way the read failed.
    static func read(udid: String, run: (String, [String]) throws -> Output) -> Reading {
        guard let result = try? run(xcrunPath, readArguments(udid: udid)) else {
            return .unreadable(reason: "\(domain) \(key) could not be read")
        }
        guard result.succeeded else {
            return failure(from: result.standardError)
        }
        return .value(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Which of the three ways a read failed this standard error describes.
    ///
    /// **The ordinary failing run is the one this exists for.** `com.apple.Accessibility` is written into existence by a session's own teardown, so a device no session has ever run on does not have the domain at all — which is every run that died before a session started: a scheme error, a compile error, a destination that never resolved. Reading that as "the preference could not be read" put a warning on the headline of the commonest failing run there is, about a device nothing had switched off.
    ///
    /// The wordings are matched as fragments because they are another tool's prose, probed on 17 Sep 2026 against `xcrun simctl spawn` and `defaults` on macOS 27: `Error: Domain 'com.apple.Accessibility' not found.`, `Error: Could not find key 'AccessibilityEnabled' in domain 'com.apple.Accessibility'.`, `Process spawn via launchd failed because device is not booted.` and `Invalid device: <udid>`. The older `does not exist` spelling of the first pair is matched too, since the deployment floor is older than the machine this was probed on. Anything else is the unknown it was before, and keeps the warning it earned.
    static func failure(from standardError: String) -> Reading {
        let text = standardError.lowercased()
        // The device before the domain: a device out of reach is why a read of *any* domain on it failed, and
        // reading that as a domain nobody has written would go quiet over a device this never looked at.
        for (shape, reason) in unreachableShapes where text.contains(shape) {
            return .unreachable(reason: reason)
        }
        if missingShapes.contains(where: text.contains) {
            return .never
        }
        let detail = standardError.split(separator: "\n").first.map { " (\($0.trimmingCharacters(in: .whitespaces)))" } ?? ""
        return .unreadable(reason: "\(domain) \(key) could not be read\(detail)")
    }

    /// The standard-error fragments that say the preference was never written on this device, spelled tightly enough that a `defaults` the runtime could not run at all is not mistaken for one.
    static var missingShapes: [String] {
        ["domain '\(domain.lowercased())' not found", "could not find key '\(key.lowercased())'", "does not exist"]
    }

    /// The standard-error fragments that say the device itself is out of reach, each with what a reader is told about it.
    static var unreachableShapes: [(String, String)] {
        [
            ("device is not booted", "the simulator is shut down"),
            ("unable to lookup in current state", "the simulator is shut down"),
            ("invalid device", "simctl knows no device with that identifier"),
        ]
    }

    /// Ends a child that has passed its deadline: the polite signal, a moment to take it, then the one it cannot ignore.
    ///
    /// The second wait is what makes the child *gone* rather than merely signalled by the time this returns — a process that ignores `SIGTERM` would otherwise outlive the call that gave up on it. The child only: anything it started is not signalled, for the reason the type states, and the pipes are drained against a deadline precisely so that a survivor holding one open cannot extend the wait.
    static func end(_ process: Process, exited: DispatchSemaphore) {
        let pid = process.processIdentifier
        process.terminate()
        guard exited.wait(timeout: .now() + terminationGrace) != .success else {
            return
        }
        kill(pid, SIGKILL)
        _ = exited.wait(timeout: .now() + terminationGrace)
    }

    /// How long an ended child is given to die, in seconds — once after `SIGTERM` and once after `SIGKILL`.
    static var terminationGrace: TimeInterval {
        0.25
    }

    /// A duration as a sentence says it: `5s`, `0.5s`.
    static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? "\(Int(interval))s" : "\(interval)s"
    }

    /// The runtime's `defaults`, resolved inside the simulator's root because it is not an absolute path.
    static var runtimeDefaults: String {
        "defaults"
    }

    /// What the preference reads when on — the state an in-process accessibility suite needs.
    static var onValue: String {
        "1"
    }

    /// What it reads once the session teardown has switched it off.
    static var offValue: String {
        "0"
    }

    /// How long the restore gives the teardown to show before reporting the preference already on, in seconds of wall clock.
    static var teardownBudget: TimeInterval {
        2
    }

    static var pollInterval: TimeInterval {
        0.25
    }

    /// How long after a write the restore reads again to see that it held.
    static var confirmationDelay: TimeInterval {
        2.5
    }

    /// How long the restore keeps writing back a value a late teardown keeps undoing before it says so.
    static var confirmationBudget: TimeInterval {
        10
    }
}

extension SimulatorAccessibility {
    /// The two pipes of one spawn, drained on the reader's own queue so that neither the child nor anything it left behind can hold this thread.
    ///
    /// A `readDataToEndOfFile` here would be an unbounded wait wearing a bounded one's clothes: the end of the file is the write end being closed, and a grandchild that inherited it — a launched service, a `&`-backgrounded command — keeps it open after the child this spawned is dead. So the bytes are accumulated as they arrive and the caller takes whatever has arrived when its deadline is up.
    ///
    /// The read ends are watched by dispatch sources this owns rather than by a handle's `readabilityHandler`, because a handle given a handler duplicates its descriptor for the watch and closes that duplicate, and on a loaded machine the handle itself, only once the watch's cancellation has run — after the call that cleared the handler and closed the handle has returned. Here each read end is closed in its own source's cancel handler, the one place dispatch allows it, and the caller waits for both closes before it returns.
    ///
    /// Each read end is made non-blocking before it is watched, so that no read can hold the queue — and with it the cancel handler that closes the descriptor — for as long as a grandchild keeps the write end open: a read that finds nothing waits for the next event instead. And because a cancelled source is never handed the events still pending on it, each cancel handler reads what is left in its pipe before it closes the read end, up to ``finalReadLimit`` bytes, so that what the child wrote as it was ended is not dropped.
    final class SpawnStreams: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()
        private var open = 2
        private let ended = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        private let handles: [FileHandle]
        private var sources: [DispatchSourceRead] = []

        /// Starts watching both read ends on `queue`, which runs every read and every close.
        init(standardOutput: Pipe, standardError: Pipe, queue: DispatchQueue = DispatchQueue(label: "SimulatorAccessibility.spawn")) {
            handles = [standardOutput.fileHandleForReading, standardError.fileHandleForReading]
            sources = handles.indices.map { drain($0, on: queue) }
            for source in sources {
                source.resume()
            }
        }

        /// What has arrived so far, decoded — and, for the caller that timed out, the last thing this reads.
        func collected() -> (standardOutput: String, standardError: String) {
            stop()
            lock.lock()
            defer { lock.unlock() }
            return (String(bytes: standardOutput, encoding: .utf8) ?? "", String(bytes: standardError, encoding: .utf8) ?? "")
        }

        /// Waits for both pipes to reach end of file, for no longer than `interval` seconds.
        func waitForEnd(within interval: TimeInterval) {
            guard interval > 0 else {
                return
            }
            _ = ended.wait(timeout: .now() + interval)
        }

        /// How many bytes a cancel handler reads from its pipe before closing it, so that a grandchild writing without end cannot hold the close.
        static var finalReadLimit: Int {
            1 << 20
        }

        /// A source that appends what the non-blocking read end at `index` delivers, cancels itself at end of file, and reads what is left before closing the read end once cancelled.
        private func drain(_ index: Int, on queue: DispatchQueue) -> DispatchSourceRead {
            let handle = handles[index]
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [self] in
                let read = Self.read(descriptor)
                if let bytes = read.bytes {
                    append(bytes, isError: index == 1)
                    return
                }
                // Nothing to read yet is not the end: the next event brings what this one did not.
                guard read.error != EAGAIN else {
                    return
                }
                // A read that finds the end of the file ends the stream, and so does one that fails.
                reachedEnd()
                sources[index].cancel()
            }
            source.setCancelHandler { [self] in
                var remaining = Self.finalReadLimit
                while remaining > 0, let bytes = Self.read(descriptor, upTo: remaining).bytes {
                    append(bytes, isError: index == 1)
                    remaining -= bytes.count
                }
                try? handle.close()
                released.signal()
            }
            return source
        }

        /// One read of up to 64 KiB, and no more than `limit`, from a non-blocking descriptor, retried when a signal interrupts it: the bytes read, or `nil` with the `errno` of a read that found none, which is zero at end of file.
        private static func read(_ descriptor: Int32, upTo limit: Int = 65536) -> (bytes: Data?, error: Int32) {
            var buffer = [UInt8](repeating: 0, count: min(65536, limit))
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    return (Data(buffer[..<count]), 0)
                }
                let error = count == 0 ? 0 : errno
                if error != EINTR {
                    return (nil, error)
                }
            }
        }

        private func append(_ data: Data, isError: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isError {
                standardError.append(data)
            } else {
                standardOutput.append(data)
            }
        }

        private func reachedEnd() {
            lock.lock()
            open -= 1
            let last = open == 0
            lock.unlock()
            if last {
                ended.signal()
            }
        }

        /// Stops reading whatever is still holding the write end open, and waits for both read ends to be closed.
        ///
        /// A handler already running finishes before its source's cancel handler runs, so a read end is never closed under a read of it, and each cancel handler takes what is left in its pipe before it closes the read end. The wait is bounded like every other on the spawn's way out: a cancel handler that has not run when it expires still closes its read end, only after the call has returned.
        private func stop() {
            for source in sources {
                source.cancel()
            }
            let deadline = DispatchTime.now() + SimulatorAccessibility.terminationGrace
            for _ in sources {
                _ = released.wait(timeout: deadline)
            }
        }
    }
}

/// How every `simctl` call in this module is spelled, since the other simulator work here spawns the same tool and quotes the same command back to a person.
extension SimulatorAccessibility {
    static var xcrunPath: String {
        "/usr/bin/\(xcrunName)"
    }

    static var xcrunName: String {
        "xcrun"
    }
}

public extension SimulatorAccessibility {
    /// What a spawned tool said, down to the three things this reads.
    struct Output: Equatable, Sendable {
        public let succeeded: Bool
        public let standardOutput: String
        /// What the tool printed on the way to failing — the only thing that says *which* failure it was, and what a run that timed out reports itself through.
        public let standardError: String

        public init(succeeded: Bool, standardOutput: String, standardError: String = "") {
            self.succeeded = succeeded
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    /// What a restore did, and the one line an answer prints about it.
    struct Restoration: Equatable, Sendable {
        /// The device acted on, or `nil` where argv and the listing between them did not name one.
        public let udid: String?
        public let state: State

        public init(udid: String?, state: State) {
            self.udid = udid
            self.state = state
        }

        /// The one line the answer prints about this device, or `nil` where there is nothing to say.
        ///
        /// **Silent over a preference that read on, unless the failures read empty trees.** That is the reading of nearly every simulator run, green ones included, and a line printed on all of them is a line every reader learns to filter out — so the device that read on throughout the poll earns a line only where the run's failures have the shape a later teardown would explain. A preference read off is always said, in one short line, because the reader's next suite on that device depends on it; a device no session ever wrote says nothing, since nothing was switched off.
        ///
        /// **The re-arm command is printed once, and only where the reader may have a write to make**: never beside a restore that saw its own write hold, and in full everywhere else, because this tool has no shorter route to the same two writes. Whether the failures read empty trees is the reading ``RunDominantFailureClass/readsEmptyTree`` makes.
        public func note(failuresReadEmptyTrees: Bool) -> String? {
            let manual = SimulatorAccessibility.command(udid: udid)
            let device = udid ?? "<udid>"
            return switch state {
            case .restored:
                "accessibility: read off on \(device) after the run; sift switched it back on"
            case .alreadyOn:
                failuresReadEmptyTrees
                    ? "accessibility: read on for \(device) after the run, yet the failures read empty trees — if a late teardown switched it off, re-arm: \(manual)"
                    : nil
            case .neverSwitchedOff:
                nil
            case let .unreached(reason):
                "accessibility: not checked on \(device) (\(reason)) — if accessibility tests read empty trees, re-arm: \(manual)"
            case let .failed(reason):
                "accessibility: left off on \(device) (\(reason)) — re-arm: \(manual)"
            case let .unconfirmed(reason):
                "accessibility: not confirmed on for \(device) (\(reason)) — re-arm: \(manual)"
            case let .undetermined(reason):
                "accessibility: no device determined (\(reason)) — if accessibility tests read empty trees, re-arm: \(manual)"
            }
        }

        /// What this qualifies the run's verdict line by, or `nil` when nothing about the device is worth the headline.
        ///
        /// On the headline rather than only in the note, because the headline is what a reader takes in first and a device that cannot run the next suite is exactly the thing they have to act on. **Only where something may actually have been switched off**: a domain no session ever wrote, and a device that could not be reached at all, are not the run's verdict's business — the first because nothing was taken, the second because the run's own failure is the thing to read and a second warning beside it is noise.
        public var qualification: String? {
            switch state {
            case .restored, .alreadyOn, .neverSwitchedOff, .unreached:
                nil
            case .failed:
                "device accessibility left off"
            case .unconfirmed:
                "device accessibility not confirmed on"
            case .undetermined:
                "device accessibility not restored"
            }
        }

        /// How bad this is beside another device's restoration, for the one qualification a headline has room for.
        ///
        /// Ordered by how sure the reading is that a device will fail the next suite: a device known off first, then one this could not confirm, then one it could not even name, then the two that are nobody's problem. `unreached` sorts above the settled states and below every qualified one, so the run whose devices are all fit or all out of reach carries no qualification at all.
        var severity: Int {
            switch state {
            case .restored, .alreadyOn, .neverSwitchedOff:
                0
            case .unreached:
                1
            case .undetermined:
                2
            case .unconfirmed:
                3
            case .failed:
                4
            }
        }
    }
}

public extension SimulatorAccessibility.Restoration {
    /// The seven things a restore can have found.
    enum State: Equatable, Sendable {
        /// The preference was seen off, switched back on, and still read on a few seconds later.
        case restored
        /// It read on, and still read on at the end of the poll, so nothing was written.
        ///
        /// Nothing is said about it unless the run's failures read empty trees, and then only that: a teardown landing after the poll is a thing this did not see, so the device is not claimed fit.
        case alreadyOn
        /// The domain or the key is not on the device at all, so no session has ever switched the preference off there and nothing was owed.
        ///
        /// The run that died before its first session started is the common way here, and it prints nothing.
        case neverSwitchedOff
        /// The device could not be reached to be read — it is not booted, or `simctl` knows no such device; the payload says which.
        ///
        /// Nothing is claimed about the preference, and nothing qualifies the verdict: the run's own failure is the thing to read.
        case unreached(reason: String)
        /// Known off: the deciding key last read off and could not be switched back on — a write that kept being switched off, or a write of the deciding key that failed after it was read off; the payload says which.
        case failed(reason: String)
        /// Not known either way: the key could not be read, or a write failed where it had not been seen off; the payload says which.
        case unconfirmed(reason: String)
        /// The run executed tests on a simulator argv and the listing between them could not name, so no device was read or written.
        case undetermined(reason: String)
    }
}
