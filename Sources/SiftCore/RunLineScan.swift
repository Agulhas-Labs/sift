//
// Copyright © Agulhas Labs
//

import Foundation

/// Hand-written reads of the shapes a run's live and final readers take off a line on every line they see, in place of a regex built on each call or a Foundation trim.
///
/// **Each one answers exactly what the regex or the trim it replaces answered.** A regex's `\d`, `\w` and `.` are Unicode-aware and read a line by its characters, so the hand-written path is taken only for a line of printable ASCII and tabs, where a byte is a character and the classes are plain; any other line goes to the regex as before. A trim keeps `CharacterSet.whitespaces` (a tab and the space separators) and works on unicode scalars, as `trimmingCharacters(in:)` does.
struct RunLineScan {
    /// Whether every byte of `text` is printable ASCII or a tab: the lines whose characters are their bytes.
    static func isPlainASCII(_ text: Substring) -> Bool {
        text.utf8.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x09 }
    }

    /// `text` with the scalars `CharacterSet.whitespaces` holds removed from both ends, as `trimmingCharacters(in: .whitespaces)` would give it.
    static func trimmingWhitespace(_ text: Substring) -> Substring {
        let scalars = text.unicodeScalars
        let whitespace = CharacterSet.whitespaces
        guard let first = scalars.firstIndex(where: { !whitespace.contains($0) }),
              let last = scalars.lastIndex(where: { !whitespace.contains($0) })
        else {
            return ""
        }
        return Substring(scalars[first ... last])
    }

    /// The test SwiftPM's `--parallel` progress line reports on, `[3/12] Testing Suite/testName` giving `Suite/testName`, or `nil` for any other line: what `\[\d+/\d+\] Testing (.+)` matched at the line's start.
    static func parallelTestName(in line: String) -> String? {
        let bytes = line.utf8
        // The pattern's `]` is the line's first: nothing its counter matches is one.
        guard bytes.first == UInt8(ascii: "["), let close = bytes.firstIndex(of: UInt8(ascii: "]")),
              bytes[close...].starts(with: "] Testing ".utf8)
        else {
            return nil
        }
        guard isPlainASCII(line[...]) else {
            return line.prefixMatch(of: #/\[\d+/\d+\] Testing (.+)/#).map { String($0.output.1) }
        }
        let slash = digitsEnd(in: bytes, from: bytes.index(after: bytes.startIndex))
        guard slash > bytes.index(after: bytes.startIndex), slash < close, bytes[slash] == UInt8(ascii: "/") else {
            return nil
        }
        let denominator = bytes.index(after: slash)
        guard digitsEnd(in: bytes, from: denominator) == close, close > denominator else {
            return nil
        }
        let name = line[bytes.index(close, offsetBy: "] Testing ".utf8.count)...]
        return name.isEmpty ? nil : String(name)
    }

    /// The seconds in an XCTest finishing line's parenthesised duration, `passed (0.172 seconds).`: the leftmost `\((\d+(?:\.\d+)?) seconds\)` anywhere in `tail`.
    static func xctestSeconds(in tail: Substring) -> Double? {
        guard isPlainASCII(tail) else {
            return tail.firstMatch(of: #/\((\d+(?:\.\d+)?) seconds\)/#).flatMap { Double($0.output.1) }
        }
        let bytes = tail.utf8
        var cursor = bytes.startIndex
        while let open = bytes[cursor...].firstIndex(of: UInt8(ascii: "(")) {
            let start = bytes.index(after: open)
            if let end = numberEnd(in: bytes, from: start), bytes[end...].starts(with: " seconds)".utf8) {
                return Double(tail[start ..< end])
            }
            cursor = start
        }
        return nil
    }

    /// The seconds in a Swift Testing finishing line's duration, ` passed after 0.001 seconds.`: `\w+ after (\d+(?:\.\d+)?) seconds` after one space at the head of `tail`.
    static func swiftTestingSeconds(in tail: Substring) -> Double? {
        guard isPlainASCII(tail) else {
            return tail.prefixMatch(of: #/ \w+ after (\d+(?:\.\d+)?) seconds/#).flatMap { Double($0.output.1) }
        }
        let bytes = tail.utf8
        guard bytes.first == UInt8(ascii: " ") else {
            return nil
        }
        let wordStart = bytes.index(after: bytes.startIndex)
        let wordEnd = bytes[wordStart...].firstIndex { !isWordByte($0) } ?? bytes.endIndex
        guard wordEnd > wordStart, bytes[wordEnd...].starts(with: " after ".utf8) else {
            return nil
        }
        let start = bytes.index(wordEnd, offsetBy: " after ".utf8.count)
        guard let end = numberEnd(in: bytes, from: start), bytes[end...].starts(with: " seconds".utf8) else {
            return nil
        }
        return Double(tail[start ..< end])
    }

    /// The iteration an XCTest start line names, `started (Iteration 2 of 3).`, and 1 for any other start; the regex is only built for a line opening on its literal words.
    static func iterationNumber(in tail: Substring) -> Int {
        guard tail.hasPrefix("started (Iteration "), let match = tail.prefixMatch(of: #/started \(Iteration (\d+) of \d+\)/#) else {
            return 1
        }
        return Int(match.output.1) ?? 1
    }

    /// Where `\d+(?:\.\d+)?` starting at `start` ends, or `nil` where no digit stands there; for ASCII text only.
    private static func numberEnd(in bytes: Substring.UTF8View, from start: Substring.UTF8View.Index) -> Substring.UTF8View.Index? {
        let whole = digitsEnd(in: bytes, from: start)
        guard whole > start else {
            return nil
        }
        guard whole < bytes.endIndex, bytes[whole] == UInt8(ascii: ".") else {
            return whole
        }
        let fraction = bytes.index(after: whole)
        let end = digitsEnd(in: bytes, from: fraction)
        return end > fraction ? end : whole
    }

    /// Where the run of ASCII digits starting at `start` ends.
    private static func digitsEnd<Bytes: BidirectionalCollection>(in bytes: Bytes, from start: Bytes.Index) -> Bytes.Index where Bytes.Element == UInt8 {
        bytes[start...].firstIndex { $0 < UInt8(ascii: "0") || $0 > UInt8(ascii: "9") } ?? bytes.endIndex
    }

    /// Whether an ASCII byte is one `\w` matches: a letter, a digit or an underscore.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "_"): true
        default: false
        }
    }
}
