//
// Copyright © Agulhas Labs
//

import Foundation

/// The length of one window in an audit's trend form: a calendar day, or a week that starts on a Monday.
public enum AuditTrendUnit: String, CaseIterable, Sendable {
    case day
    case week
}

extension TranscriptAudit {
    /// The two lines `--share` prints: the headline share and the voluntary share, each with its fraction.
    static func shareLines(_ totals: TranscriptTally) -> [String] {
        let headline = totals.total > 0 ? "\(totals.shareText ?? "n/a") = \(totals.indexed) / \(totals.total)" : "n/a"
        return [
            "served by sift — \(headline) of the lookups that had a choice",
            "voluntary — \(totals.voluntaryShareText ?? "n/a") of the lookups that had a choice",
        ]
    }

    /// The trend form's rows, one per window of `unit`, oldest first, clipped to `since` and `until`.
    ///
    /// Each row is the summary's own numbers for the lookups that landed in the window, taken from the days the one scan dated. The span runs from `since`'s day (the first day a lookup landed on where there is none) to the day before `until` (the last day a lookup landed on where there is none). A window with no lookups reads `choice 0` and nothing more. A last line counts the lookups whose lines carried no time, when there are any. The numbers are right-aligned to the widest in their column.
    static func trendLines(scans: [Scan], unit: AuditTrendUnit, since: Date?, until: Date?, timeZone: TimeZone) -> [String] {
        let rows = trendWindows(scans: scans, unit: unit, since: since, until: until, timeZone: timeZone)
        // Counted in the span and in no row: a lookup whose call carried no time cannot be put in a window.
        let undated = scans.reduce(0) { $0 + $1.undated.scored(inContext: $1.tally).everything }
        guard undated > 0 else { return rows }
        return rows + ["\(undated) lookups carry no time, counted in the first line but in no window"]
    }

    private static func trendWindows(scans: [Scan], unit: AuditTrendUnit, since: Date?, until: Date?, timeZone: TimeZone) -> [String] {
        var byDay: [String: TranscriptTally] = [:]
        for scan in scans {
            for (day, tally) in scan.byDay {
                byDay[day, default: TranscriptTally()] += tally.scored(inContext: scan.tally)
            }
        }
        guard let firstData = byDay.keys.min(), let lastData = byDay.keys.max() else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let first = since.map({ calendar.startOfDay(for: $0) }) ?? startOfDay(firstData, in: calendar),
              let last = startOfDay(lastData, in: calendar)
        else { return [] }
        let end = until.map { calendar.startOfDay(for: $0) } ?? calendar.date(byAdding: .day, value: 1, to: last)
        guard let end else { return [] }

        var windows: [(label: String, tally: TranscriptTally)] = []
        var cursor = first
        while cursor < end {
            let name = day(of: cursor, timeZone: timeZone)
            let startsWeek = calendar.component(.weekday, from: cursor) == 2
            if unit == .day || startsWeek || windows.isEmpty {
                windows.append((name, TranscriptTally()))
            }
            if let tally = byDay[name] {
                windows[windows.count - 1].tally += tally
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return trendRows(windows)
    }

    /// The text of each window's row, with the columns padded so they line up.
    private static func trendRows(_ windows: [(label: String, tally: TranscriptTally)]) -> [String] {
        let counted = windows.map { $0.tally.total > 0 }
        func widest(_ value: (TranscriptTally) -> String) -> Int {
            zip(windows, counted).filter(\.1).map { value($0.0.tally).count }.max() ?? 0
        }
        let choice = { (tally: TranscriptTally) in String(tally.total) }
        let indexed = { (tally: TranscriptTally) in tally.shareText ?? "n/a" }
        let voluntary = { (tally: TranscriptTally) in tally.voluntaryPercentText ?? "n/a" }
        let cold = { (tally: TranscriptTally) in String(tally.cold) }
        let answered = { (tally: TranscriptTally) in String(tally.answered) }
        let widths = [choice, indexed, voluntary, cold, answered].map(widest)

        return zip(windows, counted).map { window, hasChoice in
            guard hasChoice else { return "\(window.label)  choice 0" }
            let tally = window.tally
            let fields = [
                ("choice", choice(tally)), ("indexed", indexed(tally)), ("voluntary", voluntary(tally)),
                ("cold", cold(tally)), ("answered", answered(tally)),
            ]
            let cells = zip(fields, widths).map { field, width in
                "\(field.0) \(String(repeating: " ", count: max(0, width - field.1.count)))\(field.1)"
            }
            return ([window.label] + cells).joined(separator: "  ")
        }
    }

    /// The start of the local day `name` (`yyyy-MM-dd`) names, or `nil` where it is not one.
    private static func startOfDay(_ name: String, in calendar: Calendar) -> Date? {
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

extension TranscriptTally {
    /// Every Swift lookup by any route, the first line's count.
    var everything: Int {
        indexed + guided + readWholeAfterDigest + revisited + belowFloor + cold + textSearches + withheldOnWorth + unreachable
    }
}
