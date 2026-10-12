//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the jobs a transcript sweep runs at once: they really overlap, and their results come back in the jobs' own order.
struct ConcurrentScansTests {
    /// Two jobs with two workers run at the same time: each one waits to see the other start, which one after the other would never happen.
    @Test
    func twoJobsRunAtOnce() {
        let arrived = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

        let sawTheOther = ConcurrentScans<Bool>.results(count: 2, workers: 2) { index in
            arrived[index].signal()
            // A bound so a run that never overlaps fails rather than hangs; the other job starts in well under it.
            return arrived[1 - index].wait(timeout: .now() + 5) == .success
        }

        #expect(sawTheOther == [true, true], "the two jobs never ran at the same time: no second thread picked up the other job within 5 seconds")
    }

    /// A sweep whose worker threads still hold the finishing callback for a moment after their last job returns cleanly, however many times it runs.
    @Test
    func aFinishingCallbackTheWorkersStillHoldNeverTraps() {
        var total = 0
        for _ in 0 ..< 400 {
            _ = ConcurrentScans<Int>.results(count: 8, workers: 8) { $0 } finished: { _ in
                total += 1
            }
        }

        #expect(total == 400 * 8)
    }

    /// Results are handed back in index order whatever order the jobs were started and finished in, and each job is reported finished exactly once.
    @Test
    func resultsComeBackInIndexOrder() {
        var finished: [Int] = []

        let results = ConcurrentScans<Int>.results(count: 50, workers: 4, order: Array((0 ..< 50).reversed())) {
            $0 * 2
        } finished: {
            finished.append($0)
        }

        #expect(results == (0 ..< 50).map { $0 * 2 })
        #expect(finished.sorted() == Array(0 ..< 50))
    }
}
