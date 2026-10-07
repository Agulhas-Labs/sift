//
// Copyright © Agulhas Labs
//

import Foundation

/// The scan data model `TranscriptAudit` sweeps transcripts into — kept in its own file, alongside the primary type it extends, so that file stays inside the length the project holds every file to.
extension TranscriptAudit {
    /// The window clause the header names — `since <day>`, `until <day>`, `<day>` when both bound one single day, `<day> → <day>` (the last day *included*, `until` being exclusive) when both bound more than one, or empty when neither does.
    static func windowText(since: Date?, until: Date?, timeZone: TimeZone) -> String {
        let sinceDay = since.map { day(of: $0, timeZone: timeZone) }
        let untilDay = until.map { day(of: $0, timeZone: timeZone) }
        // `until` names the day excluded, so paired with `since` the header names the day *before* it — the
        // last one actually in the window — rather than printing an end that reads as included when it isn't:
        // a window holding only one day would otherwise print that day twice, as if it held two.
        let lastIncludedDay = until.map { day(of: $0.addingTimeInterval(-1), timeZone: timeZone) }
        return switch (sinceDay, untilDay) {
        case let (since?, _?) where lastIncludedDay == since:
            " \(since)"
        case let (since?, _?):
            " \(since) → \(lastIncludedDay ?? "")"
        case let (since?, nil):
            " since \(since)"
        case let (nil, until?):
            " until \(until)"
        case (nil, nil):
            ""
        }
    }

    /// Every transcript in scope, and every context scanned among them.
    struct Sweep {
        let transcripts: [URL]
        let scans: [Scan]
        /// Every session in the window before a root narrowed it, so an answer that found none in the root can say where they ran.
        var windowed: [URL] = []

        /// The contexts that made a Swift lookup.
        var active: [Scan] {
            scans.filter(\.contributed)
        }
    }

    /// What one transcript's scan is bounded and dated by, shared unchanged across every transcript in a sweep.
    struct ScanOptions {
        let since: Date?
        let until: Date?

        /// Memoised for the whole sweep: the same file is first-touched in every transcript that opened it.
        let belowFloor: (String) -> Bool

        /// Memoised for the whole sweep too, and it matters more here: each answer costs an index open per registered root, and a week of transcripts greps the same handful of names over and over.
        let couldAnswer: (String, String?) -> Bool

        /// Memoised for the whole sweep, same as `couldAnswer` above: this is the member-shaped question, asked once per distinct type-member-root triple rather than once per occurrence across the window.
        let memberExists: (String, String, String?) -> Bool

        let timeZone: TimeZone

        /// Whether to bucket each lookup under its day as well as counting it — the `report` trend needs it, the text audit does not, and it costs a JSON parse per event-bearing line.
        let datesEveryLookup: Bool

        /// The calls the hook's log says it let run, by the rule it logged, scored not worth for a rule of worth and batched for a line run whole, wherever the scan would call them cold.
        var loggedLetThrough: [String: InPlaceAnswerer.Withholding] = [:]

        /// The calls the hook's answered log says it answered in place, scored as an answer delivered as an error is whatever their result's flag says.
        var answeredCalls: Set<String> = []

        /// Whether each scan keeps the windows it scored (`sift scan-dump`), which the audit's own text never reads.
        var keepsWindows = false
    }

    /// One transcript's contribution: a context's counts, and which files it opened cold.
    ///
    /// Every finding carries the local day of the line it came from, when that line was timestamped. The default window is a week, and an audit shared without dates reads every miss as current — days after an update fixed the behaviour behind most of them.
    struct Scan {
        let label: String
        /// The session transcript this belongs to — a subagent's scan carries its parent's path.
        let session: String
        /// The transcript this scan read, the key the replay beside the audit finds these counts by.
        let transcript: String
        /// Whether this is a subagent's own transcript rather than the main session's.
        var isSubagent = false
        var tally = TranscriptTally()
        /// Every window this context scored, kept only where the sweep was asked for them.
        var windows: [ScoredWindow] = []

