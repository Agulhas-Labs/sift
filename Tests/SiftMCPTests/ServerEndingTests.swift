//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the one claim that gates both a server's stop line and its exit.
///
/// **The hazard is not hypothetical and not a narrow window.** Two dispatch sources are armed on one concurrent queue — the signal watch and the parent watch — and closing a terminal reaches both by construction: it delivers `SIGHUP` to the foreground group and kills the parent shell in the same event. A claim covering only the record would let both handlers call `exit` in parallel, which Darwin can wedge in static destruction, and the process's status and recorded reason would be whichever thread won.
struct ServerEndingTests {
    /// Two endings for one server produce one stop line and one exit.
    ///
    /// The mutation this catches: move the exit outside the claim and this sees two.
    @Test
    func onlyTheFirstEndingRecordsAndOnlyTheFirstExits() {
        let ledger = Ledger()
        let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })

        ending.end(.signalled(number: SIGHUP), status: 128 + SIGHUP)
        ending.end(.parentExited(pid: 4242), status: 0)

        #expect(ledger.stops == [.signalled(number: SIGHUP)])
        #expect(ledger.statuses == [128 + SIGHUP])
    }

    /// The ordinary return path takes the same claim, and takes it without exiting.
    ///
    /// A client hanging up as a signal lands must leave one stop and one exit between the two of them — not a record from one and an exit from the other, which would put a status on the process that no log line accounts for.
    @Test
    func aRecordedStopLeavesNothingForALaterEndingToDo() {
        let ledger = Ledger()
        let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })

        ending.record(.inputClosed)
        ending.end(.signalled(number: SIGTERM), status: 128 + SIGTERM)

        #expect(ledger.stops == [.inputClosed])
        #expect(ledger.statuses.isEmpty)
    }

    /// Entered from many threads at once, it still ends once.
    ///
    /// The sequential tests above pin the guard; this one pins that it is a guard against *concurrency* rather than against being called twice in a row, which is the shape the real failure takes.
    @Test
    func manyThreadsEndingAtOnceStillEndItOnce() {
        let ledger = Ledger()
        let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "server-ending-race", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0 ..< 32 {
            queue.async(group: group) {
                ready.signal()
                start.wait()
                ending.end(.parentExited(pid: Int32(index)), status: Int32(index))
            }
        }
        for _ in 0 ..< 32 {
            ready.wait()
        }
        for _ in 0 ..< 32 {
            start.signal()
        }
        group.wait()

        #expect(ledger.stops.count == 1)
        #expect(ledger.statuses.count == 1)
    }

    /// An ending that arrives while the image is being replaced writes nothing then, and is carried out in full if the exec fails.
    ///
    /// Both halves matter. A stop written while an exec that goes on to succeed is under way would close a start whose process then carries on serving — gone from `sift status` while it runs. And one dropped because it arrived at the wrong moment would leave a `pkill` unanswered.
    @Test
    func anEndingDuringAReplacementWaitsForItsOutcome() {
        let ledger = Ledger()
        let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })

        #expect(ending.beginReplacing())
        ending.end(.signalled(number: SIGTERM), status: 128 + SIGTERM)

        #expect(ledger.stops.isEmpty, "a stop was written while the process was still replacing itself")
        #expect(ledger.statuses.isEmpty)

        ending.abandonReplacing()

        #expect(ledger.stops == [.signalled(number: SIGTERM)])
        #expect(ledger.statuses == [128 + SIGTERM])
    }

    /// Of several endings that arrive during one replacement, the first is the one kept — the same rule as everywhere else here.
    @Test
    func theFirstEndingDuringAReplacementIsTheOneKept() {
        let ledger = Ledger()
        let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })

        #expect(ending.beginReplacing())
        ending.end(.parentExited(pid: 4242), status: 0)
        ending.end(.signalled(number: SIGHUP), status: 128 + SIGHUP)
        ending.abandonReplacing()

        #expect(ledger.stops == [.parentExited(pid: 4242)])
        #expect(ledger.statuses == [0])
    }

    /// A process already ending is not replaced: the exec would carry on a server that has written its stop.
    @Test
    func nothingIsReplacedOnceTheServerIsEnding() {
        let ledger = Ledger()
        let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })

        ending.record(.inputClosed)

        #expect(!ending.beginReplacing())
    }

    /// A replacement called off with nothing held leaves the server serving, and a later ending is written as it always was.
    @Test
    func anAbandonedReplacementLeavesTheServerServing() {
        let ledger = Ledger()
        let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })

        #expect(ending.beginReplacing())
        ending.abandonReplacing()
        #expect(ledger.stops.isEmpty)

        ending.record(.inputClosed)

        #expect(ledger.stops == [.inputClosed])
        #expect(!ending.beginReplacing())
    }
}

extension ServerEndingTests {
    /// Stands in for the log and for `exit`, so an ending can be entered twice without ending the test runner.
    final class Ledger: @unchecked Sendable {
        private let mutex = NSLock()
        private var recorded: [ServerStop] = []
        private var left: [Int32] = []

        var stops: [ServerStop] {
            mutex.lock()
            defer { mutex.unlock() }
            return recorded
        }

        var statuses: [Int32] {
            mutex.lock()
            defer { mutex.unlock() }
            return left
        }

        func record(_ stop: ServerStop) {
            mutex.lock()
            defer { mutex.unlock() }
            recorded.append(stop)
        }

        func leave(_ status: Int32) {
            mutex.lock()
            defer { mutex.unlock() }
            left.append(status)
        }
    }
}
