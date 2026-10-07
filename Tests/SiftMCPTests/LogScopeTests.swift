//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the rule one `--root` argument has to obey: it names one directory, for every log a command reads.
///
/// The two logs hold different sets of roots by construction, so resolving the same fragment separately against each let a single heading carry two repositories' numbers. Every test here is one of the three ways that showed.
@Suite(.temporaryDirectories)
struct LogScopeTests {
    // MARK: Fixtures

    private static func writeLines(_ lines: [String], named name: String) throws -> URL {
        let file = try TemporaryDirectory.make(name)
            .appendingPathComponent("\(name).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func callLog(roots: [String]) throws -> URL {
        try writeLines(roots.map { root in
            line(["tool": "digest", "target": "Widget", "root": root, "ms": 5, "ok": true, "ts": "2026-08-18T10:00:00Z"])
        }, named: "log-scope-usage")
    }

    private static func runLog(roots: [String]) throws -> URL {
        try writeLines(roots.map { root in
            line(["kind": "swift test", "exit": 0, "ms": 900, "shown": 4, "total": 200, "root": root, "ts": "2026-08-18T11:00:00Z"])
        }, named: "log-scope-run")
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    // MARK: One argument, one directory

    /// The defect itself: two checkouts of the same name, one known only to each log, put two repositories under one heading.
    ///
    /// The calls half resolved `Catalogue` to the only `Catalogue` *it* had seen and the runs half to the only one *it* had seen, so the header read `in /work/Catalogue` above a run row counting builds in `/personal/Catalogue`. Neither half was ambiguous on its own, which is exactly why nothing looked wrong.
    @Test
    func twoSameNamedCheckoutsAcrossTheTwoLogsAreOneRefusalListingBoth() throws {
        let calls = try Self.callLog(roots: ["/work/Catalogue"])
        let runs = try Self.runLog(roots: ["/personal/Catalogue"])

        let report = UsageReport.render(fileURL: calls, runFileURL: runs, root: "Catalogue")

        #expect(report.contains("Catalogue matches 2 paths in the logs — name one:"))
        #expect(report.contains("/personal/Catalogue"))
        #expect(report.contains("/work/Catalogue"))
        // And no figure survives the refusal — a count is a claim about a repository this has declined to name.
        #expect(!report.contains("runs (sift run"))
        #expect(!report.contains("usage — "))
    }

    /// Ambiguous to the calls, unambiguous to the runs: a runs half resolving on its own would guess, and print its guess underneath the refusal.
    @Test
    func aFragmentAmbiguousInTheCallLogRefusesForTheRunsToo() throws {
        let calls = try Self.callLog(roots: ["/work/Catalogue", "/personal/Catalogue"])
        let runs = try Self.runLog(roots: ["/personal/Catalogue"])

        let report = UsageReport.render(fileURL: calls, runFileURL: runs, root: "Catalogue")

        #expect(report.contains("name one:"))
        #expect(!report.contains("runs (sift run"))
        #expect(!report.contains("1 run"))
    }

    /// The mirror, and the quietest of the three: ambiguous to the runs alone, the whole section vanished — which reads as "no builds were wrapped" rather than "this cannot be answered".
    @Test
    func aFragmentAmbiguousInTheRunLogRefusesRatherThanVanishing() throws {
        let calls = try Self.callLog(roots: ["/work/Catalogue"])
        let runs = try Self.runLog(roots: ["/work/Catalogue", "/personal/Catalogue"])

        let report = UsageReport.render(fileURL: calls, runFileURL: runs, root: "Catalogue")

        #expect(report.contains("Catalogue matches 2 paths in the logs — name one:"))
        // No headline of any shape, whatever the fixture's counts: a refusal prints no figure at all.
        #expect(!report.contains("usage — "))
    }

    /// Unique across the union scopes both halves — including the half whose own log has never recorded that root, which is an empty section and not an unresolved one.
    @Test
    func aFragmentUniqueInTheUnionScopesBothHalves() throws {
        let calls = try Self.callLog(roots: ["/work/Catalogue/app"])
        let runs = try Self.runLog(roots: ["/work/Catalogue/app"])

        let report = UsageReport.render(fileURL: calls, runFileURL: runs, root: "Catalogue")

        #expect(report.contains("(under /work/Catalogue)"))
        #expect(report.contains("1 run, 2026-08-18 → 2026-08-18"))
    }

    /// A root only one log has seen still resolves, and the other's section reports its own honest silence.
    @Test
    func aRootRecordedInOnlyOneLogResolvesForBoth() throws {
        let calls = try Self.callLog(roots: ["/work/Catalogue"])
        let runs = try Self.runLog(roots: ["/work/Other"])

        let report = UsageReport.render(fileURL: calls, runFileURL: runs, root: "Catalogue")

        #expect(report.contains("usage — 0 failures, 1 call (in /work/Catalogue)"))
        // Nothing was wrapped in this repository, so there is no run section rather than a wrong one.
        #expect(!report.contains("runs (sift run"))
    }

    // MARK: What a refusal is allowed to print

    /// A machine-local path in a fixture, spelled with a home directory so the username is a thing the assertions can look for.
    private static let roots = [
        "/Users/hometester/Developer/Alpha/app",
        "/Users/hometester/Developer/Beta/app",
        "/Users/hometester/Developer/Solo",
    ]

    private static var redactor: Redactor {
        Redactor(salt: Data("log-scope-test-salt".utf8))
    }

    /// A refusal is part of the report, so it obeys the report's promise: no absolute path, and above all no username.
    ///
    /// The leak is not in the wording. `LogScope.resolve` runs before the redactor is consulted, so a message that took none would list every root either log holds, verbatim, for a mistyped `--root` — this machine's directory layout and its owner's name, printed under a `--help` line that says the report is pseudonymised so sharing it is safe. On a machine holding more than one person's checkouts that listing is another person's repository names.
    ///
    /// Asserted against a rendered report over a real log rather than against the shortening in isolation, because the failure is correct code in the wrong order, and only an actual answer can show the order.
    @Test
    func aRedactedRefusalNamesTheCandidatesWithoutNamingTheMachine() throws {
        let calls = try Self.callLog(roots: Self.roots)
        let runs = try Self.runLog(roots: Self.roots)

        let usage = UsageReport.render(fileURL: calls, runFileURL: runs, root: "zzznope", redactor: Self.redactor)
        let flakes = RunFailureHistoryReport.render(fileURL: runs, root: "zzznope", redactor: Self.redactor)

        for rendered in [usage, flakes] {
            #expect(!rendered.contains("hometester"))
            #expect(!rendered.contains("/Users/"))
            for root in Self.roots {
                #expect(!rendered.contains(root))
            }
            // What survives is the least a reader can retype — and no more of the path than that.
            #expect(rendered.contains("\n  Alpha/app"))
            #expect(rendered.contains("\n  Beta/app"))
            #expect(rendered.contains("\n  Solo"))
        }

        // `--unredact` is unchanged: the reader who asked for the paths still gets them.
        let unredacted = RunFailureHistoryReport.render(fileURL: runs, root: "zzznope", redactor: nil)

        #expect(unredacted.contains("/Users/hometester/Developer/Alpha/app"))
    }

    /// The ambiguous branch obeys the same rule, and what it offers is something this command accepts.
    ///
    /// The harder half of the promise, because here the reader has to pick one of the candidates: a listing shortened past the point where it resolves would be safe and useless. Each fragment is fed back through the resolution to prove it names the directory it was printed for.
    @Test
    func anAmbiguousRefusalOffersFragmentsTheCommandAccepts() throws {
        let calls = try Self.callLog(roots: Self.roots)

        let rendered = UsageReport.render(fileURL: calls, root: "app", redactor: Self.redactor)

        #expect(rendered.contains("app matches 2 paths in the logs — name one:"))
        #expect(rendered.contains("\n  Alpha/app"))
        #expect(rendered.contains("\n  Beta/app"))
        #expect(!rendered.contains("hometester"))

        for (fragment, directory) in [("Alpha/app", Self.roots[0]), ("Beta/app", Self.roots[1]), ("Solo", Self.roots[2])] {
            let resolved = try LogScope.resolve(fragment, among: Set(Self.roots)).get()
            #expect(resolved.path == directory)
        }
    }

    // MARK: Canonicalisation

    /// One directory reaching the two logs under two spellings is one directory.
    ///
    /// `run.jsonl` records `git rev-parse --show-toplevel` verbatim, `usage.jsonl` a path an agent supplied, and macOS volumes are case-insensitive by default — so the union can hold two entries for one repository, and the fragment matching both would refuse as ambiguous. Asked of the filesystem at comparison time, which heals the lines already written rather than only the next ones.
    @Test
    func twoSpellingsOfOneDirectoryAcrossTheTwoLogsResolveTogether() throws {
        let root = try TemporaryDirectory.make("log-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let shouted = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent.uppercased()).path
        try #require(FileManager.default.fileExists(atPath: shouted), "case-sensitive volume — nothing to fold")

        let calls = try Self.callLog(roots: [root.path])
        let runs = try Self.runLog(roots: [shouted])

        let report = UsageReport.render(fileURL: calls, runFileURL: runs, root: root.lastPathComponent, includeScratch: true)

        #expect(!report.contains("name one:"))
        #expect(report.contains("usage — 0 failures, 1 call"))
        #expect(report.contains("1 run, 2026-08-18 → 2026-08-18"))
    }

    /// A directory nothing is standing at still compares equal to itself, which is what every fixture path in this suite depends on.
    @Test
    func aRootThatIsNotOnDiskStillResolves() throws {
        let scope = try LogScope.resolve("/work/Catalogue", among: ["/work/Catalogue"]).get()

        #expect(scope.path == "/work/Catalogue")
        #expect(scope.positions(of: ["/work/Catalogue", "/work/Catalogue/app", "/work/Cataloguebook"])
            == ["/work/Catalogue": .exact, "/work/Catalogue/app": .below])
    }

    // MARK: Fixtures
}
