//
// Copyright © Agulhas Labs
//

import Foundation

/// A transcript timestamp in the one shape the harness writes every one in, read by hand: a UTC date and time to the millisecond, twenty-four characters ending in `Z`.
///
/// An audit reads a timestamp for every line of every transcript it scans and again for every line it replays, and the ISO-8601 formatter spent more on each than the rest of the line's handling. The shape is fixed-width, so this reads its digits where they stand and computes the instant the formatter computes, to the same bit: milliseconds since 1970, divided by a thousand. Anything else — another shape, a field out of range, a day the month does not have — is not read here, and goes to the formatter, which decides it exactly as before.
struct TranscriptTimestamp {
    /// The instant `text` names when it is a millisecond UTC timestamp with every field in range, or `nil` for the formatter to decide.
    static func instant(_ text: String) -> Date? {
        var text = text
        return text.withUTF8(instant(utf8:))
    }

    private static func instant(utf8 bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        // The separators stand at fixed offsets: the date's two dashes, the T, the time's two colons, the decimal point and the Z.
        guard bytes.count == 24,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "."),
              bytes[23] == UInt8(ascii: "Z")
        else { return nil }
        func number(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for index in start ..< start + count {
                let digit = Int(bytes[index]) - Int(UInt8(ascii: "0"))
                guard (0 ... 9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              let millisecond = number(20, 3),
              year >= 1970, (1 ... 12).contains(month), day >= 1, day <= days(inMonth: month, of: year),
              hour < 24, minute < 60, second < 60
        else { return nil }
        let seconds = daysSince1970(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(seconds * 1000 + millisecond) / 1000)
    }

    private static func days(inMonth month: Int, of year: Int) -> Int {
        switch month {
        case 2:
            year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11:
            30
        default:
            31
        }
    }

    /// The days from the first day of 1970 to a date of the proleptic Gregorian calendar, counted from a year that begins in March so the leap day falls last.
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let marchYear = month <= 2 ? year - 1 : year
        let era = marchYear / 400
        let yearOfEra = marchYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
