//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the reader a server can replace itself from under: one line per request, and nothing read in between.
///
/// The read loop it shares with ``FileHandleLines`` — what `EINTR`, `EAGAIN` and a real failure each mean — is pinned in ``FileHandleLinesTests``; what is pinned here is what this reader adds, and what an exec depends on.
@Suite(.temporaryDirectories)
struct LineInputTests {
    /// Once a line has been handed out, nothing more is read until the next one is asked for.
    ///
    /// The property an exec rests on. A reader that ran ahead would already be blocked in `read(2)` when the next request arrived and take it into memory that is about to stop existing; here the request stays in the pipe, where the next image reads it. Asserted from outside, by reading the pipe directly: bytes this reader had taken would not be there.
    @Test
    func nothingIsReadBetweenOneLineAndTheNext() async throws {
        let pipe = Pipe()
        let input = LineInput(descriptor: pipe.fileHandleForReading.fileDescriptor)
        pipe.fileHandleForWriting.write(Data("first\n".utf8))

        #expect(try await Self.next(input) == "first")

        pipe.fileHandleForWriting.write(Data("second\n".utf8))
        // Long enough that a reader running ahead would certainly have taken it.
        try await Task.sleep(for: .milliseconds(200))
        let readEnd = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK) == 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }

        #expect(count > 0, "the reader took the next request out of the pipe before anyone asked for it")
        #expect(String(bytes: buffer.prefix(max(count, 0)), encoding: .utf8) == "second\n")
        pipe.fileHandleForWriting.closeFile()
    }

    /// What arrived with a line, past its newline, is held rather than lost — the part of the input an exec has to hand on.
    @Test
    func whatArrivedWithALineIsHeldAsUnread() async throws {
        let pipe = Pipe()
        let input = LineInput(descriptor: pipe.fileHandleForReading.fileDescriptor)
        // One write, so one read delivers all of it: a request, the next one whole, and part of a third.
        pipe.fileHandleForWriting.write(Data("first\nsecond\nthi".utf8))

        #expect(try await Self.next(input) == "first")
        #expect(input.unread == Data("second\nthi".utf8))

        #expect(try await Self.next(input) == "second")
        #expect(input.unread == Data("thi".utf8))
        pipe.fileHandleForWriting.closeFile()
    }

    /// Input handed over from an earlier image comes first, and joins what is read after it as though it had been read here.
    ///
    /// The writer is closed before anything is read, so a reader that lost the handed-over bytes runs out of lines and fails here rather than waiting on the pipe for ever.
    @Test
    func carriedInputIsDeliveredBeforeAnythingIsRead() async throws {
        let pipe = Pipe()
        let input = LineInput(descriptor: pipe.fileHandleForReading.fileDescriptor, carried: Data("handed\nha".utf8))
        pipe.fileHandleForWriting.write(Data("lf\nfresh\n".utf8))
        pipe.fileHandleForWriting.closeFile()

        #expect(try await Self.next(input) == "handed")
        #expect(try await Self.next(input) == "half")
        #expect(try await Self.next(input) == "fresh")
        #expect(try await Self.next(input) == nil)
    }

    /// A last line with no newline is still delivered, and the input then reads as ended — for good.
    @Test
    func theWriterClosingEndsTheInputAfterItsLastLine() async throws {
        let pipe = Pipe()
        let input = LineInput(descriptor: pipe.fileHandleForReading.fileDescriptor)
        pipe.fileHandleForWriting.write(Data("unterminated".utf8))
        pipe.fileHandleForWriting.closeFile()

        #expect(try await Self.next(input) == "unterminated")
        #expect(input.hasEnded)
        #expect(try await Self.next(input) == nil)
        #expect(try await Self.next(input) == nil)
        #expect(input.closure == .endOfInput)
    }

    /// A descriptor that cannot be read ends the input carrying its `errno`, not as a client that hung up.
    @Test
    func aDescriptorThatCannotBeReadEndsWithItsErrno() async throws {
        let path = try TemporaryDirectory.make("line-input-unreadable")
            .appendingPathComponent("line-input-unreadable")
        let descriptor = open(path.path, O_WRONLY | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let input = LineInput(descriptor: descriptor)

        #expect(try await Self.next(input) == nil)
        #expect(input.closure == .readFailed(code: EBADF))
    }

    /// A frame far larger than one read is one line, whole, and the line after it is still found.
    @Test
    func aFrameLargerThanOneReadIsOneLine() async throws {
        let pipe = Pipe()
        let input = LineInput(descriptor: pipe.fileHandleForReading.fileDescriptor)
        let huge = String(repeating: "sift", count: 200_000)
        let writer = Thread { pipe.fileHandleForWriting.write(Data((huge + "\nafter\n").utf8)) }
        writer.start()

        #expect(try await Self.next(input) == huge)
        #expect(try await Self.next(input) == "after")
        pipe.fileHandleForWriting.closeFile()
    }

    /// The next line, waited for with a deadline: a reader that never delivers one fails the test here rather than hanging the suite, and a reader that stops is the regression these exist to catch.
    private static func next(_ input: LineInput, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String? {
        try #require(await Deadline.within(seconds: 10) { await input.next() }, "no line within 10 seconds", sourceLocation: sourceLocation)
    }
}
