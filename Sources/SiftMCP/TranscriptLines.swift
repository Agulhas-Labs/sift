//
// Copyright © Agulhas Labs
//

import Foundation

/// A transcript's non-empty lines, read from disk a chunk at a time, so a scan holds the line it is on and the chunk it came in rather than the whole file.
///
/// A sweep scans several transcripts at once and they reach tens of megabytes each; read whole, the largest few would be resident together for as long as their scans ran. The bytes are read with plain system calls into a buffer this type owns, so nothing is left to an autorelease pool between lines.
final class TranscriptLines: Sequence, IteratorProtocol {
    /// How much is read at a time; not a cap on any one line's length.
    static let chunkSize = 1 << 18

    private let descriptor: Int32
    private let chunk: Int
    private var remaining: Int
    private var buffer: [UInt8] = []
    private var start = 0
    private var atEnd = false

    /// The lines of the file at `url`, read no further than `limit` bytes where one is given, a chunk at a time, or nil where the file cannot be opened.
    init?(url: URL, limit: Int?, chunkSize: Int = TranscriptLines.chunkSize) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor
        chunk = Swift.max(chunkSize, 1)
        remaining = limit ?? Int.max
    }

    deinit {
        close(descriptor)
    }

    /// The next line that holds anything, without its newline, or nil once the file or its limit is reached.
    func next() -> Data? {
        while true {
            if let newline = newlineAfterStart() {
                let line = start ..< newline
                start = newline + 1
                if !line.isEmpty {
                    return Data(buffer[line])
                }
                continue
            }
            if atEnd {
                guard start < buffer.count else { return nil }
                let last = Data(buffer[start...])
                start = buffer.count
                return last
            }
            fill()
        }
    }

    /// The position of the first newline at or after `start`, if the buffer holds one.
    private func newlineAfterStart() -> Int? {
        guard start < buffer.count else { return nil }
        return buffer.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress, let found = memchr(base + start, 0x0A, bytes.count - start) else { return nil }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }

    /// Drops the lines already handed out and reads the next chunk behind what is left, noting the end once the file or the limit runs out.
    private func fill() {
        buffer.removeSubrange(..<start)
        start = 0
        let wanted = Swift.min(chunk, remaining)
        guard wanted > 0 else {
            atEnd = true
            return
        }
        let kept = buffer.count
        buffer.append(contentsOf: repeatElement(0, count: wanted))
        var got: Int
        repeat {
            got = buffer.withUnsafeMutableBufferPointer { bytes in
                read(descriptor, bytes.baseAddress.map { $0 + kept }, wanted)
            }
        } while got < 0 && errno == EINTR
        let count = Swift.max(got, 0)
        buffer.removeSubrange((kept + count)...)
        remaining -= count
        if count == 0 {
            atEnd = true
        }
    }
}
