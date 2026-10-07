//
// Copyright © Agulhas Labs
//

import Foundation

/// Cuts a toolchain's output, arriving in chunks of raw bytes, into the lines its readers anchor on, and cleans each one the same way for every reader.
///
/// Shared by ``RunOutputFilter``, which reads the whole stream once it has ended, and ``RunLiveTally``, which reads it while it arrives: two spellings of where a line ends or of what comes off its head would let the live count and the final one drift apart over a byte neither of them is about.
struct RunOutputLines {
    /// The bytes of the line still arriving: everything after the last newline seen.
    private var pending = Data()

    /// The complete lines `data` finishes, decoded but not cleaned, holding whatever trailing partial line it ends on for the next chunk.
    mutating func split(_ data: Data) -> [String] {
        split(data) { _ in true }
    }

    /// The complete lines `data` finishes whose raw bytes `keep` accepts, decoded but not cleaned; a line `keep` turns away is never decoded, and a trailing partial line is held for the next chunk whatever `keep` would say of it.
    ///
    /// The newline is found with `memchr` over the buffer's own bytes, and every offset is one into that buffer, never a `Data` index.
    mutating func split(_ data: Data, keeping keep: (UnsafeRawBufferPointer) -> Bool) -> [String] {
        pending.append(data)
        var lines: [String] = []
        let consumed = pending.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else {
                return 0
            }
            var lineStart = 0
            while lineStart < buffer.count, let found = memchr(base + lineStart, Int32(UInt8(ascii: "\n")), buffer.count - lineStart) {
                let newline = base.distance(to: UnsafeRawPointer(found))
                let line = UnsafeRawBufferPointer(rebasing: buffer[lineStart ..< newline])
                if keep(line) {
                    lines.append(Self.decode(line))
                }
                lineStart = newline + 1
            }
            return lineStart
        }
        // One compaction per chunk: dropping the front on every line would make a large log quadratic.
        if consumed > 0 {
            pending = Data(pending.dropFirst(consumed))
        }
        return lines
    }

    /// The partial line the stream ended on without a newline, decoded, or `nil` where it ended on one; the buffer is empty afterwards.
    mutating func remainder() -> String? {
        guard !pending.isEmpty else {
            return nil
        }
        let trailing = Self.decode(pending)
        pending.removeAll()
        return trailing
    }

    /// The token XCTest writes to order one test runner's output against another's, which arrives as the head of whatever line is printed next.
    ///
    /// It is a fixed literal and not a shape to be guessed at, which is what makes stripping it safe: every splice in the corpus is exactly this string in front of an otherwise intact line — three in the passing `xcodebuild` capture, one in the truncated one — and no line any toolchain prints begins with it for any other reason. Left in place it is read as the first word of the line, so a `recorded an issue` line spliced this way names no test the framework wrote and the failure loses its message and its `file:line` both.
    static var outputBarrier: String {
        "XCTestOutputBarrier"
    }

    /// `raw` as every reader expects a line: its carriage return, every ``outputBarrier`` at its head and every ANSI escape in it removed, in that order.
    ///
    /// The barrier comes off repeatedly rather than once: two runners flushing together put two of them in front of one line, and half a strip is worth nothing.
    static func cleaned(_ raw: String) -> String {
        var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        while line.hasPrefix(outputBarrier) {
            line = String(line.dropFirst(outputBarrier.count))
        }
        return RunOutputFilter.strippedOfANSIEscapes(line)
    }

    /// One log line's bytes as text, lossily and deliberately.
    ///
    /// A build log is not guaranteed UTF-8 — a source path, a test name or a third-party tool's output can carry anything — and a failable decode would answer `nil` for the whole line, which drops a diagnostic rather than mangling one character of it. A run that loses an error because a byte could not be spelled is the failure this filter exists to prevent.
    private static func decode(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion no_swiftlint_disable
    }
}
