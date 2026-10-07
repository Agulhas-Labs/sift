//
// Copyright © Agulhas Labs
//

import Foundation

/// How a SwiftPM package's tests are read, partitioned by suite across shards, and selected for each shard's `swift test`.
///
/// **The unit is the suite, never the test.** A suite is what a `--filter` can name in one short anchored pattern, what `.serialized` orders and what shares fixture state, so splitting one across two processes would run its tests beside each other where the author asked for them one at a time. The tests stay the currency of the plan: each shard carries every test of its suites, so ``ShardMerge`` reconciles a package's run exactly as it reconciles a simulator run.
public struct PackageShardPlanner: Sendable {
    /// What a shard is charged for its own `swift test` launch and bundle load before its first test runs.
    public static let overheadSeconds: Double = 2

    /// The shards to run on this machine unless the caller says otherwise: a quarter of the performance cores, between 1 and 4.
    ///
    /// Low on purpose. Each shard's Swift Testing run is already parallel inside itself, and a package whose tests spawn processes loads the machine far past its core count on one process alone; what the shards buy is overlap between the runs one `swift test` makes one after another, and that is had at a handful.
    public static func defaultShardCount(performanceCores: Int) -> Int {
        max(1, min(performanceCores / 4, 4))
    }

    /// The type given to a test declared at file scope: a name no Swift type can have, so it is told apart from every suite and still makes the three-part identifier the reconciliation counts.
    public static var fileScopeType: String {
        "(file scope)"
    }

