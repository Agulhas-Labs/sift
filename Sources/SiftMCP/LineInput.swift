//
// Copyright © Agulhas Labs
//

import Foundation

/// The server's input: newline-delimited lines from a descriptor, read one at a time and only when one is asked for.
///
/// **Why not ``FileHandleLines``, which reads the same way.** That stream reads ahead on a thread of its own for as long as the input lasts, so at any instant it may be blocked in `read(2)` or holding bytes it has taken from the pipe and not yet handed on. A process that replaces its own image (``ServerReexec``) destroys both — whatever a read was about to return is gone with the old image, and the client waits for an answer to a request nobody will ever see. Here nothing is read between requests: a line is cut on demand, and what arrived with it past its newline stays in ``unread``, a buffer this process owns and can hand to the next image. Between two calls to ``next()``, everything this reader has not returned is either in ``unread`` or still in the pipe.
///
/// The read itself is ``FileHandleLines/nextChunk(from:into:)`` — `read(2)` on a thread of its own, `EINTR` retried, `EAGAIN` waited out, anything else an ending with its `errno` — so the two readers cannot disagree about what a read means. A line that is not UTF-8 is dropped, as the stream drops it, and a last line with no newline is still delivered once the input ends.
///
/// **One consumer, one call at a time.** The server asks for a line, answers it, and only then asks for the next; a second ``next()`` while one is outstanding is a programming error this type does not guard against. The thread has no cancellation path, for the reason ``FileHandleLines`` gives: it is parked on a semaphore between requests and blocked in `read(2)` during one, and the process exits once the loop it feeds returns.
final class LineInput: @unchecked Sendable {
    private let descriptor: Int32
    /// Guards every mutable property below, which the reader thread and the caller both reach.
    private let lock = NSLock()
    private let demand = DispatchSemaphore(value: 0)
    /// Bytes read, or handed in by an earlier image, that no line has been cut from yet.
    private var held: Data
    /// How many bytes at the front of `held` are already known to hold no newline.
    ///
    /// Kept so that a frame arriving in many reads is searched once rather than once per read.
    private var searched = 0
    /// Why the descriptor stopped giving bytes, once it has.
    private var ending: InputClosure?
    /// Whether ``next()`` has returned `nil`, after which it always does.
    private var finished = false
    /// The call waiting for a line.
    private var waiting: CheckedContinuation<String?, Never>?
    /// Whether the reader thread is running.
    ///
    /// It starts with the first call, so an input nobody reads never holds a thread.
    private var started = false

    /// `carried` is input an earlier image of this process read and did not answer (``ServerHandover``); it is delivered before anything is read.
    init(descriptor: Int32, carried: Data = Data()) {
        self.descriptor = descriptor
        held = carried
    }

    /// The next line, without its newline, or `nil` once the input has ended and every line it held has been returned.
    func next() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiting = continuation
            let start = !started
            started = true
            lock.unlock()
            if start {
                let reader = Thread { [self] in serve() }
                reader.name = "sift.mcp.input"
                reader.start()
            }
            demand.signal()
        }
    }

    /// Everything read and not yet returned as a line, oldest first.
    ///
    /// Only meaningful between calls to ``next()``, which is the only time nothing is being read.
    var unread: Data {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// Whether the descriptor has already reported its end — after which the only lines left are ones already held.
    var hasEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ending != nil
    }

    /// Why the input ended: ``InputClosure/endOfInput`` until it has.
    var closure: InputClosure {
        lock.lock()
        defer { lock.unlock() }
        return ending ?? .endOfInput
    }
}

private extension LineInput {
    /// The reader thread: one line per demand, then back to waiting — never a read without a caller waiting for its line.
    func serve() {
        var chunk = [UInt8](repeating: 0, count: FileHandleLines.chunkSize)
        while true {
            demand.wait()
            let line = produce(reading: &chunk)
            lock.lock()
            let continuation = waiting
            waiting = nil
            if line == nil {
                finished = true
            }
            lock.unlock()
            // Resumed on every path out of here, `nil` included: a caller left waiting is the orphan shape.
            continuation?.resume(returning: line)
            if line == nil {
                return
            }
        }
    }

    /// Cuts the next line from what is held, reading only while what is held has no complete line in it.
    func produce(reading chunk: inout [UInt8]) -> String? {
        while true {
            lock.lock()
            if let line = cutLine() {
                lock.unlock()
                return line
            }
            if ending != nil {
                let last = cutRemainder()
                lock.unlock()
                return last
            }
            lock.unlock()
            let outcome = FileHandleLines.nextChunk(from: descriptor, into: &chunk)
            lock.lock()
            switch outcome {
            case let .bytes(count):
                held.append(contentsOf: chunk[0 ..< count])
            case let .ended(closure):
                ending = closure
            }
            lock.unlock()
        }
    }

    /// The first complete line held, without its newline; called with `lock` held.
    func cutLine() -> String? {
        while let newline = held[(held.startIndex + searched)...].firstIndex(of: 0x0A) {
            let line = held[held.startIndex ..< newline]
            held = Data(held[held.index(after: newline)...])
            searched = 0
            if let text = String(data: line, encoding: .utf8) {
                return text
            }
        }
        searched = held.count
        return nil
    }

    /// The last line of an input that ended without a newline, or `nil` when nothing is left; called with `lock` held.
    func cutRemainder() -> String? {
        guard !held.isEmpty else { return nil }
        defer {
            held = Data()
            searched = 0
        }
        return String(data: held, encoding: .utf8)
    }
}
