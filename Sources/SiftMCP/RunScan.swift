//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Reads `~/.sift/run.jsonl` — the wrapped toolchain runs — and narrows it to a window and a root.
///
/// **A parallel of ``UsageScan``, not an extension of it.** The two logs are deliberately separate files because they mean different things (index lookups against wrapped builds), and one parser over both would put that distinction back at risk the moment either grew a field: a run has no tool, no target and no measured byte pair, and a call has no exit code and no line counts. `--since` and `--root` are the same vocabulary, and the root is resolved *once* by ``LogScope`` against both logs' roots together and handed here already resolved, so a reader narrowing one narrows both to the same directory.
///
/// It reports absence rather than refusing. A missing log, an unreadable one, or a scope this log has never recorded a run under all yield a scan with no entries: a run log holding nothing for a real root is a fact rather than an error. A `--root` that names *no* directory never reaches here at all — resolution refuses before either log is scanned, so a run count can never be printed beneath a refusal to say which repository it is about.
public struct RunScan: Sendable {
    /// The runs inside the window and root asked for.
    public let entries: [Entry]

    /// Every readable run in the log before scoping, so "nothing here" can say what it is nothing out of.
    public let logged: Int

    /// Lines that were not JSON this understands.
    public let malformed: Int

    /// Reads `fileURL` and narrows it; anything unreadable renders as an empty scan.
    ///
    /// Asked to reach across worktrees, it widens a scope to every run filed under the same `repo` as a run inside it, or as the scope's own directory where that is a recorded root — the worktrees of the repositories it names, wherever they were cut. A line without `repo` is scoped by path alone. `flakes` alone asks for it: `usage` and `report` scope a lookup log beside this one with the same argument, and a lookup line carries no `repo` to widen by.
    public static func load(fileURL: URL, since: String? = nil, scope: LogScope? = nil, acrossWorktrees: Bool = false) -> RunScan {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return RunScan(entries: [], logged: 0, malformed: 0)
        }
        var parsed: [Entry] = []
        var malformed = 0
        for line in data.split(separator: 0x0A) {
            guard let entry = Entry(line: Data(line)) else {
                malformed += 1
                continue
            }
            parsed.append(entry)
        }

        // A run outside any repository records no root at all, so it can never answer a question scoped to
        // one — dropped rather than counted, the same way it would be if it had run somewhere else.
        let positions = scope?.positions(of: Set(parsed.compactMap(\.root)))
        let inPlace: (Entry) -> Bool = { entry in
            positions.map { inScope in entry.root.map { inScope[$0] != nil } ?? false } ?? true
        }
        let repositories = acrossWorktrees ? Self.repositories(of: parsed.filter(inPlace), scope: scope, positions: positions) : []
        let scoped = parsed.filter { entry in
            (since.map { entry.day >= $0 } ?? true)
                && (inPlace(entry) || entry.repository.map(repositories.contains) == true)
        }
        return RunScan(entries: scoped, logged: parsed.count, malformed: malformed)
    }

    /// The `repo` keys a scope stands for: every one its own runs recorded, and its directory's own where that directory is a recorded root, so a checkout whose lines all predate the field still reaches its worktrees' newer ones.
    ///
    /// The directory's own key is taken only while the directory is still the top of a work tree: `git` walks up to find a repository, so a recorded root that has lost its `.git` but sits inside another checkout would otherwise answer with that checkout's key and widen to its runs.
    private static func repositories(of inPlace: [Entry], scope: LogScope?, positions: [String: LogScope.Position]?) -> Set<String> {
        guard let scope else { return [] }
        var keys = Set(inPlace.compactMap(\.repository))
        let directory = URL(fileURLWithPath: scope.path)
        if positions?.values.contains(.exact) == true,
           let top = GitContext.spawnedRoot(from: directory), CanonicalPath.of(top.path) == CanonicalPath.of(scope.path),
           let own = RunUsageLog.repositoryKey(of: directory)
        {
            keys.insert(own)
        }
        return keys
    }

    /// What the runs in scope add up to, or `nil` when there are none.
    public var summary: Summary? {
        guard !entries.isEmpty else { return nil }
        let filtered = entries.compactMap(\.filtered)
        return Summary(
            runs: entries.count,
            kinds: Dictionary(grouping: entries, by: \.kind)
                .sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
                .map { KindCount(kind: $0.key, count: $0.value.count) },
            shown: filtered.reduce(0) { $0 + $1.shown },
            total: filtered.reduce(0) { $0 + $1.total },
            filteredRuns: filtered.count,
            nonzeroExits: entries.filter { $0.exitCode != 0 }.count,
            days: Set(entries.map(\.day)).sorted()
        )
    }
}

public extension RunScan {
    /// The line counts one filtered run kept and stood for.
    struct Filtered: Sendable, Equatable {
        public let shown: Int
        public let total: Int
    }

    /// Which tests one run recorded failing, and how many there were before the log's cap.
    ///
    /// A run that has one of these read its own output and knows the answer; a run that has none is unknown and is never to be read as a run where nothing failed. That is the distinction the whole per-test history rests on, so it is a type rather than a bare array — the two fields are one measurement, and either alone is a claim the other has to be there to support.
    struct Failures: Sendable, Equatable {
        /// The distinct names the run reported, sorted, as far as the log's cap allowed.
        public let named: [String]

        /// How many distinct names the run reported before the cap, which is `named.count` unless some were withheld.
        public let distinct: Int

