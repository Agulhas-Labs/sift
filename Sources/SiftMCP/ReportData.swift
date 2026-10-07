//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Everything the `report` page states, assembled from what already accumulates — and nothing it cannot point at.
///
/// The order the sections appear in is the design decision, not the styling: the conditions awaiting a human lead, then the share, which can fall. A call counter only ever rises and reads as adoption whatever the truth is, so counters come last (Docs/Design.md §3).
///
/// Assembled here and rendered by ``ReportPage``, which is a pure function of this value. Nothing in this type reads the home directory on its own: every path and every probe arrives as an argument, so the whole page is testable without an indexed repository or a real log.
public struct ReportData: Sendable, Equatable {
    /// When the page was rendered — a report states its own age, unlike a query answer.
    public let generatedAt: Date

    /// The window as it was asked for (`7d`, `today`, `YYYY-MM-DD`).
    public let window: String

    /// The inclusive first day of the log read, as the log files days — UTC, matching `usage --since`.
    public let firstLogDay: String?

    /// The first local day transcripts were read from, matching `audit --since`.
    ///
    /// Not the same axis as the log's, which is why the page states both rather than blurring them into one window.
    public let firstTranscriptDay: String?

    /// What a `--root` argument came to, when one was given.
    public let rootScope: RootScope?

    /// Conditions awaiting a human.
    ///
    /// Empty is the ordinary case, and renders as nothing at all rather than as a standing all-clear.
    public let conditions: [Condition]

    /// The index's share of the Swift lookups this machine's transcripts recorded, or `nil` when they recorded none.
    public let share: Share?

    /// What the measured answers saved, over the calls that measured themselves.
    public let savings: UsageScan.Savings?

    /// What the wrapped toolchain runs in scope add up to, or `nil` when there were none.
    ///
    /// Its own field beside `savings` rather than folded into it: both are compression measured against a real original, but one is source a digest stood in for and the other is build output a filter dropped, and adding them would produce a number about nothing.
    public let runs: RunScan.Summary?

    /// Calls in scope.
    public let calls: Int

    /// Failed calls grouped by the reason they recorded, most-frequent first.
    public let failures: [UsageScan.FailureGroup]

    /// Calls by root, most-used first.
    public let roots: [RootUse]

    /// The most-asked-for targets, most-frequent first.
    public let targets: [TargetUse]

    /// Why the usage log contributed nothing, when it did not — a missing log is a state to report, not to render as zero.
    public let logNote: String?

    /// The line saying how many calls against scratch roots were left out of every figure, or `nil` when none were.
    public let scratchNote: String?

    public let logPath: String
    public let transcriptDirectory: String

