//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers re-arming the simulator accessibility preference after a wrapped test run: which invocations earn it, which device it acts on, what the state machine does, and what the answer says about it.
///
/// Every case drives a scripted runner and a scripted clock, so nothing here spawns `simctl`, waits on wall clock, or touches a device — which is also what makes the budgets assertable rather than merely believed.
struct SimulatorAccessibilityTests {
    // MARK: - Which invocations, and which device

    /// The destination is read only for the two actions that execute a test bundle, and only where it names a simulator.
    @Test(arguments: [
        (["xcodebuild", "-scheme", "Gizmo", "-destination", "id=\(SimulatorAccessibilityTests.udid)", "test"], SimulatorDestination.identified(udid: SimulatorAccessibilityTests.udid)),
        (["xcodebuild", "-xctestrun", "Gizmo.xctestrun", "-destination", "id=\(SimulatorAccessibilityTests.udid)", "test-without-building"], SimulatorDestination.identified(udid: SimulatorAccessibilityTests.udid)),
        (["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS Simulator,name=iPhone 17", "test"], SimulatorDestination.named(name: "iPhone 17", osVersion: nil)),
        (["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS Simulator,name=iPhone 17,OS=26.0", "test"], SimulatorDestination.named(name: "iPhone 17", osVersion: "26.0")),
        // `OS=latest` narrows nothing, which is what it means.
        (["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=tvOS Simulator,name=iPhone 17,OS=latest", "test"], SimulatorDestination.named(name: "iPhone 17", osVersion: nil)),
        (["xcodebuild", "-scheme", "Gizmo", "-destination", "generic/platform=iOS Simulator", "test"], SimulatorDestination.unnamed),
        // A bare `id=` is a simulator's only where the identifier is shaped like one — a udid is a UUID either
        // case, since `simctl` prints them upper-cased and argv is written by hand as often as it is copied.
        (["xcodebuild", "-scheme", "Gizmo", "-destination", "id=\(SimulatorAccessibilityTests.udid.lowercased())", "test"], SimulatorDestination.identified(udid: SimulatorAccessibilityTests.udid.lowercased())),
        // A platform that names a simulator has already decided it, so the identifier beside it is taken as written.
        (["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS Simulator,id=\(SimulatorAccessibilityTests.physical)", "test"], SimulatorDestination.identified(udid: SimulatorAccessibilityTests.physical)),
    ])
    func argvNamesTheSimulatorTheTestsRanOn(arguments: [String], expected: SimulatorDestination) {
        #expect(SimulatorDestination.simulatorsOfTestRun(arguments) == [expected])
    }

