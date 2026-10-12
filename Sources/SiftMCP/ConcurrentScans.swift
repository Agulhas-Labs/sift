//
// Copyright © Agulhas Labs
//

import Foundation

/// Independent jobs run on several threads at once, their results handed back in the jobs' own order.
///
/// A transcript sweep is one scan per transcript, each reading only its own file and the memos every scan shares, and a fortnight of them is minutes of one core's work. Run here, the same scans finish in a fraction of that, and the sweep reads them back in the order it would have made them.
final class ConcurrentScans<Result>: @unchecked Sendable {
    /// At most this many jobs run at once: each scan holds its own state and its transcript's current chunk, so the cap bounds the memory a sweep can take as well as the threads.
    static var defaultWorkers: Int {
        min(ProcessInfo.processInfo.activeProcessorCount, 8)
    }

    private let lock = NSLock()
    private var results: [Result?]
    private var next = 0
    private let order: [Int]
    private let body: @Sendable (Int) -> Result
    private let finished: (Int) -> Void

    /// Jobs `0..<count`, started in `order` where it is given — the largest first, so the last to finish is a small one — and in index order otherwise.
    private init(count: Int, order: [Int]?, body: @escaping @Sendable (Int) -> Result, finished: @escaping (Int) -> Void) {
        results = Array(repeating: nil, count: count)
        self.order = order ?? Array(0 ..< count)
        self.body = body
        self.finished = finished
    }

    /// `body` run for every index in `0..<count` on up to `workers` threads, the results in index order whatever order they finished in.
    ///
    /// `body` must be safe to call from several threads at once; `finished` is called once per job as it completes, never two at a time.
    static func results(
        count: Int,
        workers: Int = defaultWorkers,
        order: [Int]? = nil,
        _ body: @escaping @Sendable (Int) -> Result,
        finished: @escaping (Int) -> Void = { _ in }
    ) -> [Result] {
        // `finished` escapes into the worker threads, which may still hold it for a moment after their last job is
        // recorded, so it is taken as escaping rather than wrapped in a check that would trap on that moment.
        let jobs = ConcurrentScans(count: count, order: order, body: body, finished: finished)
        // Threads of their own rather than the shared pool's: a pool other work has saturated can run every
        // worker one after another on this thread, which is the minutes-long sweep this type exists to avoid.
        let done = DispatchGroup()
        for _ in 1 ..< max(1, min(workers, count)) {
            done.enter()
            let thread = Thread {
                jobs.work()
                done.leave()
            }
            thread.stackSize = 8 << 20
            thread.start()
        }
        jobs.work()
        done.wait()
        // Every index is claimed and stored before the workers return, so none is dropped here.
        return jobs.results.compactMap(\.self)
    }

    /// One worker's share: jobs taken one at a time until none is left.
    private func work() {
        while let index = claim() {
            record(autoreleasepool { body(index) }, at: index)
        }
    }

    /// The next job no worker has taken yet, or `nil` once every job is taken.
    private func claim() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard next < order.count else { return nil }
        next += 1
        return order[next - 1]
    }

    /// Keeps `result` and tells `finished`, one job at a time.
    private func record(_ result: Result, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        results[index] = result
        finished(index)
    }
}
