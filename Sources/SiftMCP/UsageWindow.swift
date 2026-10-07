//
// Copyright © Agulhas Labs
//

import Foundation

/// Resolves the `--since` argument to the first day a report should include.
///
/// The question the log is actually asked is "did anything use this today", so typing a date to answer it is friction the command should absorb: `today`, `yesterday` and `<N>d` all resolve here, and an explicit `YYYY-MM-DD` passes through.
///
/// The grammar is parsed once and rendered twice, because the two commands legitimately differ on *time zone* and on nothing else. Duplicating the ladder would let a fix to one leave `usage --since` and `audit --since` disagreeing about what `2d` means, which is the class of drift this file exists to prevent.
public struct UsageWindow {
    /// The inclusive first day (`YYYY-MM-DD`) for `text`, or `nil` when it is not a window this understands.
    ///
    /// Resolved in **UTC**, because the log's day key is `ts` truncated to ten characters and `ts` is UTC. Resolving `today` locally instead would, at 00:30 in a UTC+1 summer, ask for a day the calls made minutes earlier are not filed under — the one failure mode that matters, since it hides recent activity rather than showing a little extra.
    public static func firstDay(from text: String, now: Date) -> String? {
        switch parse(text) {
        case let .relative(days):
            day(offsetByDays: days, from: now, timeZone: .gmt)
        case let .explicit(written):
            written
        case nil:
            nil
        }
    }

    /// The instant a window begins: midnight **local** on its first day, or `nil` when `text` is not a window this understands.
    ///
    /// Local where `firstDay` is UTC, and the divergence is deliberate. `usage` filters on the log's own UTC day key; `audit` filters on timestamps, absolute instants with no day key involved, and someone asking what happened *today* means their own today. Sharing one resolution would put the boundary at 01:00 local on UTC+1 and silently drop the first hour of every day.
    public static func start(from text: String, now: Date, timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        switch parse(text) {
        case let .relative(days):
            return calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
        case let .explicit(written):
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.date(from: written)
        case nil:
            return nil
        }
    }

    /// The one place the `--since` vocabulary is defined.
    private static func parse(_ text: String) -> Window? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch trimmed {
        case "today":
            return .relative(days: 0)
        case "yesterday":
            return .relative(days: -1)
        default:
            break
        }
        if trimmed.hasSuffix("d"), let count = Int(trimmed.dropLast()), count >= 0 {
            return .relative(days: -count)
        }
        return isCalendarDay(trimmed) ? .explicit(trimmed) : nil
    }

    /// The day `offsetByDays` from `now` in `timeZone`, formatted as the log files them.
    private static func day(offsetByDays offset: Int, from now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shifted = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether `text` is shaped like the log's day key, without asking whether such a date exists.
    ///
    /// Shape is the whole check on purpose: an impossible date simply matches nothing, which reports as an empty window — a clearer answer than rejecting the argument.
    private static func isCalendarDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else {
            return false
        }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

private extension UsageWindow {
    /// A `--since` argument, parsed but not yet placed in a time zone.
    enum Window {
        case relative(days: Int)
        case explicit(String)
    }
}