    /// Everything that leaves no simulator torn down, including the two shapes a misreading would turn into one.
    @Test(arguments: [
        // A device no `simctl` write can reach — by platform, and by platform beside an identifier.
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=macOS", "test"],
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=macOS,arch=arm64", "test"],
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS,name=Gizmo's Phone", "test"],
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS,id=\(SimulatorAccessibilityTests.udid)", "test"],
        // An action that executes no test bundle, and none at all.
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS Simulator,name=iPhone 17", "build"],
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS Simulator,name=iPhone 17", "build-for-testing"],
        // `test` standing as an option's value is not an action, so this invocation's action goes unread.
        ["xcodebuild", "-scheme", "test", "-destination", "platform=iOS Simulator,name=iPhone 17"],
        // A test run with no destination at all, and a tool this reader does not wrap.
        ["xcodebuild", "-scheme", "Gizmo", "test"],
        ["swift", "test", "--filter", "GizmoTests"],
        // `id=` on its own is the canonical spelling for a physical device too, and every physical udid is a
        // shape no CoreSimulator udid has: `8-16` hex on current hardware, 40 hex on older.
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "id=\(SimulatorAccessibilityTests.physical)", "test"],
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "id=\(SimulatorAccessibilityTests.olderPhysical)", "test"],
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "id=Gizmos-iPhone", "test"],
    ])
    func nothingIsReArmedWhereNoSimulatorRanTheTests(arguments: [String]) {
        #expect(SimulatorDestination.simulatorsOfTestRun(arguments).isEmpty)
    }

    /// A test run with no `-destination` at all still re-arms the device Xcode resolved for itself — read from the one place that says so, the `PLATFORM_NAME` a verbose build echoes for the destination it picked.
    @Test
    func aRunWithNoDestinationIsReadFromWhatTheLogSaysItBuiltFor() {
        let noDestination = ["xcodebuild", "-scheme", "Gizmo", "test"]
        #expect(SimulatorDestination.simulatorsOfTestRun(noDestination, log: Self.simulatorPlatformLog) == [.unnamed])
        #expect(SimulatorDestination.simulatorsOfTestRun(noDestination, log: Self.macOSPlatformLog).isEmpty)
        #expect(SimulatorDestination.simulatorsOfTestRun(noDestination, log: nil).isEmpty)
        // A build action names no simulator itself, whatever the log says the destination resolved to.
        let build = ["xcodebuild", "-scheme", "Gizmo", "build"]
        #expect(SimulatorDestination.simulatorsOfTestRun(build, log: Self.simulatorPlatformLog).isEmpty)
        // A `-destination` on the command line answers the question outright, without reading the log at all.
        #expect(SimulatorDestination.simulatorsOfTestRun(Self.testRun, log: Self.macOSPlatformLog) == [.identified(udid: Self.udid)])
    }

    /// A booted device of that name is the one the run used; a name several available devices carry is not settled at all.
    @Test
    func theListingSettlesTheDeviceOrNothingIsWritten() {
        let listing = Data(Self.listing.utf8)

        // Booted wins over the shutdown device of the same name on another runtime.
        #expect(SimulatorDestination.device(named: "iPhone 17 Pro", osVersion: nil, inListing: listing) == Self.booted)
        // One available match and no booted one.
        #expect(SimulatorDestination.device(named: "iPhone 17 Mini", osVersion: nil, inListing: listing) == Self.only)
        // Two available devices of one name, neither booted: several is not an answer.
        #expect(SimulatorDestination.device(named: "iPhone 17", osVersion: nil, inListing: listing) == nil)
        // The same name, narrowed by the runtime — and a version written short accepts the longer spelling.
        #expect(SimulatorDestination.device(named: "iPhone 17", osVersion: "26.0", inListing: listing) == Self.current)
        #expect(SimulatorDestination.device(named: "iPhone 17", osVersion: "26", inListing: listing) == Self.current)
        #expect(SimulatorDestination.device(named: "iPhone 17", osVersion: "18.5", inListing: listing) == Self.older)
        // A name nothing carries, and a runtime nothing sits on.
        #expect(SimulatorDestination.device(named: "iPhone 17", osVersion: "12.0", inListing: listing) == nil)
        #expect(SimulatorDestination.device(named: "Gizmo Phone", osVersion: nil, inListing: listing) == nil)
    }

    /// A name the listing does not settle writes nothing and says so, with the command to run by hand.
    @Test
    func aDeviceTheListingDoesNotSettleIsReportedRatherThanGuessedAt() throws {
        let simulator = Self.simulator(listing: Self.listing)

        let restoration = try #require(Self.restore(["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS Simulator,name=iPhone 17", "test"], on: simulator))

        #expect(restoration.state == .undetermined(reason: "no single available simulator is named iPhone 17"))
        #expect(restoration.qualification == "device accessibility not restored")
        #expect(restoration.note(failuresReadEmptyTrees: false)?.contains("no device determined") == true)
        #expect(restoration.note(failuresReadEmptyTrees: false)?.contains("xcrun simctl spawn <udid> defaults write com.apple.Accessibility AccessibilityEnabled -bool true") == true)
        // Nothing was read and nothing was written: the listing was the only thing asked for.
        #expect(simulator.calls.count == 1)
        #expect(simulator.calls[0] == SimulatorDestination.listArguments)
    }

    /// A destination naming the device outright asks for no listing.
    @Test
    func anIdentifiedDestinationNeedsNoListing() throws {
        let simulator = Self.simulator(readings: ["0", "1"])

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .restored)
        #expect(restoration.udid == Self.udid)
        #expect(!simulator.calls.contains(SimulatorDestination.listArguments))
    }

    // MARK: - The state machine

    /// The teardown's `0`, both keys written back, and a read a moment later that finds them held.
    @Test
    func aPreferenceSeenOffIsWrittenBackOnAndConfirmed() throws {
        let simulator = Self.simulator(readings: ["0", "1"])

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .restored)
        #expect(restoration.qualification == nil)
        #expect(restoration.note(failuresReadEmptyTrees: false) == "accessibility: read off on \(Self.udid) after the run; sift switched it back on")
        #expect(simulator.writes == [
            ["simctl", "spawn", Self.udid, "defaults", "write", "com.apple.Accessibility", "AccessibilityEnabled", "-bool", "true"],
            ["simctl", "spawn", Self.udid, "defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled", "-bool", "true"],
        ])
    }

    /// **`defaults`, never `/usr/bin/defaults`.** `simctl spawn` resolves a bare name inside the runtime and an absolute path on the host, so the absolute spelling writes nowhere the simulator reads — and reports success while doing it.
    @Test
    func everyVectorSpellsTheRuntimesOwnDefaultsRelatively() {
        let simulator = Self.simulator(readings: ["0", "1"])

        _ = Self.restore(Self.testRun, on: simulator)

        #expect(!simulator.calls.isEmpty)
        for vector in simulator.calls where vector.count > 3 {
            #expect(vector[3] == "defaults")
            #expect(!vector.contains("/usr/bin/defaults"))
        }
        #expect(simulator.executables.allSatisfy { $0 == "/usr/bin/xcrun" })
    }

    /// A preference already on is left alone — no write, no confirmation delay, and the poll bounded by the clock rather than by a count of spawns.
    @Test
    func aPreferenceAlreadyOnIsNeverWritten() throws {
        let simulator = Self.simulator(readings: ["1"])

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .alreadyOn)
        #expect(restoration.qualification == nil)
        // The reading of nearly every simulator run, green ones included, is said nothing about.
        #expect(restoration.note(failuresReadEmptyTrees: false) == nil)
        // Two seconds of reading on is all this saw, so where the failures read empty trees the note claims no more than that and hands over the command a later teardown would call for.
        let note = try #require(restoration.note(failuresReadEmptyTrees: true))
        #expect(note.contains("read on for \(Self.udid) after the run, yet the failures read empty trees"))
        #expect(!note.contains("fit for"))
        #expect(note.hasSuffix("re-arm: \(SimulatorAccessibility.command(udid: Self.udid))"))
        #expect(simulator.writes.isEmpty)
        // The whole cost of an ordinary simulator package run: a poll bounded at two seconds, and no 2.5s
        // confirmation delay behind a write that never happened.
        #expect(simulator.elapsed <= 2)
        #expect(simulator.calls.count > 1)
    }

    /// A write a late teardown undoes is written again, for as long as the budget lasts.
    @Test
    func aWriteSwitchedBackOffIsWrittenAgain() throws {
        let simulator = Self.simulator(readings: ["0", "0", "1"])

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .restored)
        #expect(simulator.writes.count == 4)
    }

    /// A key that keeps being switched off is a device left off, said as that and not as a restore.
    @Test
    func aPreferenceThatKeepsBeingSwitchedOffIsReportedLeftOff() throws {
        let simulator = Self.simulator(readings: ["0"])

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .failed(reason: "com.apple.Accessibility AccessibilityEnabled was switched back off after 4 writes"))
        #expect(restoration.qualification == "device accessibility left off")
        let note = try #require(restoration.note(failuresReadEmptyTrees: false))
        #expect(note.hasPrefix("accessibility: left off on \(Self.udid) ("))
        #expect(note.hasSuffix("re-arm: \(SimulatorAccessibility.command(udid: Self.udid))"))
        #expect(simulator.elapsed <= 10)
    }

    /// A key that cannot be read is not a key known to be off: the answer says unknown, and names the command.
    @Test
    func aPreferenceThatCannotBeReadIsUnconfirmed() throws {
        let simulator = Self.simulator(readings: [nil])

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .unconfirmed(reason: "com.apple.Accessibility AccessibilityEnabled could not be read"))
        #expect(restoration.qualification == "device accessibility not confirmed on")
        #expect(restoration.note(failuresReadEmptyTrees: false)?.contains("not confirmed on for \(Self.udid)") == true)
        #expect(simulator.writes.isEmpty)
    }

    /// A write of the deciding key that fails where the key was seen off is a device known to be off; one that fails on the key behind it is not, because the deciding key was written and never read back.
    @Test
    func aFailedWriteIsKnownOffOnlyForTheDecidingKey() {
        let known = Self.simulator(readings: ["0"], writeSucceeds: { _ in false })
        let unknown = Self.simulator(readings: ["0"], writeSucceeds: { $0 == "AccessibilityEnabled" })

        #expect(Self.restore(Self.testRun, on: known)?.state == .failed(reason: "writing com.apple.Accessibility AccessibilityEnabled did not succeed"))
        #expect(Self.restore(Self.testRun, on: unknown)?.state == .unconfirmed(reason: "writing com.apple.Accessibility ApplicationAccessibilityEnabled did not succeed"))
    }

    // MARK: - What the answer says

    /// The note goes under the receipt, and the receipt counts it: a line of the answer the answer's own size does not count is a receipt that understates itself.
    @Test
    func theNoteSitsUnderTheReceiptAndIsCountedByIt() throws {
        let answer = Self.answer(for: [SimulatorAccessibility.Restoration(udid: Self.udid, state: .restored)])
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false)

        let note = try #require(lines.last)

        #expect(note == "accessibility: read off on \(Self.udid) after the run; sift switched it back on")
        #expect(lines[lines.count - 2].hasPrefix("raw: "))
        #expect(lines[lines.count - 2].contains("lines in, \(lines.count) out"))
    }

    /// A device whose preference read on says nothing, on a green run and on a red one whose failures are not an empty tree's — the line every simulator run used to print, and every reader learned to filter out.
    @Test
    func aDeviceThatReadOnSaysNothingWhereTheFailuresAreNotAnEmptyTrees() {
        let readOn = [SimulatorAccessibility.Restoration(udid: Self.udid, state: .alreadyOn)]
        var green = RunOutputFilter(invokedAs: Self.testRun)
        green.consume(line: "** TEST SUCCEEDED **")

        let passed = Self.renderer(for: readOn).render(green.finish(exitCode: 0), exitCode: 0, logURL: nil)

        #expect(passed.hasPrefix("✔ xcodebuild"))
        #expect(!passed.contains("accessibility"))
        #expect(!Self.answer(for: readOn).contains("accessibility"))
    }

    /// A preference read off is one short line, and a device this run re-armed is never handed the command it no longer needs.
    @Test
    func aPreferenceReadOffIsOneShortLine() throws {
        let answer = Self.answer(for: [SimulatorAccessibility.Restoration(udid: Self.udid, state: .restored)])

        let note = try #require(answer.split(separator: "\n").last)

        #expect(note.hasPrefix("accessibility: read off on \(Self.udid)"))
        #expect(note.count < 120)
        #expect(!note.contains("simctl"))
    }

    /// A build that executes no test tears no session down, so it reads no device, spawns nothing and prints nothing about one.
    @Test(arguments: ["build-for-testing", "build"])
    func aBuildThatRunsNoTestsSaysNothingAboutADevice(action: String) {
        let simulator = Self.simulator(readings: ["0", "1"])

        let restorations = Self.restoreAll(["xcodebuild", "-scheme", "Gizmo", "-destination", "id=\(Self.udid)", action], on: simulator)

        #expect(restorations.isEmpty)
        #expect(simulator.calls.isEmpty)
        #expect(!Self.answer(for: restorations).contains("accessibility"))
    }

    /// A device left off or unconfirmed qualifies the one line a reader takes in first; a device known on leaves it as the log earned it.
    @Test
    func aDeviceLeftOffQualifiesTheHeadline() {
        let left = SimulatorAccessibility.Restoration(udid: Self.udid, state: .failed(reason: "no"))
        let confirmed = SimulatorAccessibility.Restoration(udid: Self.udid, state: .restored)

        #expect(Self.answer(for: [left]).hasPrefix("✘ xcodebuild — exit 65 — device accessibility left off"))
        #expect(Self.answer(for: [confirmed]).hasPrefix("✘ xcodebuild — exit 65\n"))
    }

    /// A run that put no test on a simulator says nothing about a device at all.
    @Test
    func aRunOnNoSimulatorPrintsNoAccessibilityLine() {
        #expect(!Self.answer(for: []).contains("accessibility:"))
    }

    /// A domain no session has ever written is not a device this run made worse: nothing is printed, and nothing qualifies the headline.
    ///
    /// **This is the commonest failing run there is.** `com.apple.Accessibility` comes into existence on a device when a session's teardown writes it, so a run that died before a session started — a scheme error, a compile error, a destination that never resolved — reads the key as missing. Answering that with `⚠ … — device accessibility not confirmed on` put a warning about a device on the headline of a failure that has nothing to do with one.
    @Test(arguments: [
        // The wordings `defaults` fails with, probed on 17 Sep 2026, and the older spelling of the same pair.
        "Error: Domain 'com.apple.Accessibility' not found.\n",
        "Error: Could not find key 'AccessibilityEnabled' in domain 'com.apple.Accessibility'.\n",
        "The domain/default pair of (com.apple.Accessibility, AccessibilityEnabled) does not exist\n",
    ])
    func aDomainNoSessionHasEverWrittenSaysNothingAtAll(standardError: String) throws {
        let simulator = Self.simulator(readings: [nil], standardError: standardError)

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .neverSwitchedOff)
        #expect(restoration.note(failuresReadEmptyTrees: false) == nil)
        #expect(restoration.note(failuresReadEmptyTrees: true) == nil)
        #expect(restoration.qualification == nil)
        #expect(simulator.writes.isEmpty)
        #expect(!Self.answer(for: [restoration]).contains("accessibility:"))
    }

    /// A device no spawn can reach is one note and no qualification — and no two seconds of polling a device that will not answer the tenth read any better than the first.
    @Test(arguments: [
        ("An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nProcess spawn via launchd failed because device is not booted.\n", "the simulator is shut down"),
        ("Unable to lookup in current state: Shutdown\n", "the simulator is shut down"),
        ("Invalid device: 11111111-2222-3333-4444-555555555555\n", "simctl knows no device with that identifier"),
    ])
    func aDeviceNothingCanReachIsSaidOnceAndQualifiesNothing(standardError: String, reason: String) throws {
        let simulator = Self.simulator(readings: [nil], standardError: standardError)

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .unreached(reason: reason))
        #expect(restoration.qualification == nil)
        #expect(restoration.note(failuresReadEmptyTrees: false)?.contains("not checked on \(Self.udid) (\(reason))") == true)
        #expect(Self.answer(for: [restoration]).hasPrefix("✘ xcodebuild — exit 65\n"))
        // One read, and no poll: a device out of reach is out of reach for the whole budget.
        #expect(simulator.calls.count == 1)
        #expect(simulator.elapsed == 0)
    }

    /// A read that failed some other way is the unknown it always was, and now says what the tool said about it.
    @Test
    func anUnrecognisedFailureKeepsItsWarningAndCarriesTheReason() throws {
        let simulator = Self.simulator(readings: [nil], standardError: "defaults[913:9]: could not talk to cfprefsd\n")

        let restoration = try #require(Self.restore(Self.testRun, on: simulator))

        #expect(restoration.state == .unconfirmed(reason: "com.apple.Accessibility AccessibilityEnabled could not be read (defaults[913:9]: could not talk to cfprefsd)"))
        #expect(restoration.qualification == "device accessibility not confirmed on")
    }

    /// Every simulator argv names is restored, in the order it named them, and the headline carries the worst of what they came to.
    ///
    /// One destination restored out of two would leave the other device off while the answer read as a clean run — and the device that breaks the next suite would be the one nobody was told about.
    @Test
    func everySimulatorOnTheCommandLineIsRestoredInArgvOrder() {
        let second = "22222222-3333-4444-5555-666666666666"
        let arguments = ["xcodebuild", "-scheme", "Gizmo", "-destination", "id=\(Self.udid)", "-destination", "id=\(second)", "test"]
        let simulator = Self.simulator(readings: [nil], standardError: "Unable to lookup in current state: Shutdown\n")

        let restorations = Self.restoreAll(arguments, on: simulator)

        #expect(restorations.map(\.udid) == [Self.udid, second])
        let notes = Self.answer(for: restorations).split(separator: "\n").suffix(2)
        #expect(notes.first?.contains("not checked on \(Self.udid)") == true)
        #expect(notes.last?.contains("not checked on \(second)") == true)
    }

    /// The worst of the devices is what the one headline says, and a device nothing is claimed about never takes that line from one that is known off.
    @Test
    func theHeadlineCarriesTheWorstDeviceOfTheRun() {
        let off = SimulatorAccessibility.Restoration(udid: Self.udid, state: .failed(reason: "no"))
        let unreached = SimulatorAccessibility.Restoration(udid: Self.udid, state: .unreached(reason: "the simulator is shut down"))
        let silent = SimulatorAccessibility.Restoration(udid: Self.udid, state: .neverSwitchedOff)

        #expect(SimulatorAccessibility.qualification(of: [unreached, off]) == "device accessibility left off")
        #expect(SimulatorAccessibility.qualification(of: [off, unreached]) == "device accessibility left off")
        #expect(SimulatorAccessibility.qualification(of: [silent, unreached]) == nil)
        #expect(SimulatorAccessibility.qualification(of: []) == nil)
    }

    /// The note is charged to the allowance the two listings share, because it is as much a line of the answer as they are.
    ///
    /// The allowance is what keeps a filtered answer shorter than the log it stands in for; a line exempt from it is a line by which the answer may run over, and the receipt underneath would say so.
    @Test
    func theNoteIsChargedToTheAnswersOwnAllowance() {
        var filter = RunOutputFilter(invokedAs: Self.testRun)
        for line in 1 ... 39 {
            filter.consume(line: "line \(line)")
        }
        filter.consume(line: "** TEST FAILED **")
        let report = filter.finish(exitCode: 65)

        let bare = Self.renderer(for: []).allowance(of: report, beside: 3)
        let noted = Self.renderer(for: [SimulatorAccessibility.Restoration(udid: Self.udid, state: .restored)]).allowance(of: report, beside: 3)
        let silent = Self.renderer(for: [SimulatorAccessibility.Restoration(udid: Self.udid, state: .neverSwitchedOff)]).allowance(of: report, beside: 3)

        #expect(bare > 0)
        #expect(noted == bare - 1)
        #expect(silent == bare)
    }
}

