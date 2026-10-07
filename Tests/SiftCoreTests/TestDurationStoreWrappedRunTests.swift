//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers what an ordinary wrapped run can honestly seed the durations store with, before any shard has run.
struct TestDurationStoreWrappedRunTests {
    /// A target-qualified XCTest name is the one shape this store's key already understands; the recording keys it exactly the way the shard planner would have.
    @Test
    func aTargetQualifiedXCTestNameIsKeyedTargetSlashTypeSlashFunction() throws {
        var outcomes = RunTestOutcomes()
        outcomes.read("Test Case '-[DemoUITests.ItemListUITests testSelectsFirstItem]' started.")
        outcomes.read("Test Case '-[DemoUITests.ItemListUITests testSelectsFirstItem]' passed (1.5 seconds).")

        let recording = try #require(TestDurationStore.Recording(wrappedRun: outcomes, exitCode: 0))

        #expect(recording.observations == [
            TestDurationStore.Timing(identifier: "DemoUITests/ItemListUITests/testSelectsFirstItem()", seconds: 1.5),
        ])
    }

    /// An unqualified XCTest name carries no target to key by, and a Swift Testing name carries neither a target nor a suite — both are skipped rather than guessed at.
    @Test
    func anUnqualifiedXCTestNameAndASwiftTestingNameAreBothSkipped() {
        var outcomes = RunTestOutcomes()
        outcomes.read("Test Case '-[ItemListUITests testSelectsFirstItem]' started.")
        outcomes.read("Test Case '-[ItemListUITests testSelectsFirstItem]' passed (1.5 seconds).")
        outcomes.read("Test doublingIsEven() started.")
        outcomes.read("Test doublingIsEven() passed after 0.002 seconds.")

        let recording = TestDurationStore.Recording(wrappedRun: outcomes, exitCode: 0)

        #expect(recording?.observations.isEmpty == true)
    }

    /// A nonzero exit is a run with nothing honest to measure: whatever timings it printed are timings of a run that failed or crashed, not of the tests.
    @Test
    func aNonZeroExitCodeRecordsNothing() {
        var outcomes = RunTestOutcomes()
        outcomes.read("Test Case '-[DemoUITests.ItemListUITests testSelectsFirstItem]' started.")
        outcomes.read("Test Case '-[DemoUITests.ItemListUITests testSelectsFirstItem]' passed (1.5 seconds).")

        #expect(TestDurationStore.Recording(wrappedRun: outcomes, exitCode: 1) == nil)
    }

    /// A retried run is read for what it is, so the store's own guard is the thing that later refuses to keep it.
    @Test
    func aRetriedRunYieldsRetriedTrue() throws {
        var outcomes = RunTestOutcomes()
        for line in try TestSources.runOutput("xcodebuild-retry-iterations").components(separatedBy: "\n") {
            outcomes.read(line)
        }

        let recording = try #require(TestDurationStore.Recording(wrappedRun: outcomes, exitCode: 0))

        #expect(recording.retried)
    }
}