    /// Reads the log, the transcripts and the registered roots into one page's worth of facts.
    ///
    /// `moduleHealth` is the read-only probe behind the conditions list — the session primer's, injected so a test can pin the section without standing up an indexed repository, and so this can never index as a side effect.
    ///
    /// `roots` is passed in for the same reason `TranscriptAudit.render` takes it: reading the registry here would make every test depend on whatever the machine running it happens to have indexed.
    ///
    /// `progress` is told each stage as it starts, and the sweep of transcripts as it advances — the one stage that takes minutes — so a caller can print them and a long run reads as slow, not stuck.
    ///
    /// `tallyCache` is where each transcript's counts are kept between runs, so an unchanged transcript is not read twice; `nil`, every test's default, reads them all.
    ///
    /// `runLogURL` is optional for the reason `UsageReport`'s is: defaulting it to the standard path would have a test asking about a log it wrote pick up whatever this machine happens to have built. The suppression log is optional for the same reason, and read as `TranscriptAudit.render` reads it.
    public static func assemble(
        logURL: URL,
        runLogURL: URL? = nil,
        suppressionLogURL: URL? = nil,
        projectsDirectory: URL,
        roots: [String],
        since: String?,
        root: String?,
        includeScratch: Bool = false,
        now: Date,
        timeZone: TimeZone = .current,
        tallyCache: TranscriptTallyCache? = nil,
        moduleHealth: (String) -> SessionPrimer.ModuleHealth? = ReportData.indexedModuleHealth,
        progress: @escaping (String) -> Void = { _ in }
    ) -> ReportData {
        let firstLogDay = since.flatMap { UsageWindow.firstDay(from: $0, now: now) }
        let transcriptStart = since.flatMap { UsageWindow.start(from: $0, now: now, timeZone: timeZone) }

        var calls = 0
        var failures: [UsageScan.FailureGroup] = []
        var rootUse: [RootUse] = []
        var targets: [TargetUse] = []
        var savings: UsageScan.Savings?
        var logNote: String?
        var scratchNote: String?
        var resolvedRoot: String?
        var rootScope: RootScope?
        var runs: RunScan.Summary?

        // One argument, one directory, resolved against both logs' roots together — the calls below and the
        // runs beside them are two halves of one heading, and resolving the fragment twice could let them name two
        // different repositories. A refusal scopes nothing and renders no run figure, exactly as the CLI
        // face refuses; the header states it, because a page that reads as unscoped while its reason sits
        // far below is read as machine-wide.
        var transcriptScope: String?
        switch LogScope.resolve(root, inLogsAt: [logURL] + [runLogURL].compactMap(\.self)) {
        case let .success(scope):
            rootScope = scope.map { .resolved($0.path) }
            // The scope's own path, not `resolvedRoot` below: that one depends on the usage log having
            // loaded and having actually recorded this root, and a transcript's `cwd` can place it inside a
            // root the usage log has never mentioned.
            transcriptScope = scope?.path
            progress("reading the usage log \(logURL.path)")
            switch UsageScan.load(fileURL: logURL, since: firstLogDay, scope: scope, includeScratch: includeScratch) {
            case let .success(scan):
                resolvedRoot = scan.resolvedRoot
                scratchNote = scan.scratchNote
                calls = scan.entries.count
                savings = scan.savings
                failures = scan.failureGroups
                let total = scan.entries.count
                let byRoot = scan.grouped(by: \.root)
                let allRoots = byRoot.map(\.0)
                rootUse = byRoot.map { path, group in
                    RootUse(
                        root: path,
                        name: AuditModuleHealth.name(path, among: allRoots),
                        calls: group.count,
                        percent: total > 0 ? Int((Double(group.count) / Double(total) * 100).rounded()) : 0
                    )
                }
                targets = scan.topTargets().map { TargetUse(label: $0.label, count: $0.count, days: $0.days) }
                if scan.entries.isEmpty {
                    logNote = "no calls in this window — \(scan.logged) in the log overall"
                }
            case let .failure(problem):
                logNote = note(for: problem)
            }
            runs = runLogURL.flatMap { RunScan.load(fileURL: $0, since: firstLogDay, scope: scope).summary }
        case let .failure(problem):
            rootScope = root.map { .unresolved(argument: $0) }
            logNote = note(for: problem)
        }

        let tallies = TranscriptAudit.tallies(
            projectsDirectory: projectsDirectory,
            since: transcriptStart,
            now: now,
            timeZone: timeZone,
            root: transcriptScope,
            excludingScratch: !includeScratch,
            suppressionLog: suppressionLogURL,
            tallyCache: tallyCache,
            progress: progress
        )

        // Conditions are scoped by `--root` the same way the log sections are, so a report about one
        // repository does not open with another repository's unfinished business.
        let scopedRoots = resolvedRoot.map { scope in roots.filter { $0 == scope || $0.hasPrefix(scope + "/") } } ?? roots
        return ReportData(
            generatedAt: now,
            window: since ?? "everything recorded",
            firstLogDay: firstLogDay,
            firstTranscriptDay: transcriptStart.map { day(of: $0, timeZone: timeZone) },
            rootScope: rootScope,
            conditions: conditions(roots: scopedRoots, moduleHealth: moduleHealth),
            share: share(from: tallies),
            savings: savings,
            runs: runs,
            calls: calls,
            failures: failures,
            roots: rootUse,
            targets: targets,
            logNote: logNote,
            scratchNote: scratchNote,
            logPath: logURL.path,
            transcriptDirectory: projectsDirectory.path
        )
    }

    /// The module health of an indexed root, read strictly read-only.
    ///
    /// Opening the index properly would let a report rebuild a schema — the same discipline `SiblingIndexProbe` and the session-start warning hold to. A root with no index simply contributes nothing.
    public static func indexedModuleHealth(atRoot root: String) -> SessionPrimer.ModuleHealth? {
        ReadOnlyIndex.snapshot(atRoot: root).map {
            SessionPrimer.ModuleHealth(guessed: $0.guessedModules, files: $0.files)
        }
    }

