//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI

/// A ``CommandOutput`` that keeps what a command printed, so a test can read its answer back instead of the process's own streams.
///
/// Locked because the closures are `@Sendable` and a command may hand one to a launcher that calls it from the thread reading its child's pipe.
final class RecordedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var printedText = ""
    private var printedRawBytes = Data()
    private var errorLines: [String] = []

    /// Whether ``output`` keeps the part marker, as `CommandOutput.standard` would decide from `CLAUDECODE`/`SIFT_PART_MARKER` — `false` stands in for a plain pipe with neither set.
    private let keepsPartMarker: Bool

    init(keepsPartMarker: Bool = false) {
        self.keepsPartMarker = keepsPartMarker
    }

    /// Everything written to stdout, raw bytes and lines alike, in the order it was written.
    var printed: String {
        lock.withLock { printedText }
    }

    /// Every byte handed to `emitRaw`, exactly as received — not decoded, so a test can assert on bytes that are not valid UTF-8.
    var printedBytes: Data {
        lock.withLock { printedRawBytes }
    }

    /// Every line written to stderr, in order.
    var errors: [String] {
        lock.withLock { errorLines }
    }

    /// The sink to inject into the command under test.
    var output: CommandOutput {
        CommandOutput(
            keepsPartMarker: keepsPartMarker,
            emit: { line in self.lock.withLock { self.printedText += line + "\n" } },
            emitRaw: { data in self.lock.withLock {
                self.printedText += String(bytes: data, encoding: .utf8) ?? ""
                self.printedRawBytes += data
            } },
            emitError: { line in self.lock.withLock { self.errorLines.append(line) } }
        )
    }
}
