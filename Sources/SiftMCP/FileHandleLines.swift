//
// Copyright © Agulhas Labs
//

import Foundation

/// Bridges a file descriptor to an async sequence of newline-delimited strings, read on a thread of its own.
///
/// **Why not `FileHandle.readabilityHandler` + `availableData`.** That pairing has no safe behaviour for the one condition a long-lived stdio server meets by surprise: a readable event that turns out to carry no bytes. Against the socket pair a Claude Code client gives a spawned server for its stdin, a blocking descriptor makes `availableData` **block inside the readability handler** and never return — the handler's queue is stuck, no further input is ever delivered, and the process sits alive and mute, which is the hung `sift mcp` shape; a non-blocking one makes it raise `NSFileHandleOperationException` ("Resource temporarily unavailable" — `EAGAIN`), an Objective-C exception no Swift `catch` can see, so the process aborts on the spot with no Swift-level error and nothing written anywhere.
///
/// Neither is a failure of the *session*: `EAGAIN` and `EINTR` are ordinary transients that say "nothing yet", not "the client is gone". A loop over `availableData` has no way to say that — a chunk of zero bytes is its only vocabulary for every one of these conditions, and it reads all of them as end of input.
///
/// So the read is `read(2)` on the descriptor, on its own `Thread` — the same reasoning as ``SiftCore/ProcessStreams``: a blocking read that must begin now owes nothing to a thread pool. Only a return of zero is end of input; `EINTR` retries, `EAGAIN` waits for readability and retries, and anything else ends the stream *with its `errno`*, so the reason survives into the lifecycle log instead of being indistinguishable from a client that hung up politely.
///
/// **Two things live here, and the server uses only one of them.** The read itself, ``nextChunk(from:into:)``, is what the server's input (``LineInput``) reads through, so the two cannot come to disagree about what a read means. The stream over it reads ahead for as long as the input lasts, which a server that replaces its own image cannot afford — so the server no longer reads its input through it, and what reads through it is a test reading a server's *output*.
///
/// **The stream has no cancellation path, deliberately.** A consumer that stops iterating leaves the thread blocked in `read(2)` until the descriptor closes. There is no safe way to interrupt it — closing the descriptor under a blocked read is a race, not a cancellation — and a test's pipe closes when the test is done with it. Anything that reaches for this in a context where streams come and go has to solve that first.
struct FileHandleLines {
    /// How much is asked for per read.
    ///
    /// A frame larger than this is not a problem: the accumulator joins reads, so the size here is a syscall-count trade and never a limit on what a client may send.
    static let chunkSize = 64 * 1024

    /// Newline-delimited lines until the input ends; a trailing unterminated line is delivered before finishing.
    static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let descriptor = handle.fileDescriptor
            let reader = Thread {
                // Finished on *every* path out of this thread, deliberately. A stream that stops delivering without finishing suspends its consumer forever — a consumer waiting for a line that will never come, and never told so. A reader that ends must end the stream with it, whatever ended the reader.
                defer { continuation.finish() }
                let accumulator = Accumulator()
                pump(descriptor: descriptor) { chunk in
                    for line in accumulator.append(chunk) {
                        continuation.yield(line)
                    }
                }
                if let remainder = accumulator.drainRemainder() {
                    continuation.yield(remainder)
                }
            }
            reader.name = "sift.lines"
            reader.start()
        }
    }

    /// Reads until the input ends, handing every chunk to `receive`.
    private static func pump(descriptor: Int32, receive: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while case let .bytes(count) = nextChunk(from: descriptor, into: &buffer) {
            receive(Data(buffer[0 ..< count]))
        }
    }

    /// One read's worth of input: bytes at the front of `buffer`, or the reason no more will come.
    ///
    /// The transient outcomes never leave this function — `EINTR` is read again and `EAGAIN` waited out — so a caller sees only the two things a line reader acts on. Shared by both readers of a descriptor here, this stream and ``LineInput``, so the two cannot come to disagree about what a read means.
    static func nextChunk(from descriptor: Int32, into buffer: inout [UInt8]) -> Chunk {
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            // Captured before anything else runs: `poll` and the allocation below both clobber `errno`.
            let code = errno
            switch ReadOutcome.of(count: count, code: code) {
            case .received:
                return .bytes(count)
            case .endOfInput:
                return .ended(.endOfInput)
            case .retry:
                continue
            case .waitForInput:
                // The one place this loop waits rather than progresses, so a failure here has to end it: a
                // `poll` that keeps failing would otherwise spin this thread at full tilt for the life of the
                // process, which is a worse outcome than the session ending with a reason attached.
                guard let failure = waitForReadable(descriptor) else { continue }
                return .ended(.readFailed(code: failure))
            case .failed:
                return .ended(.readFailed(code: code))
            }
        }
    }

    /// Blocks until the descriptor has something to say, so an `EAGAIN` retry is a wait rather than a spin.
    ///
    /// Returns `nil` when it is worth reading again — including a wait a signal interrupted, which is not a failure of the pipe — and the `errno` when it is not.
    private static func waitForReadable(_ descriptor: Int32) -> Int32? {
        var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&watched, 1, -1) < 0 else { return nil }
        let code = errno
        return code == EINTR ? nil : code
    }
}

extension FileHandleLines {
    /// What ``FileHandleLines/nextChunk(from:into:)`` came back with.
    enum Chunk: Equatable {
        /// This many bytes arrived, at the front of the buffer.
        case bytes(Int)
        /// The input is over, and this is why.
        case ended(InputClosure)
    }

    /// What one `read(2)` return means.
    ///
    /// Split out as a pure function because it *is* the distinction that matters: a loop with one interpretation for every non-data outcome reads each of them as "the client closed the pipe".
    enum ReadOutcome: Equatable {
        /// Bytes arrived.
        case received
        /// A return of zero, which on a pipe or socket is the only thing that means the writer is gone.
        case endOfInput
        /// Interrupted before it read anything — read again immediately.
        case retry
        /// Nothing available on a non-blocking descriptor — wait for readability, then read again.
        case waitForInput
        /// A failure that is not any of the above; the session ends and `errno` says why.
        case failed

        static func of(count: Int, code: Int32) -> ReadOutcome {
            if count > 0 {
                return .received
            }
            if count == 0 {
                return .endOfInput
            }
            return switch code {
            case EINTR: .retry
            case EAGAIN, EWOULDBLOCK: .waitForInput
            default: .failed
            }
        }
    }

    /// Byte buffer splitting on 0x0A; confined to the single reader thread.
    final class Accumulator: @unchecked Sendable {
        private var buffer = Data()

        /// Appends a chunk and returns every complete line it closed.
        func append(_ chunk: Data) -> [String] {
            buffer.append(chunk)
            var lines: [String] = []
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex ..< newlineRange.lowerBound)
                buffer = buffer.subdata(in: newlineRange.upperBound ..< buffer.endIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
            return lines
        }

        /// The trailing unterminated line at end of input, if any.
        func drainRemainder() -> String? {
            guard !buffer.isEmpty else { return nil }
            defer { buffer = Data() }
            return String(data: buffer, encoding: .utf8)
        }
    }
}