    /// The conditions only a person can clear, worst first.
    ///
    /// One instance so far — a repository whose modules are mostly guesswork. It is the class this list exists for: a condition the tool can detect, that no amount of talking to the agent resolves, and that is otherwise reported over and over to a reader who cannot act on it. Nothing here is a count; a condition either holds or it does not.
    private static func conditions(roots: [String], moduleHealth: (String) -> SessionPrimer.ModuleHealth?) -> [Condition] {
        roots.compactMap { root -> (root: String, health: SessionPrimer.ModuleHealth)? in
            guard let health = moduleHealth(root), health.isMostlyGuessed else { return nil }
            return (root: root, health: health)
        }
        .sorted { $0.health.guessed > $1.health.guessed }
        .map { entry in
            let share = entry.health.guessed * 100 / entry.health.files
            return Condition(
                root: entry.root,
                name: AuditModuleHealth.name(entry.root, among: roots),
                headline: "Module names are mostly guesswork — \(share)% of files (\(entry.health.guessed) of \(entry.health.files))",
                fact: "Those files answer on time about a module that does not exist: \(GuessedModuleNotice.consequence). It is invisible in every count below.",
                action: GuessedModuleNotice.humanRemedy,
                command: "sift init \(entry.root)"
            )
        }
    }

    private static func share(from tallies: TranscriptAudit.Tallies) -> Share? {
        guard tallies.totals.total > 0 else { return nil }
        return Share(
            tally: tallies.totals,
            sessions: tallies.sessions,
            byDay: tallies.byDay.compactMap { row in
                guard let share = row.tally.share, let shareText = row.tally.shareText else { return nil }
                return DayShare(
                    day: row.day,
                    indexed: row.tally.indexed,
                    total: row.tally.total,
                    share: share,
                    shareText: shareText
                )
            }
        )
    }

    /// What a log that could not be read contributes: a stated reason, never a zero.
    private static func note(for problem: UsageScan.Problem) -> String {
        switch problem {
        case .missingOrEmpty:
            "no usage recorded yet — the log is missing or empty"
        case let .unreadable(malformed):
            "no readable entries (\(malformed) malformed line\(malformed == 1 ? "" : "s"))"
        case let .rootUnmatched(argument, roots):
            "nothing recorded for a root matching \(argument) — the logs hold \(roots.count) root\(roots.count == 1 ? "" : "s")"
        case let .rootAmbiguous(argument, matches):
            "\(argument) matches \(matches.count) paths in the logs — name one of \(matches.joined(separator: ", "))"
        }
    }

    private static func day(of date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // Gregorian and POSIX pinned as `TranscriptAudit` pins them: a machine preferring the Buddhist
        // calendar would otherwise date the window 2569 and make it untypeable back into `--since`.
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

public extension ReportData {
    /// What a `--root` argument came to.
    ///
    /// A refusal is carried rather than dropped, because dropping it produces the page's version of the defect the CLI face avoids by printing the refusal alone: a header that reads exactly as an unscoped, machine-wide report while the reason sits far below it, past a run caption that has helpfully picked one of the candidates.
    enum RootScope: Sendable, Equatable {
        /// The directory the argument named; every log-derived section is scoped to it.
        case resolved(String)

        /// It named no one directory — nothing below is scoped, and no section carries a number.
        case unresolved(argument: String)
    }

    /// One condition awaiting a human: which repository, what holds, and what to do about it.
    struct Condition: Sendable, Equatable {
        public let root: String

        /// The root's shortest unambiguous name among its peers — several roots on one machine can be called `app`.
        public let name: String

        public let headline: String
        public let fact: String
        public let action: String

        /// The command to run, kept separate from the prose so it can be copied rather than read.
        public let command: String
    }

    /// The index's share of the lookups that had a choice, and how it moved.
    ///
    /// Scoped by `--root` exactly as the calls above it are: a transcript joins this only when its recorded `cwd` places it inside the resolved root.
    struct Share: Sendable, Equatable {
        public let tally: TranscriptTally
        public let sessions: Int

        /// One row per day, oldest first, skipping days whose lookups all fell outside the choice.
        public let byDay: [DayShare]
    }

    /// One day's share.
    struct DayShare: Sendable, Equatable {
        public let day: String
        public let indexed: Int
        public let total: Int
        public let share: Int

        /// That share as it must be printed, floored exactly as the headline above the trend is floored.
        ///
        /// Carried rather than re-derived, because a bar drawn from `share` and labelled from a second reading of it is how a page comes to print a bare `0` over a visibly drawn bar, and `0% — 1 of 201` in its tooltip, on the same page as a headline reading `<1%`.
        public let shareText: String
    }

    /// One root's calls, and what fraction of the window they are.
    struct RootUse: Sendable, Equatable {
        public let root: String
        public let name: String
        public let calls: Int
        public let percent: Int
    }

    /// One `tool target` pair asked for repeatedly — what this codebase keeps being asked about.
    struct TargetUse: Sendable, Equatable {
        public let label: String
        public let count: Int
        public let days: [String]
    }
}
