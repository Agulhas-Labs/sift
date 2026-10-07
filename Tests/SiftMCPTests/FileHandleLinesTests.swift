//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the read loop the MCP server's whole session hangs off.
@Suite(.temporaryDirectories)
struct FileHandleLinesTests {
    /// The defect this guards against: reading every way a read can decline to hand over bytes as the same thing, and that thing being "the client is gone".
    ///
    /// `EINTR` is a signal arriving mid-read — this process arms three of them — and `EAGAIN` is a descriptor with nothing on it *yet*. Neither says anything about the client. Read as end of input they end a live session, and the four index tools vanish from a session that had been using them correctly. Only a return of zero is end of input, and that is the whole of the claim being pinned here.
    @Test
    func onlyAZeroLengthReadMeansTheClientIsGone() {
        #expect(FileHandleLines.ReadOutcome.of(count: 0, code: 0) == .endOfInput)
        #expect(FileHandleLines.ReadOutcome.of(count: -1, code: EINTR) == .retry)
        #expect(FileHandleLines.ReadOutcome.of(count: -1, code: EAGAIN) == .waitForInput)
        #expect(FileHandleLines.ReadOutcome.of(count: -1, code: EWOULDBLOCK) == .waitForInput)
        #expect(FileHandleLines.ReadOutcome.of(count: 12, code: 0) == .received)
    }

    /// A real read failure is neither a retry nor a quiet ending.
    ///
    /// It stops the stream and says which `errno` it was, so ``ServerLifecycleLog`` records a cause rather than a shrug.
    @Test
    func aRealReadFailureIsNotMistakenForEndOfInput() {
        #expect(FileHandleLines.ReadOutcome.of(count: -1, code: EIO) == .failed)
        #expect(FileHandleLines.ReadOutcome.of(count: -1, code: EBADF) == .failed)
        #expect(FileHandleLines.ReadOutcome.of(count: -1, code: ECONNRESET) == .failed)
    }

    /// `EAGAIN` is waited out, not mistaken for a client that hung up — asserted through the loop rather than through its lookup table.
    ///
    /// This is the mutation that matters most and the one the classification test alone does not catch: with `EAGAIN` read as end of input, the stream finishes before a single byte is written and the line below never arrives. Deterministic despite the timing it looks like it depends on, because the descriptor is non-blocking and `poll(-1)` blocks until the write — there is no race to lose, only a wait that either ends or does not.
    @Test
    func nothingAvailableYetIsWaitedOutRatherThanReadAsAHangUp() async throws {
        let pipe = Pipe()
        // The state `FileHandle.availableData` raises an uncatchable Objective-C exception on, and the one a
        // client's socket can be handed to a spawned server in.
        let readEnd = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK) == 0)
        let lines = ServerResponses(pipe.fileHandleForReading)

        // Long enough that the reader has certainly met an empty descriptor before anything is written.
        try await Task.sleep(for: .milliseconds(200))
        pipe.fileHandleForWriting.write(Data("arrived after a wait\n".utf8))

        #expect(await lines.next(within: 5) == "arrived after a wait")
        pipe.fileHandleForWriting.closeFile()
    }

    /// A descriptor that cannot be read ends the read carrying its `errno`, and is not reported as end of input — and the stream over it ends rather than waiting.
    ///
    /// A write-only descriptor gives a real, deterministic `EBADF` from `read(2)` — no race, no signal to arrange — which is the only way to exercise the failure branch through the loop rather than through its lookup table. Asserted on ``FileHandleLines/nextChunk(from:into:)``, the read both the server's input and this stream go through. Reported as an ordinary ending it would tell ``ServerLifecycleLog`` a client hung up politely when the pipe had in fact broken.
    @Test
    func aDescriptorThatCannotBeReadEndsTheReadWithItsErrno() async throws {
        let path = try TemporaryDirectory.make("unreadable")
            .appendingPathComponent("unreadable")
        let descriptor = open(path.path, O_WRONLY | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var buffer = [UInt8](repeating: 0, count: 64)

        #expect(FileHandleLines.nextChunk(from: descriptor, into: &buffer) == .ended(.readFailed(code: EBADF)))
        let lines = ServerResponses(handle)
        #expect(await lines.next(within: 5) == nil)
    }

    /// A regression guard on the line joining `Accumulator` does.
    @Test
    func linesArriveWholeAcrossChunkBoundaries() async {
        let pipe = Pipe()
        let lines = ServerResponses(pipe.fileHandleForReading)

        // Written in fragments that split a line in the middle, which is what a socket read does on its own.
        pipe.fileHandleForWriting.write(Data("first\nsec".utf8))
        pipe.fileHandleForWriting.write(Data("ond\nthird\n".utf8))

        #expect(await lines.next(within: 5) == "first")
        #expect(await lines.next(within: 5) == "second")
        #expect(await lines.next(within: 5) == "third")
        pipe.fileHandleForWriting.closeFile()
    }

    /// A frame far larger than any single read is one line, not a truncated one and not several.
    ///
    /// Worth asserting because the buffer size is an implementation choice that reads like a limit: a `tools/list` response, a wide digest, or a client sending a large argument all cross it, and a framing bug at that boundary would present as a dropped session — one that works until the request that happens to be big.
    ///
    /// A regression guard: the joining it exercises lives in `Accumulator`.
    @Test
    func aFrameLargerThanTheReadBufferArrivesAsOneLine() async {
        let pipe = Pipe()
        let lines = ServerResponses(pipe.fileHandleForReading)
        let huge = String(repeating: "sift", count: 200_000) // 800 KB, over twelve reads' worth
        let writer = Thread { pipe.fileHandleForWriting.write(Data((huge + "\n").utf8)) }
        writer.start()

        let received = await lines.next(within: 10)

        #expect(received == huge)
        pipe.fileHandleForWriting.closeFile()
    }

    /// A trailing line with no newline is still delivered, and the writer closing is read as an ordinary ending.
    ///
    /// The ending is asserted on ``FileHandleLines/nextChunk(from:into:)``, the read both the server's input and this stream go through, once the stream has drained the pipe.
    @Test
    func theWriterClosingIsReportedAsEndOfInput() async {
        let pipe = Pipe()
        let lines = ServerResponses(pipe.fileHandleForReading)
        pipe.fileHandleForWriting.write(Data("unterminated".utf8))
        pipe.fileHandleForWriting.closeFile()

        #expect(await lines.next(within: 5) == "unterminated")
        #expect(await lines.next(within: 5) == nil)
        var buffer = [UInt8](repeating: 0, count: 64)
        #expect(FileHandleLines.nextChunk(from: pipe.fileHandleForReading.fileDescriptor, into: &buffer) == .ended(.endOfInput))
    }
}
