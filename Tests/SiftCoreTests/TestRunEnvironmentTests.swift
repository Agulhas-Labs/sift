//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// What the seams a live run reaches the world through are bounded by.
@Suite(.temporaryDirectories)
struct TestRunEnvironmentTests {
    /// A boot is given the boot's own three minutes and a listing the default five seconds — the one seam every `simctl` goes through does not flatten them into whichever it was written with.
    @Test
    func everySimctlIsBoundedByWhatTheOperationItNamesMayCost() throws {
        // The chosen deadline comes back as the spawn's own output, which is the whole of what this seam
        // decides and the only thing about it a caller can see.
        let simctl = TestRunEnvironment.liveSimctl { _, _, deadline in
            SimulatorAccessibility.Output(succeeded: true, standardOutput: "\(deadline)")
        }
        let operations = [
            ["simctl", "bootstatus", TestRunEnvironmentTests.udid, "-b"],
            ["simctl", "create", "sift-1", "iPhone"],
            ["simctl", "delete", TestRunEnvironmentTests.udid],
            ["simctl", "list", "devices", "--json"],
        ]
        let taken = try operations.map { try Double(simctl("/usr/bin/xcrun", $0).standardOutput) }

        #expect(taken == [
            ShardDevices.bootDeadline,
            ShardDevices.createDeadline,
            ShardDevices.deleteDeadline,
            SimulatorAccessibility.spawnDeadline,
        ])
    }

    /// A boot needs longer than the default a plain spawn gets, which is why the two cannot be one number.
    @Test
    func theBootsDeadlineIsLongerThanTheOneAPlainSpawnGets() {
        #expect(ShardDevices.bootDeadline > SimulatorAccessibility.spawnDeadline)
    }

    private static var udid: String {
        "00000000-0000-0000-0000-000000000000"
    }

    /// A crash report is the run's when its name is stamped inside the run and it is not one of the system's own daemons.
    @Test
    func onlyReportsATestRunCouldHaveCausedAreNamed() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let began = try #require(formatter.date(from: "2026-09-17-180000"))
        let runner = #"{"app_name":"DemoUITests-Runner","is_first_party":0}"#
        let daemon = #"{"app_name":"chronod","is_first_party":1}"#

        #expect(TestRunEnvironment.isTestCrashReport(named: "DemoUITests-Runner-2026-09-17-180209.ips", header: runner, since: began))
        #expect(!TestRunEnvironment.isTestCrashReport(named: "chronod-2026-09-17-180051.0002.ips", header: daemon, since: began))
        #expect(!TestRunEnvironment.isTestCrashReport(named: "DemoUITests-Runner-2026-09-16-210514.ips", header: runner, since: began))
        #expect(TestRunEnvironment.isTestCrashReport(named: "xctest-2026-09-17-180209.ips", header: daemon, since: began))
    }

    /// The header's `is_first_party` decides whatever the report is named, and only when it carries the field; whenever the header does not carry it — parsed but missing the field, unparseable, or absent — a known system process's name decides instead, as the second tier ``TestRunEnvironment/isTestCrashReport(named:header:since:)`` falls to.
    @Test
    func theHeadersFieldDecidesOnlyWhenItCarriesItAndTheNameDecidesWheneverItDoesNot() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let began = try #require(formatter.date(from: "2026-09-17-180000"))
        let systemHeader = #"{"app_name":"PosterBoard","is_first_party":1}"#

        #expect(!TestRunEnvironment.isTestCrashReport(named: "PosterBoard-2026-09-17-180209.ips", header: systemHeader, since: began))
        #expect(!TestRunEnvironment.isTestCrashReport(named: "PosterBoard-2026-09-17-180209.ips", header: #"{"app_name":"PosterBoard"}"#, since: began))
        #expect(!TestRunEnvironment.isTestCrashReport(named: "PosterBoard-2026-09-17-180209.ips", header: nil, since: began))
        #expect(!TestRunEnvironment.isTestCrashReport(named: "PosterBoard-2026-09-17-180209.ips", header: "not json", since: began))
    }

    /// The build's and the enumeration's `xcodebuild` are the run's own children, because a child started outside the set-aside is one the teardown cannot end: a signal taken while a build was running would leave `sift test` blocked on that build's pipe until the build finished, minutes after the caller asked it to stop.
    ///
    /// The one case here that starts a process, because that is the whole of what this seam decides — from outside, a launch through the children and a launch beside them are the same call.
    @Test
    func theLiveLaunchIsEndedByTheChildrenTheTeardownHolds() throws {
        let root = try TemporaryDirectory.make("test-run-environment")
        let children = SetAsideChildren()
        let ledger = root.appendingPathComponent("sessions")
        children.record(into: ledger)
        let launch = TestRunEnvironment.liveLaunch(workingDirectory: root, repositoryRoot: nil, children: children)
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? launch(["/bin/sh", "-c", "sleep 30"])
            returned.signal()
        }
        let session = try #require(Self.firstSession(in: ledger), "the launch recorded no session, so it never started its child under the children")
        children.endAll()

        // The child asked for thirty seconds: the launch comes back because its child was ended, not waited out.
        #expect(returned.wait(timeout: .now() + 10) == .success)
        #expect(SetAsideChildren.members(of: session).isEmpty)
    }

    /// The session the launcher recorded, waited for rather than assumed — the launch runs on a thread of its own, and its child is spawned a moment after that thread starts.
    private static func firstSession(in ledger: URL) -> SetAsideChildren.Session? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let session = SetAsideChildren.sessions(in: ledger).first {
                return session
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}