// MARK: - The scripted device

private extension SimulatorAccessibilityTests {
    /// A `simctl` nobody spawns: it answers reads from a script, records every vector, and moves a clock only when something waits on it.
    final class ScriptedSimulator {
        private(set) var calls: [[String]] = []
        private(set) var executables: [String] = []
        private var readings: [String?]
        private let listing: String
        private let standardError: String
        private let writeSucceeds: (String) -> Bool
        private let started = Date(timeIntervalSince1970: 0)
        private var moment = Date(timeIntervalSince1970: 0)

        init(readings: [String?], listing: String, standardError: String, writeSucceeds: @escaping (String) -> Bool) {
            self.readings = readings
            self.listing = listing
            self.standardError = standardError
            self.writeSucceeds = writeSucceeds
        }

        /// Every vector that wrote a key, in order.
        var writes: [[String]] {
            calls.filter { $0.count > 4 && $0[4] == "write" }
        }

        /// How far the scripted clock moved — what the run would have cost in wall clock.
        var elapsed: TimeInterval {
            moment.timeIntervalSince(started)
        }

        func run(_ executable: String, _ arguments: [String]) throws -> SimulatorAccessibility.Output {
            executables.append(executable)
            calls.append(arguments)
            if arguments.first == "simctl", arguments.dropFirst().first == "list" {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: listing)
            }
            guard arguments.count > 4 else {
                return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: standardError)
            }
            if arguments[4] == "write" {
                return SimulatorAccessibility.Output(succeeded: writeSucceeds(arguments[6]), standardOutput: "")
            }
            // The last reading stands for every read after it, so a script says what changes and nothing else.
            let reading = readings.count > 1 ? readings.removeFirst() : readings.first.flatMap(\.self)
            guard let reading else {
                // A read that failed says why on standard error, which is the only thing that tells the three
                // failures apart — an empty one is a failure that said nothing, and stays the unknown it was.
                return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: standardError)
            }
            return SimulatorAccessibility.Output(succeeded: true, standardOutput: "\(reading)\n")
        }

        func pause(_ interval: TimeInterval) {
            moment = moment.addingTimeInterval(interval)
        }

        func now() -> Date {
            moment
        }
    }
}