    /// The tests `swift test list` printed on its standard output, as identifiers: `Module.Outer/Inner/function` becomes `Module/Outer.Inner/function()`, the spelling every other identifier here has.
    ///
    /// **A line that names no test refuses the listing; it never drops out of it.** Every non-blank line is a test the run owes, so a line that cannot be read is a test the plan would give no shard, neither run nor counted missing, and the answer would be green short of it; the error names the line instead. XCTest lists a method without parentheses, and they are added so the identifier is one test's whichever framework declared it.
    ///
    /// A path is split on `/` only outside backticks, since a raw-identifier test such as `` `a//b`() `` holds slashes of its own. A Swift Testing function declared at file scope is listed as `Module.function()`, with no type, and is given ``fileScopeType``.
    public static func listed(_ output: String) throws -> [TestIdentifier] {
        var tests: [TestIdentifier] = []
        var unread: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                continue
            }
            if let test = identifier(listedAs: text) {
                tests.append(test)
            } else {
                unread.append(text)
            }
        }
        guard unread.isEmpty else {
            throw TestRunError.unreadableListing(unread)
        }
        return tests
    }

    /// The suites in `swift test list`'s `output` that Swift Testing alone declares: every test of theirs is listed with parentheses, which XCTest never prints.
    public static func swiftTestingSuites(listed output: String) -> Set<String> {
        var swiftTesting: Set<String> = []
        var xctest: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let test = identifier(listedAs: text) else {
                continue
            }
            if splitOutsideBackticks(text).last?.hasSuffix(")") == true {
                swiftTesting.insert(suite(of: test))
            } else {
                xctest.insert(suite(of: test))
            }
        }
        return swiftTesting.subtracting(xctest)
    }

    /// The name Swift Testing logs a raw-identifier test under, the text between its backticks in quotes — `` `a.b`() `` logs as `"a.b"` — or `nil` for a function named plainly.
    public static func rawIdentifierLogName(of test: TestIdentifier) -> String? {
        let function = test.function
        guard function.hasPrefix("`"), let close = function.dropFirst().firstIndex(of: "`") else {
            return nil
        }
        return "\"\(function[function.index(after: function.startIndex) ..< close])\""
    }

    /// The `@Test("…")` literals and the conditional tests `inventory` declares, each test named as ``listed(_:)`` names it, a file-scope one included.
    ///
    /// The inventory's own ``TestInventory/displayNames`` leaves a file-scope test out, since no enumeration names one; a package's listing does, so a file-scope test logging under its literal is joined here rather than reported missing over a run it passed.
    public static func declared(in inventory: TestInventory) -> (displayNames: [String: [TestIdentifier]], conditional: Set<TestIdentifier>) {
        var displayNames: [String: [TestIdentifier]] = [:]
        var conditional: Set<TestIdentifier> = []
        for test in inventory.tests {
            guard let identifier = listedIdentifier(of: test) else {
                continue
            }
            if let logName = test.logName {
                displayNames[logName, default: []].append(identifier)
            }
            if case .conditional = test.disposition {
                conditional.insert(identifier)
            }
        }
        return (displayNames.mapValues { $0.sorted { $0.enumerated < $1.enumerated } }, conditional)
    }

    /// The tests `inventory` declares that `listed` never named, in the modules `listed` names at least once, in identifier order.
    ///
    /// **A test the listing lost is one no shard runs.** `swift test list` goes through the relay that drops console lines under load, and each shard's stream declares only what its filter selected, so no stream sees a suite the listing lost whole — a file-scope test is a one-test suite — and the answer would be green short of it. The index declares it all the same, and does not come through that relay.
    ///
    /// Only the modules the listing named are owed, so another package's or an app's tests in the same repository are not. A declaration whose file no longer spells its function's name is passed over: a run reads the index as it stands and never freshens it, so a test renamed or deleted since the index was built is not owed.
    ///
    /// A test inside an `#if` is a candidate like any other: the index records every clause and cannot say which this build compiled, and one compiled out is missing from every listing, so ``confirmed(neverListed:listed:relisting:)`` drops it.
    public static func neverListed(declaredIn inventory: TestInventory, listed: [TestIdentifier], repositoryRoot: URL) -> [TestIdentifier] {
        let spelled = Set(listed.map(\.enumerated))
        let modules = Set(listed.map(\.moduleName))
        var sources: [String: String?] = [:]
        var owed: [TestIdentifier] = []
        for test in inventory.tests {
            guard let identifier = listedIdentifier(of: test), modules.contains(identifier.moduleName), !spelled.contains(identifier.enumerated) else {
                continue
            }
            if sources[test.path] == nil {
                sources[test.path] = try? String(contentsOf: repositoryRoot.appendingPathComponent(test.path), encoding: .utf8)
            }
            if let source = sources[test.path].flatMap(\.self), source.contains(test.function.prefix { $0 != "(" }) {
                owed.append(identifier)
            }
        }
        return owed.sorted { $0.enumerated < $1.enumerated }
    }

    /// How many more times the package is listed, at most, to confirm the never-listed candidates.
    public static let confirmingListings = 3

    /// The tests of `candidates` — those ``neverListed(declaredIn:listed:repositoryRoot:)`` found against `listed` — that a later listing, `relisting`, names: the ones the first listing lost.
    ///
    /// `complete` says whether a listing complete enough to rule any out was seen.
    ///
    /// **Losing a line is chance; leaving a test out of the build is not.** A test in a file its target excludes, or one the index still holds under a name since renamed, is missing from every listing, where the relay loses a line only now and then. So a candidate is dropped only where a listing that names every test `listed` named also lacks it, and every other listing lacked it too; one any listing names was compiled, and stays red.
    ///
    /// A listing is paid for only where there is a candidate. One that falls short of `listed` — the relay lost a line of it too, or it named nothing — is no evidence, and the package is listed again, up to ``confirmingListings`` times. One that fails — `relisting` answers `nil` — ends the confirmation, since running it again would fail the same way. Where no listing was complete, every candidate stands.
    public static func confirmed(
        neverListed candidates: [TestIdentifier],
        listed: [TestIdentifier],
        relisting: () throws -> [TestIdentifier]?
    ) rethrows -> (owed: [TestIdentifier], complete: Bool) {
        guard !candidates.isEmpty else {
            return ([], true)
        }
        let first = Set(listed.map(\.enumerated))
        var named: Set<String> = []
        for _ in 0 ..< confirmingListings {
            guard let relisted = try relisting() else {
                break
            }
            let spelled = Set(relisted.map(\.enumerated))
            named.formUnion(spelled)
            if !spelled.isEmpty, spelled.isSuperset(of: first) {
                return (candidates.filter { named.contains($0.enumerated) }, true)
            }
        }
        return (candidates, false)
    }

    /// The unit a test is partitioned by: its target and the outermost type declaring it, so a nested suite always travels with the suite around it, or the test itself where it was declared at file scope.
    ///
    /// A file-scope unit is spelled `Module.function()`, the prefix of Swift Testing's own identifier for that test, so ``filter(for:)`` anchors on the test alone and ``SuiteSpans`` keys its span the same way.
    public static func suite(of test: TestIdentifier) -> String {
        guard test.type != fileScopeType else {
            return "\(test.moduleName).\(test.function)"
        }
        let outermost = splitOutsideBackticks(test.type, on: ".").first ?? test.type
        return "\(test.moduleName).\(outermost)"
    }

    /// The clause of the answer's note that says how many shards ran and what they were cut from: `2 of 4 shards over 7 units`.
    ///
    /// A unit is what ``suite(of:)`` partitions by, a suite or a lone file-scope test, so the count is not called a suite count, and the word is shorter than the one it replaced.
    public static func shardsNote(shards: Int, requested: Int, tests: [TestIdentifier]) -> String {
        "\(shards) of \(requested) shard\(requested == 1 ? "" : "s") over \(Set(tests.map(suite(of:))).count) units"
    }

    /// Partitions `tests` by suite into at most `requested` shards, longest suite first onto the shard predicted to finish soonest.
    ///
    /// Every charge is in wall seconds. A suite's recorded span (``SuiteSpans``) was measured beside every other suite its process ran at once, so spans do not add up: a shard is predicted to run until the later of its longest span and the sum of its suites' shares of the wall clock, where a share divides each second among the suites still running then, as if the recorded runs had split them `count` ways. A suite with no span is charged by its framework. A Swift Testing suite (one of `swiftTestingSuites`) ran its tests beside each other, each clock counting the time it waited, so the longest of its clocks stands in for its span; summed, they can exceed the whole run many times over. An XCTest suite runs one test at a time and writes no event stream, so its tests' summed durations are wall time and are charged on top, capped at the longest span where one exists. A suite with neither is charged the median of the others on top. Ties are broken by suite name, so one inventory and one history always make one plan. The count is clamped to the number of suites and never lowered on estimates, since a split judged not to pay for itself is a judgement to make on measurements.
    public static func plan(
        tests: [TestIdentifier],
        shards requested: Int,
        displayNames: [String: [TestIdentifier]] = [:],
        conditional: Set<TestIdentifier> = [],
        swiftTestingSuites: Set<String> = [],
        duration: (TestIdentifier) -> Double?,
        suiteSeconds: (String) -> Double? = { _ in nil }
    ) -> ShardPlan {
        let bySuite = Dictionary(grouping: Set(tests), by: suite(of:))
        let count = max(1, min(requested, bySuite.count))
        let recorded = bySuite.keys.reduce(into: [String: Double]()) { spans, name in spans[name] = suiteSeconds(name) }
        let spans = bySuite.reduce(into: recorded) { spans, entry in
            if spans[entry.key] == nil, swiftTestingSuites.contains(entry.key), let longest = entry.value.compactMap(duration).max() {
                spans[entry.key] = longest
            }
        }
        let longestSpan = spans.values.max()
        let summed = bySuite.reduce(into: [String: Double]()) { summed, entry in
            let timed = entry.value.compactMap(duration)
            if spans[entry.key] == nil, !timed.isEmpty {
                summed[entry.key] = min(timed.reduce(0, +), longestSpan ?? .infinity)
            }
        }
        let shares = sharedSeconds(of: spans, shards: count)
        let fallback: Double = median(of: Array(shares.values) + Array(summed.values)) ?? 1
        let charged: [PackageShardLoad] = bySuite.keys.map { name in
            if let span = spans[name] {
                return PackageShardLoad(suites: [name], serialSeconds: 0, longestSpan: span, sharedSeconds: shares[name] ?? span)
            }
            return PackageShardLoad(suites: [name], serialSeconds: summed[name] ?? fallback, longestSpan: 0, sharedSeconds: 0)
        }
        let ordered = charged.sorted { left, right in
            left.seconds == right.seconds ? left.suites.lexicographicallyPrecedes(right.suites) : left.seconds > right.seconds
        }
        var bins = Array(repeating: PackageShardLoad(suites: [], serialSeconds: 0, longestSpan: 0, sharedSeconds: 0), count: count)
        for entry in ordered {
            bins[lightestBin(bins.map(\.seconds))].add(entry)
        }
        let shards = bins.enumerated().filter { !$0.element.suites.isEmpty }.map { offset, bin in
            ShardPlan.Shard(
                index: offset + 1,
                tests: bin.suites.flatMap { (bySuite[$0] ?? []).sorted { $0.enumerated < $1.enumerated } },
                predictedSeconds: overheadSeconds + bin.seconds
            )
        }
        return ShardPlan(
            shards: shards,
            requestedShards: requested,
            overheadSeconds: overheadSeconds,
            estimatedTests: 0,
            estimatedSeconds: fallback,
            displayNames: withRawIdentifierLogNames(displayNames, of: tests),
            conditional: conditional,
            lowering: nil
        )
    }

    /// The `swift test --filter` pattern that selects exactly the suites `tests` belong to, anchored at the start and closed by `/` or `.`, so a suite never selects another whose name merely begins with its own.
    ///
    /// Both frameworks match it against `Module.Type/function`, measured with SwiftPM 6.4: XCTest spells its tests that way, and Swift Testing's identifiers begin with the same prefix.
    public static func filter(for tests: [TestIdentifier]) -> String {
        let suites = Set(tests.map(suite(of:))).sorted()
        let alternatives = suites.map { NSRegularExpression.escapedPattern(for: $0) }
        return "^(?:" + alternatives.joined(separator: "|") + ")[/.]"
    }

    /// The sentence the answer owes about how the suites were charged, or `nil` where every suite had a recorded duration.
    public static func estimateNote(
        tests: [TestIdentifier],
        duration: (TestIdentifier) -> Double?,
        suiteSeconds: (String) -> Double? = { _ in nil }
    ) -> String? {
        let bySuite = Dictionary(grouping: Set(tests), by: suite(of:))
        let untimed = bySuite.filter { name, members in suiteSeconds(name) == nil && members.allSatisfy { duration($0) == nil } }.count
        guard untimed > 0 else {
            return nil
        }
        guard untimed < bySuite.count else {
            return "No suite has a recorded duration, so all \(bySuite.count) were charged alike and the partition is even by suite count; this run's timings are kept for the next one."
        }
        return "\(untimed) of \(bySuite.count) suites have no recorded duration and were charged the median of the timed suites."
    }

    /// The identifier ``listed(_:)`` gives the test `test` declares, a file-scope one included, or `nil` where no identifier can be made of it.
    static func listedIdentifier(of test: DeclaredTest) -> TestIdentifier? {
        let suite = test.suite.isEmpty ? fileScopeType : test.suite
        return TestIdentifier(enumerated: "\(TestIdentifier.moduleName(ofTarget: test.target))/\(suite)/\(test.function)")
    }

    /// One listed line's identifier, or `nil` where the line is not the shape `swift test list` prints a test in.
    static func identifier(listedAs text: String) -> TestIdentifier? {
        let segments = splitOutsideBackticks(text)
        guard let head = segments.first, let dot = head.firstIndex(of: "."), segments.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        let module = String(head[..<dot])
        let path = [String(head[head.index(after: dot)...])] + segments.dropFirst()
        guard !module.isEmpty, !module.contains(" "), !module.contains("`"), let function = path.last, !function.isEmpty else {
            return nil
        }
        guard path.count > 1 else {
            let isFunction = function.contains("(") && function.hasSuffix(")")
            return isFunction ? TestIdentifier(target: module, type: fileScopeType, function: function) : nil
        }
        let type = path.dropLast().joined(separator: ".")
        let spelled = function.contains("(") ? function : "\(function)()"
        return TestIdentifier(target: module, type: type, function: spelled)
    }

    /// `text` split on every `separator` (a `/` unless said otherwise) that stands outside a pair of backticks, empty pieces kept.
    static func splitOutsideBackticks(_ text: String, on separator: Character = "/") -> [String] {
        var pieces = [""]
        var quoted = false
        for character in text {
            if character == "`" {
                quoted.toggle()
            }
            if character == separator, !quoted {
                pieces.append("")
            } else {
                pieces[pieces.count - 1].append(character)
            }
        }
        return pieces
    }

    /// `displayNames` with every raw-identifier test among `tests` joined under the quoted name its log uses, so a raw-identifier test that ran is not reported missing.
    private static func withRawIdentifierLogNames(_ displayNames: [String: [TestIdentifier]], of tests: [TestIdentifier]) -> [String: [TestIdentifier]] {
        var names = displayNames
        for test in Set(tests) {
            guard let name = rawIdentifierLogName(of: test), !(names[name] ?? []).contains(test) else {
                continue
            }
            names[name, default: []].append(test)
        }
        return names.mapValues { $0.sorted { $0.enumerated < $1.enumerated } }
    }

    /// Each spanned suite's share of the wall clock, its span divided among the suites still running at each moment of it, as if they had all started together and been split `shards` ways.
    ///
    /// The shares of suites that ran in one process add up to that process's wall clock, where their spans add up to many times it; a suite still running once fewer than `shards` suites are left has each remaining second to itself.
    private static func sharedSeconds(of spans: [String: Double], shards: Int) -> [String: Double] {
        let ordered = spans.sorted { left, right in left.value == right.value ? left.key < right.key : left.value < right.value }
        var shares: [String: Double] = [:]
        var accrued = 0.0
        var reached = 0.0
        for (offset, entry) in ordered.enumerated() {
            let running = Double(ordered.count - offset) / Double(shards)
            accrued += (entry.value - reached) / max(1, running)
            reached = entry.value
            shares[entry.key] = accrued
        }
        return shares
    }

    /// The index of the least loaded bin, the lowest index among equals.
    private static func lightestBin(_ loads: [Double]) -> Int {
        var best = 0
        for index in loads.indices where loads[index] < loads[best] {
            best = index
        }
        return best
    }

    private static func median(of seconds: [Double]) -> Double? {
        guard !seconds.isEmpty else {
            return nil
        }
        let sorted = seconds.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
