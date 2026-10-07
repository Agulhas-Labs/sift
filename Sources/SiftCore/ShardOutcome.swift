//
// Copyright © Agulhas Labs
//

import Foundation

/// What one shard's run left behind, as the merge reads it.
///
/// **The exit code is carried beside the outcomes and never folded into them.** A shard's process can exit non-zero over a log whose every test passed — a crashed runner, a failed teardown, a diagnostics timeout — and a merge that read only the test lines would answer green over it. Both facts reach ``ShardMerge`` and the verdict is taken over the pair.
public struct ShardOutcome: Sendable {
    /// Every test this shard's log reported starting or finishing.
    public let outcomes: RunTestOutcomes

    /// What the shard's `xcodebuild` exited with.
    public let exitCode: Int32

    /// How long the shard took from launch to exit, which is the number summed test time cannot see.
    public let wallSeconds: Double

    /// Where this shard's log was written, as the answer states it — moved by the caller where the log is kept past pruning.
    public var logPath: String

    /// The failures the filter read out of that log, for the answer's classification block.
    ///
    /// Bare outcomes carry an ending and a duration and nothing else, so a failure's message and location — which is all ``RunFailureShape`` groups by — have to come from the filter that read the same log.
    public let failures: [RunTestFailure]

    /// Whether this shard was ended at its wall-clock bound instead of finishing.
    ///
    /// Set by the runner after the fact rather than passed in, because the shard itself cannot know: what it hands back is whatever its log held when the session was ended, which is indistinguishable from a short run that simply reported little. The merge owes the reader that sentence — the tests below the cut are missing by the ordinary rule, and a reader who is not told why reads them as crashes.
    public var timedOut = false

    /// The sentence a shard whose executable never started carries, or `nil` where one started.
    ///
    /// A shard that could not be launched has no log to explain itself with, so the error's own words are the only thing the answer can print.
    public var launchFailure: String?

    /// Whether the log carries Swift Testing's closing `Test run with …` line for every Swift Testing process it opened, which a run that was cut short never prints — see ``ShardRunner/closedEverySwiftTestingRun(_:)``.
    public var closedWithRunSummary = false

    /// What each suite held this shard's process for on the wall clock, keyed as ``PackageShardPlanner/suite(of:)`` names a suite — see ``SuiteSpans``.
    public var suiteSeconds: [String: Double] = [:]

    /// This shard's Swift Testing event stream, the record its Swift Testing tests are reconciled from, or `nil` where it has none — see ``ShardEventStream``.
    public var eventStream: ShardEventStream?

    /// Why a SwiftPM shard has no ``eventStream``, which the answer states where the console then shows Swift Testing ran; `nil` where it has one or was never asked for one.
    public var eventStreamAbsence: String?

    public init(
        outcomes: RunTestOutcomes,
        exitCode: Int32,
        wallSeconds: Double,
        logPath: String,
        failures: [RunTestFailure] = []
    ) {
        self.outcomes = outcomes
        self.exitCode = exitCode
        self.wallSeconds = wallSeconds
        self.logPath = logPath
        self.failures = failures
    }
}
