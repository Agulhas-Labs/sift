//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// Where Swift source is parsed and its tree read: a thread of its own whose stack holds any nesting the parser takes, rather than the half-megabyte one a concurrency thread has.
///
/// SwiftSyntax's parser and every walk of its tree recurse once or more per level of nesting, and a few hundred levels of string interpolation, closures, `#if` or `else if` overflow a small stack long before the parser's own nesting cap stops it; the overflow takes the whole process down. Run here, the parse and every read of its tree share one thread with a 64 MB stack (reserved, and committed only as it is touched), the caller waits for the result, and the tree is gone before the thread takes its next body. A read that asks for another parse while already on such a thread runs it in place.
struct ParseThread {
    /// The stack each parse thread has: enough for the parser's nesting cap, in a debug build too, with the walks of the tree it gives.
    static let stackSize = 64 << 20

    /// How deep the parser nests before it stops descending and records the rest as an error: the release build's default, set here so a debug build parses what a release one does.
    static let maximumNestingLevel = 256

    /// `read` applied to the tree of `source`, the parse and the read both on a parse thread; the tree is local to the call.
    static func parse<Result>(_ source: String, _ read: (SourceFileSyntax) -> Result) -> Result {
        run {
            var parser = Parser(source, maximumNestingLevel: maximumNestingLevel)
            return read(SourceFileSyntax.parse(from: &parser))
        }
    }

    /// `read` applied to `source` parsed as a type alone, the parse and the read both on a parse thread; the tree is local to the call.
    static func parseType<Result>(_ source: String, _ read: (TypeSyntax) -> Result) -> Result {
        run {
            var parser = Parser(source, maximumNestingLevel: maximumNestingLevel)
            return read(TypeSyntax.parse(from: &parser))
        }
    }

    /// `body` run on a parse thread, the caller waiting for it; run in place when the caller is one already.
    static func run<Result>(_ body: () -> Result) -> Result {
        if Thread.current.threadDictionary[threadKey] != nil {
            return body()
        }
        return withoutActuallyEscaping(body) { body in
            let job = Job(body)
            threads.start(job.perform)
            return job.result()
        }
    }

    /// The key a parse thread marks itself with in its thread dictionary.
    private static var threadKey: String {
        "sift.parse-thread"
    }
}

private extension ParseThread {
    /// The process's parse threads: threads are the process's to share, so the one pool belongs to ``ParseThread`` itself and no caller reaches it but ``run(_:)``.
    static let threads = Pool(keeping: max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// The parse threads idle between bodies, so a run reuses one rather than paying for a thread of its own: a signature's parse is far cheaper than starting a thread.
    ///
    /// A run takes an idle thread where there is one and starts a new one where there is none, so no run ever waits on another to finish (a body that fans out to more runs cannot starve the pool); a thread finished with its body waits for the next unless as many as there are cores already wait, and then ends.
    final class Pool: @unchecked Sendable {
        private let lock = NSLock()
        private var idle: [Worker] = []
        private let keeping: Int

        fileprivate init(keeping: Int) {
            self.keeping = keeping
        }

        /// Runs `body` on an idle parse thread, or on a new one where none is idle; returns without waiting for it.
        func start(_ body: @escaping () -> Void) {
            let worker = lock.withLock { idle.popLast() } ?? Worker(pool: self)
            worker.hand(body)
        }

        /// Whether `worker`, finished with its body, waits for another: `false` where enough threads already wait, and it ends.
        fileprivate func park(_ worker: Worker) -> Bool {
            lock.withLock {
                guard idle.count < keeping else { return false }
                idle.append(worker)
                return true
            }
        }
    }

    /// One parse thread and the body it is handed next.
    final class Worker: @unchecked Sendable {
        private let condition = NSCondition()
        private var body: (() -> Void)?

        fileprivate init(pool: Pool) {
            let thread = Thread { [self] in
                Thread.current.threadDictionary[threadKey] = true
                repeat {
                    take()()
                } while pool.park(self)
            }
            thread.stackSize = stackSize
            thread.start()
        }

        /// Gives the thread `body` to run; the thread is idle, or new and not yet waiting.
        fileprivate func hand(_ body: @escaping () -> Void) {
            condition.withLock {
                self.body = body
                condition.signal()
            }
        }

        /// The next body handed to this thread, once there is one.
        private func take() -> () -> Void {
            condition.withLock {
                while body == nil {
                    condition.wait()
                }
                defer { body = nil }
                // The loop above ends only once a body is present.
                guard let body else { preconditionFailure("a parse thread woke without a body") }
                return body
            }
        }
    }

    /// One body handed to a parse thread, and the result it hands back; the caller blocks in ``result()`` until the thread has run it.
    final class Job<Result>: @unchecked Sendable {
        /// Dropped once run, before the caller is woken: the caller's closure must not outlive its call.
        private var body: (() -> Result)?
        private var value: Result?
        private let done = DispatchSemaphore(value: 0)

        init(_ body: @escaping () -> Result) {
            self.body = body
        }

        /// Runs the body, on the parse thread.
        func perform() {
            value = body?()
            body = nil
            done.signal()
        }

        /// The body's result, once the parse thread has run it.
        func result() -> Result {
            done.wait()
            // `perform` stores the value before it signals, so it is present once the wait returns.
            guard let value else { preconditionFailure("a parse thread signalled before storing its result") }
            return value
        }
    }
}