private extension SimulatorAccessibilityTests {
    static var udid: String {
        "11111111-2222-3333-4444-555555555555"
    }

    /// A physical device's udid as `xcodebuild -destination` spells it — the shape no CoreSimulator device has.
    static var physical: String {
        "00008120-000A4D3A0A88401E"
    }

    /// The same, as hardware before the dashed spelling wrote it.
    static var olderPhysical: String {
        "0123456789abcdef0123456789abcdef01234567"
    }

    static var booted: String {
        "AAAAAAAA-0000-0000-0000-000000000001"
    }

    static var only: String {
        "AAAAAAAA-0000-0000-0000-000000000002"
    }

    static var current: String {
        "AAAAAAAA-0000-0000-0000-000000000003"
    }

    static var older: String {
        "AAAAAAAA-0000-0000-0000-000000000004"
    }

    /// A test run on the device named outright — the shape every state-machine case is driven through.
    static var testRun: [String] {
        ["xcodebuild", "-scheme", "Gizmo", "-destination", "id=\(udid)", "test"]
    }

    /// A verbose build settings line naming a simulator platform — the same `export PLATFORM_NAME\=…` spelling `xcodebuild-test-success.txt` carries for `macosx`, below, with the platform swapped for the one no fixture here was captured against a simulator to show.
    static var simulatorPlatformLog: String {
        "    export PLATFORM_NAME\\=iphonesimulator\n"
    }

