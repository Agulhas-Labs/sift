//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers `--since` resolution, including the time zone it deliberately does not use.
struct UsageWindowTests {
    /// 23:30 UTC on the 1st — late enough that a UTC+1 local clock has already rolled to the 2nd.
    private static var lateEvening: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 1
        components.hour = 23
        components.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    @Test
    func relativeWindowsResolveToTheDayTheLogFilesThemUnder() {
        #expect(UsageWindow.firstDay(from: "today", now: Self.lateEvening) == "2026-08-01")
        #expect(UsageWindow.firstDay(from: "yesterday", now: Self.lateEvening) == "2026-07-31")
        #expect(UsageWindow.firstDay(from: "7d", now: Self.lateEvening) == "2026-07-25")
        #expect(UsageWindow.firstDay(from: "0d", now: Self.lateEvening) == "2026-08-01")
    }

    @Test
    func aWindowIsResolvedInUTCBecauseThatIsHowTheLogIsFiled() {
        // The failure this prevents: at 00:30 in a UTC+1 summer, a local `today` asks for a day the calls
        // made minutes earlier are not filed under, so "did anything use it just now" answers no.
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 1
        components.hour = 23
        components.minute = 45
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let justBeforeUTCMidnight = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)

        #expect(UsageWindow.firstDay(from: "today", now: justBeforeUTCMidnight) == "2026-08-01")
    }

    @Test
    func explicitDaysPassThroughAndAnythingElseIsRejected() {
        #expect(UsageWindow.firstDay(from: "2026-07-04", now: Self.lateEvening) == "2026-07-04")
        #expect(UsageWindow.firstDay(from: "  TODAY  ", now: Self.lateEvening) == "2026-08-01")
        #expect(UsageWindow.firstDay(from: "last tuesday", now: Self.lateEvening) == nil)
        #expect(UsageWindow.firstDay(from: "2026-7-4", now: Self.lateEvening) == nil)
        #expect(UsageWindow.firstDay(from: "-3d", now: Self.lateEvening) == nil)
        #expect(UsageWindow.firstDay(from: "", now: Self.lateEvening) == nil)
    }

    @Test
    func anImpossibleDateIsAWindowThatMatchesNothingNotAnError() {
        // Shape is the whole check: reporting an empty window is a clearer answer than rejecting the input.
        #expect(UsageWindow.firstDay(from: "2026-02-31", now: Self.lateEvening) == "2026-02-31")
    }
}
