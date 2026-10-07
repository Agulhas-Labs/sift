//
// Copyright © Agulhas Labs
//

import Foundation

/// Where a running build or test command has got to, as far as its output has said so far: what ``RunLiveTally`` answers at any moment.
public struct RunLiveState: Sendable, Equatable {
    /// Whether the command is still building or has started running tests; it only ever moves forward.
    public internal(set) var phase: Phase = .building
    /// Whether a SwiftPM step counter has been printed while building, which shows a build ran even where no line named a step; never set once testing has started.
    public internal(set) var buildStarted = false
    /// The step the build last named (`MixedTests Modern.swift`, `Pallet`) while building, and the test that last started while testing; `nil` until a line names either.
    public internal(set) var current: String?
    /// The tests finished so far, each counted once by how it last ended.
    public internal(set) var tests = Tests()
    /// Distinct compiler errors printed so far; an XCTest assertion, printed in a diagnostic's shape, is not one.
    public internal(set) var errors = 0
    /// Distinct compiler warnings printed so far.
    public internal(set) var warnings = 0
    /// When the command started, which every duration is measured from.
    public let startedAt: Date
    /// When the first line showing a test running arrived, or `nil` while none has.
    public internal(set) var testingStartedAt: Date?

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}

public extension RunLiveState {
    /// The two things a run can be doing.
    enum Phase: String, Sendable {
        case building
        case testing
    }

    /// How many tests have finished, by how each ended.
    struct Tests: Sendable, Equatable {
        public internal(set) var passed = 0
        public internal(set) var failed = 0
        public internal(set) var skipped = 0

        public init(passed: Int = 0, failed: Int = 0, skipped: Int = 0) {
            self.passed = passed
            self.failed = failed
            self.skipped = skipped
        }

        /// Every test counted, whatever its ending.
        public var finished: Int {
            passed + failed + skipped
        }
    }

    /// How a run's time splits between building and testing, in whole milliseconds.
    struct Durations: Sendable, Equatable {
        /// Time from the start to the first test line, or all of it where no test line arrived.
        public let buildMs: Int
        /// Time from the first test line on, or `nil` where none arrived: a `swift build` or a `build-for-testing` spent all its time building.
        public let testMs: Int?
    }

    /// When the current phase began: the run's start while building, the first test line once testing, so a live view can show the phase's own elapsed time.
    var phaseStartedAt: Date {
        testingStartedAt ?? startedAt
    }

    /// The split of the time from ``startedAt`` to `now`: the two parts are cut from one whole-millisecond total, so they always add up to it.
    func durations(until now: Date) -> Durations {
        let total = Self.milliseconds(from: startedAt, to: now)
        guard let testingStartedAt else {
            return Durations(buildMs: total, testMs: nil)
        }
        let build = min(total, Self.milliseconds(from: startedAt, to: testingStartedAt))
        return Durations(buildMs: build, testMs: total - build)
    }

    /// Whole milliseconds from `start` to `end`, rounded, and never negative: a clock read out of order is no reason to report time running backwards.
    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
