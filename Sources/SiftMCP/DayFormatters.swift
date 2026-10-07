//
// Copyright © Agulhas Labs
//

import Foundation

/// The formatters that name the day an instant falls on, one for each time zone asked about, each made once and shared.
///
/// Making a date formatter costs several times what formatting with one does, and an audit names the day of every line it counts. A formatter nothing mutates after it is made is safe to use from several threads at once.
final class DayFormatters: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [TimeZone: DateFormatter] = [:]

    /// The formatter naming a day as `yyyy-MM-dd` in `timeZone`, made on the first request for that zone.
    func formatter(for timeZone: TimeZone) -> DateFormatter {
        lock.withLock {
            if let formatter = made[timeZone] {
                return formatter
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            // Local, matching the window it echoes back. Printing a UTC day beside a locally-resolved boundary
            // would name a different date than the one asked for, an hour either side of midnight.
            // Calendar and locale are pinned as the usage window's start pins them, so the day a finding names can
            // be typed back into `--since` — a machine preferring the Buddhist calendar would otherwise date
            // every finding 2569.
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            made[timeZone] = formatter
            return formatter
        }
    }
}