    /// The line `Tests/SiftCoreTests/Fixtures/RunOutput/xcodebuild-test-success.txt` actually carries for its `My Mac` destination — real captured `xcodebuild` output, naming no simulator.
    static var macOSPlatformLog: String {
        "    export PLATFORM_NAME\\=macosx\n"
    }

    /// `simctl list devices available -j` as it answers, cut down to the fields this reads.
    static var listing: String {
        """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
              { "udid" : "\(booted)", "name" : "iPhone 17 Pro", "state" : "Booted" },
              { "udid" : "\(only)", "name" : "iPhone 17 Mini", "state" : "Shutdown" },
              { "udid" : "\(current)", "name" : "iPhone 17", "state" : "Shutdown" }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5" : [
              { "udid" : "BBBBBBBB-0000-0000-0000-000000000001", "name" : "iPhone 17 Pro", "state" : "Shutdown" },
              { "udid" : "\(older)", "name" : "iPhone 17", "state" : "Shutdown" }
            ]
          }
        }
        """
    }

    static func simulator(
        readings: [String?] = [],
        listing: String = "",
        standardError: String = "",
        writeSucceeds: @escaping (String) -> Bool = { _ in true }
    ) -> ScriptedSimulator {
        ScriptedSimulator(readings: readings, listing: listing, standardError: standardError, writeSucceeds: writeSucceeds)
    }

    /// What the one device of a single-destination run came to — every state-machine case is written through this.
    static func restore(_ arguments: [String], on simulator: ScriptedSimulator) -> SimulatorAccessibility.Restoration? {
        restoreAll(arguments, on: simulator).first
    }

    static func restoreAll(_ arguments: [String], on simulator: ScriptedSimulator) -> [SimulatorAccessibility.Restoration] {
        SimulatorAccessibility.restore(
            after: arguments,
            run: { try simulator.run($0, $1) },
            pause: { simulator.pause($0) },
            now: { simulator.now() }
        )
    }

    /// A failing `xcodebuild test` answer, rendered with whatever the restores found under it.
    static func answer(for accessibility: [SimulatorAccessibility.Restoration]) -> String {
        var filter = RunOutputFilter(invokedAs: testRun)
        filter.consume(line: "** TEST FAILED **")
        return renderer(for: accessibility).render(filter.finish(exitCode: 65), exitCode: 65, logURL: nil)
    }

    static func renderer(for accessibility: [SimulatorAccessibility.Restoration]) -> RunReportRenderer {
        RunReportRenderer(
            kind: .xcodebuild,
            workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"),
            accessibility: accessibility
        )
    }
}
