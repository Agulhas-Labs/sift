//
// Copyright © Agulhas Labs
//

import Foundation

/// Which of a run's raw lines the live tally must read, decided on the line's bytes before it is decoded: most of a build log is lines no reader of the tally could take for anything, and decoding each one is where a long log's time went.
///
/// A line passes where any reader ``RunLiveTally`` asks could match it once the line is cleaned: it opens on `[` (a SwiftPM counter or a parallel test), `S` or `C` (an `xcodebuild` compile), or `A` (SwiftPM's lock notice glued to a test opening), or it carries `Test` anywhere (every test line, and the `XCTestOutputBarrier` a spliced line opens on), `error: ` or `warning: ` (every diagnostic), or an escape byte, whose removal could join any of these. Cleaning only ever removes bytes, a trailing carriage return, a barrier or an escape, so a line without any of them cannot gain one.
struct RunLiveLineScreen {
    /// Whether the tally must decode and read `line`, its bytes without the newline.
    static func mayMatter(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let first = line.first, let base = line.baseAddress else {
            return false
        }
        switch first {
        case UInt8(ascii: "["), UInt8(ascii: "S"), UInt8(ascii: "C"), UInt8(ascii: "A"):
            return true
        default:
            break
        }
        if memchr(base, 0x1B, line.count) != nil {
            return true
        }
        return contains("Test", in: line) || contains("error: ", in: line) || contains("warning: ", in: line)
    }

    private static func contains(_ needle: StaticString, in line: UnsafeRawBufferPointer) -> Bool {
        memmem(line.baseAddress, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
}