        /// The same counts split by the local day each lookup landed on, populated only when the caller asked for dating.
        ///
        /// A retraction lands on a later line than the call it takes back, so one straddling a midnight decrements the day it was read on rather than the day it was counted on. The same inexactness the retracted-search span carries, and for the same reason: threading a call id through the event contract to close it is more machinery than a trend row is worth.
        var byDay: [String: TranscriptTally] = [:]
        /// The earliest timestamp the scan judged a window against, and whether the transcript could be read at all — what the tally cache keys a stored scan's window by, and whether it stores one.
        var earliestStamp: Date?
        var wasRead = false
        var coldFiles: [(path: String, day: String?)] = []
        var readWholeFiles: [(path: String, day: String?)] = []
        /// Every Swift-flavoured search that went around the index: the day it landed on, and the call that would have answered it.
        var coldSearchEntries: [(day: String?, missed: MissedCall?)] = []

        /// Every index call that came back an error, with what it was and what it said.
        var failures: [(failure: IndexFailure, day: String?)] = []
        var followUp = DigestFollowUp()

        /// Files whose counted first touch was judged against the disk, having no digest verdict in the transcript.
        var floorFromDisk: Set<String> = []

        /// Whether the transcript records the harness reporting this server as failed in this context.
        var serverFailed = false

        /// Whether this context's transcript ever recorded one of this server's tools as callable, in a `prompt_snapshot` or a `deferred_tools_delta`.
        var heldIndexTools = false

        /// Whether this transcript records the session's `SessionStart` hook failing because the sift binary was not there to run.
        var binaryMissingAtStart = false

        /// Whether the session's own context demonstrably never held sift's tools (``heldNoIndexTools``, read off the session's transcript) — for the session's own scan, its own answer.
        ///
        /// A subagent's MCP tools come from the session's servers, so where the session's own context held none of sift's, no subagent of it could have: the server was not there, and no agent definition was at fault.
        var sessionHeldNoIndexTools = false

        /// Whether the session's own transcript records the sift binary missing when the session started.
        var sessionBinaryMissing = false

        /// Whether this context demonstrably never held sift's tools: its whole tool list is on record without them, or the harness recorded the server failing and never recorded a tool of it arriving.
        ///
        /// Read for the cause a report names, never for the verdict — the verdict rests on the tool list alone (``TranscriptTally/couldNotReachTheIndex``).
        var heldNoIndexTools: Bool {
            tally.recordedToolListWithoutIndex || (serverFailed && !heldIndexTools)
        }

        /// Every refusal that was alone in its turn, with what the round trip cost and the day it did.
        var roundTrips: [(cost: RoundTripCost, day: String?)] = []

        /// Every lone refusal whose next tool call was the identical call, re-run.
        var reRunFollowUps: [ReRunFollowUp] = []

        var coldSearchDays: [String?] {
            coldSearchEntries.map(\.day)
        }

        var coldSearches: Int {
            coldSearchEntries.count
        }

        /// The distinct days this context's misses fall on, oldest first.
        ///
        /// An undated miss simply contributes no day, so a row holding one dated and one undated miss is annotated with the dated one's day. Claude Code stamps every line, so the undated path is defensive; row granularity is not worth machinery for it.
        var missDays: [String] {
            Set((coldFiles.map(\.day) + coldSearchDays).compactMap(\.self)).sorted()
        }

        /// Whether this context made any Swift lookup at all inside the window — one withheld on worth among them, as the headline counts it — or had a call fail, go undelivered or be declined.
        ///
        /// `failed` is in the sum because a call that errored is retracted from `indexed` on its way out: a context whose every index call failed and which read nothing nets zero everywhere else, and without this it is dropped from the sweep entirely — taking the failures with it, out of the one section of the report that is unambiguously a defect. `unavailable` and `declined` are retracted the same way and are in the sum for the same reason.
        ///
        /// `refusals` is in it for the same reason: a context whose every lookup was refused nets zero lookups, and dropping it would drop the round trips those refusals cost from the one report that prices them.
        var contributed: Bool {
            tally.indexed + tally.guided + tally.readWholeAfterDigest + tally.revisited + tally.belowFloor + tally.cold
                + tally.textSearches + tally.withheldOnWorth + tally.failed + tally.unavailable + tally.declined + tally.refusals > 0
        }
    }

    /// A counted file row: display name, occurrences, and the last day one was seen.
    struct CountedEntry {
        let name: String
        let count: Int
        let last: String?
    }

    /// One lone refusal classified as a re-run: its shape, the call itself (verbatim, before redaction), and the day the re-run landed on.
    struct ReRunFollowUp {
        let shape: RefusalShape
        let call: String
        let day: String?
    }
}
