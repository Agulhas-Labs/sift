//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A transcript timestamp read by hand names the instant the ISO-8601 formatter names, to the bit, and anything it does not read is left to the formatter.
struct TranscriptTimestampTests {
    private static func formatted(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Every day of every month of a leap year and of a common one, at times spread over the day and the second, reads as the formatter reads it.
    @Test(arguments: [2024, 2026, 2100])
    func everyDayReadsAsTheFormatterReadsIt(year: Int) {
        var generator = SystemRandomNumberGenerator()
        let lengths = [31, year % 4 == 0 && year % 100 != 0 ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        for (month, length) in zip(1..., lengths) {
            for day in 1 ... length {
                for _ in 0 ..< 20 {
                    let text = String(
                        format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                        year, month, day,
                        Int.random(in: 0 ... 23, using: &generator),
                        Int.random(in: 0 ... 59, using: &generator),
                        Int.random(in: 0 ... 59, using: &generator),
                        Int.random(in: 0 ... 999, using: &generator)
                    )
                    let read = TranscriptTimestamp.instant(text)
                    #expect(read != nil, "\(text)")
                    #expect(read == Self.formatted(text), "\(text)")
                }
            }
        }
    }

    /// A field out of range, a day the month lacks, another shape or a stray character is not read by hand, and the scan's reading of it is still the formatter's.
    @Test(arguments: [
        "2026-02-29T10:00:00.000Z", "2026-02-30T10:00:00.000Z", "2026-04-31T10:00:00.000Z", "2026-13-01T10:00:00.000Z",
        "2026-00-01T10:00:00.000Z", "2026-01-00T10:00:00.000Z", "2026-01-01T24:00:00.000Z", "2026-01-01T10:60:00.000Z",
        "2026-01-01T10:00:60.000Z", "2026-01-01T10:00:00Z", "2026-01-01T10:00:00.000+02:00", "2026-01-01 10:00:00.000Z",
        "2026-01-01T10:00:00.00xZ", "1969-12-31T23:59:59.999Z", "",
    ])
    func whatIsNotReadByHandIsTheFormattersToDecide(text: String) {
        #expect(TranscriptTimestamp.instant(text) == nil)
        let wholeSeconds = ISO8601DateFormatter()
        #expect(TranscriptScan.instant(text) == Self.formatted(text) ?? wholeSeconds.date(from: text))
    }
}