        /// Whether every failing test in this run is named above.
        ///
        /// A run where it is `false` names some of its failures and withholds the rest, so it can say a test *did* fail and can never say one did not — which is a denominator it cannot be part of, and it is dropped from the tally rather than being allowed to contribute one half of a fraction.
        public var namesThemAll: Bool {
            named.count == distinct
        }
    }

    /// One parsed log line.
    struct Entry: Sendable, Equatable {
        /// How the run filed itself — `swift build`, `swift test`, `xcodebuild test`, or `unfiltered` for a passthrough.
        ///
        /// **Two shapes of `xcodebuild` key are on disk and both are permanent.** Newer lines name the action beside the tool; older ones, and any run whose action argv left in doubt, carry the bare word `xcodebuild` and say nothing about which of ten actions ran. Readers that count runs together must ask ``RunCommandKind/population(of:)`` rather than group on this string, which is the difference between a denominator and a number.
        public let kind: String

        public let exitCode: Int

        /// The repository the command ran in, or `nil` when it ran outside one.
        public let root: String?

        /// The key every worktree of the run's repository shares (``RunUsageLog/repositoryKey(of:)``), or `nil` for a line that recorded none.
        public let repository: String?

        /// The day the log filed this run under — the timestamp's UTC date, matching how `usage.jsonl` files a call.
        public let day: String

        public let milliseconds: Int

        /// `nil` for a passthrough, which filtered nothing and counted no lines.
        public let filtered: Filtered?

        /// Which tests this run recorded failing, or `nil` when it recorded nothing about them.
        ///
        /// **`nil` is unknown and never zero**, and the reason it has to survive the read is on disk: lines written before this field existed carry nothing here, and every one of them would otherwise report as a run in which no test failed — turning a log that cannot answer "has this failed before?" into one that answers it wrongly.
        public let failures: Failures?

        /// The content hash of the tree the run started on, or `nil` when the line recorded none.
        ///
        /// **`nil` is unknown and never a tree of its own**, for the reason `failures` is: every line written before the field existed carries nothing here, and grouping them as one tree would put years of different code behind a single key — the one reading that turns every deliberate red into a same-tree failure.
        public let tree: String?

        /// The digest of the command line the run was given and where, or `nil` when the line recorded none — and then the tree is not used either, since outcomes on one tree are compared only between runs given one command.
        public let invocation: String?

        /// One log line, or `nil` when it is not one this understands.
        init?(line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = object["kind"] as? String,
                  let timestamp = object["ts"] as? String
            else {
                return nil
            }
            self.kind = kind
            exitCode = object["exit"] as? Int ?? 0
            root = object["root"] as? String
            repository = (object["repo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            day = String(timestamp.prefix(10))
            milliseconds = object["ms"] as? Int ?? 0
            // Both or neither, matching how they are written: one half of the pair is not a measurement,
            // and a passthrough is an unfiltered run rather than one that suppressed nothing.
            filtered = (object["shown"] as? Int).flatMap { shown in
                (object["total"] as? Int).map { Filtered(shown: shown, total: $0) }
            }
            // Both or neither again, on the same reasoning: a list of names with no count beside it cannot
            // say whether it is the whole list, and a count with no names says nothing at all.
            failures = (object["failed"] as? [String]).flatMap { named in
                (object["failed_total"] as? Int).map { Failures(named: named, distinct: $0) }
            }
            tree = (object["tree"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            invocation = (object["invocation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// One command kind and how often it was wrapped.
    struct KindCount: Sendable, Equatable {
        public let kind: String
        public let count: Int
    }

    /// What the runs in scope add up to.
    ///
    /// Summed on both sides rather than averaged over per-run ratios, for the same reason ``UsageScan/Savings`` is: a mean would let a five-line run weigh as much as the five-thousand-line `xcodebuild` this exists for, and read as a worse result than the log holds.
    struct Summary: Sendable, Equatable {
        public let runs: Int
        public let kinds: [KindCount]
        public let shown: Int
        public let total: Int

        /// How many of the runs had a filter applied at all; a passthrough contributes to `runs` and to nothing else.
        public let filteredRuns: Int

        public let nonzeroExits: Int

        /// The distinct days these runs fall on, oldest first.
        public let days: [String]

        /// What the filtered runs printed as a percentage of the output they wrapped.
        public var percent: Int {
            total > 0 ? Int((Double(shown) / Double(total) * 100).rounded()) : 0
        }

        /// That percentage as it must be printed: something shown never renders as nothing shown.
        ///
        /// A filter can keep a few dozen lines of tens of thousands, and "run showed 0% of the output it wrapped" is a claim about a filter that prints nothing at all — which is the one thing it never does, since those few lines are why the runs were worth wrapping. Rounding is the right presentation of a share and 0 is the wrong presentation of a nonzero one, so the floor is stated rather than the rounding loosened: a reader who sees `<1%` knows both that it is small and that it is not none.
        public var percentText: String {
            percent == 0 && shown > 0 ? "<1%" : "\(percent)%"
        }

        public var suppressed: Int {
            max(0, total - shown)
        }

        /// The one sentence both faces state the filtering in, or `nil` when no run in scope was filtered.
        ///
        /// Stated with how many runs it was measured over for the reason the savings sentence is: an aggregate drawn from part of the log must never read as a claim about all of it.
        public var sentence: String? {
            guard filteredRuns > 0, total > 0 else { return nil }
            return "run showed \(percentText) of the output it wrapped "
                + "(measured over \(filteredRuns) of \(runs) run\(runs == 1 ? "" : "s"))"
        }
    }
}
