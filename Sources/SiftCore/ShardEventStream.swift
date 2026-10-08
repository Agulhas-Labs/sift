//
// Copyright © Agulhas Labs
//

import Foundation

/// How each Swift Testing test of a SwiftPM package's shard ended, read from the event stream that shard wrote rather than from its console.
///
/// **The stream is the record, the console a relay of it.** `swift test` runs `swiftpm-testing-helper` on pipes of its own and relays what it prints, and under load whole `✔ Test … passed` lines go missing on the way, so a console reading reports tests that ran as missing. The stream is written to a file by the testing library itself, and it carried every ending a lossy console dropped.
///
/// A test ended where the stream has its `testEnded`, or was skipped where it has its `testSkipped`, and it failed where an `issueRecorded` for it in that iteration says `isFailure` — which a known issue and a warning do not. A failing issue for a test that never started, was never skipped and never ended is a failure too: it is what a `.enabled(if:)` condition that threw leaves, its own or its suite's, and nothing else in the stream or the console says that test ran. One that started and never ended stays missing, since that is a test cut short, whichever iteration its failing issue carries. Only tests the stream declares as functions are read: a suite ends too, and is not a test.
///
/// **A parameterised test repeats by case, not as a whole.** Asked to repeat, the testing library starts and ends such a test once, with no iteration, and numbers only its cases' starts, ends and issues, where a plain test's own start and end are numbered too. So an unnumbered ending stands for one attempt per iteration the test's numbered events reached since its previous unnumbered ending, iteration 1 always among them: each fails where a failing issue carries its iteration, and iteration 1 carries the time from the test's one start to its one end, which spans every iteration. With the last attempt as the outcome, that is right for repeating until a pass, where every case still failing runs on to the last iteration; it is not for repeating until a failure, where one case can fail early while another passes on to the last, and nothing here passes that option.
public struct ShardEventStream: Sendable, Equatable {
    /// Every test the stream declared as a function, the tests it is the record for.
    public private(set) var declared: Set<TestIdentifier> = []

    /// Every ending each declared test reached, in the order the stream wrote them, each timed from its own start on the stream's one clock.
    public private(set) var attempts: [TestIdentifier: [RunTestOutcomes.Attempt]] = [:]

    /// The stream's identifiers for functions it ended that no listed spelling could be read from, so a caller can name them rather than drop them.
    public private(set) var unreadable: [String] = []

    /// The message of the failing issue each declared test recorded without ever starting — a condition or trait that threw — which the stream is the only record of: the console prints its line in a form its filter does not read.
    public private(set) var failedBeforeStarting: [TestIdentifier: String] = [:]
    /// The name the console prints for each declared test: its display name in quotes where it has one, and its function's name otherwise.
    public private(set) var printedNames: [TestIdentifier: String] = [:]
    /// The identifier of every test function the stream declared, verbatim with its `/File.swift:line:column` location, which is part of what a `--filter` pattern is matched against.
    ///
    /// A suite's is not among them: a pattern only its suite's id matches, `AlphaSuite$`, runs none of its tests.
    public private(set) var recordedIDs: Set<String> = []
    /// Where each test function the stream started and never ended, in any iteration, was declared: the tests a process that died was running.
    public private(set) var unfinishedSources: [DeclaredTestSource] = []

    public init() {}

    /// The endings `stream`, one JSON record a line, carries; a line that is not a record this reads is passed over.
    public static func read(_ stream: String) -> ShardEventStream {
        var functions: [String: TestIdentifier?] = [:]
        var printed: [TestIdentifier: String] = [:]
        var recorded: Set<String> = []
        var starts: [String: Double] = [:]
        var started: Set<String> = []
        var reachedSinceEnding: [String: Set<Int>] = [:]
        var failing: Set<String> = []
        var failingInOrder: [(id: String, iteration: Int)] = []
        var messages: [String: String] = [:]
        var ends: [String: Double] = [:]
        var skipped: Set<String> = []
        var endings: [(id: String, iteration: Int)] = []
        var sites: [DeclaredTestSource.Site] = []
        var running: [String: String] = [:]
        for line in stream.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else {
                continue
            }
            if object["kind"] as? String == "test" {
                sites += [DeclaredTestSource.Site(payload)].compactMap(\.self)
                if payload["kind"] as? String == "function", let id = payload["id"] as? String {
                    recorded.insert(id)
                    let test = identifier(of: id)
                    functions[id] = test
                    if let test, let name = (payload["displayName"] as? String).map({ "\"\($0)\"" }) ?? payload["name"] as? String {
                        printed[test] = name
                    }
                }
                continue
            }
            guard object["kind"] as? String == "event", let id = payload["testID"] as? String else {
                continue
            }
            // A parameterised test's own start and end carry no iteration while its cases' events do, so an absent one is the first.
            let numbered = payload["iteration"] as? Int
            let iteration = numbered ?? 1
            let kind = payload["kind"] as? String
            var iterations = [iteration]
            if let numbered {
                reachedSinceEnding[id, default: []].insert(numbered)
            } else if kind == "testEnded" || kind == "testSkipped" {
                iterations = (reachedSinceEnding.removeValue(forKey: id) ?? []).union([1]).sorted()
            }
            let instant = (payload["instant"] as? [String: Any])?["absolute"] as? Double
            switch kind {
            case "testStarted":
                starts[key(id, iteration)] = instant
                started.insert(id)
                running[key(id, iteration)] = id
            case "issueRecorded":
                let issue = payload["issue"] as? [String: Any]
                if issue?["isFailure"] as? Bool ?? !(issue?["isKnown"] as? Bool ?? false), failing.insert(key(id, iteration)).inserted {
                    failingInOrder.append((id: id, iteration: iteration))
                    messages[key(id, iteration)] = ((payload["messages"] as? [[String: Any]])?.first?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
            case "testEnded":
                ends[key(id, iteration)] = instant
                endings += iterations.map { (id: id, iteration: $0) }
                iterations.forEach { running[key(id, $0)] = nil }
            case "testSkipped":
                skipped.formUnion(iterations.map { key(id, $0) })
                endings += iterations.map { (id: id, iteration: $0) }
                iterations.forEach { running[key(id, $0)] = nil }
            default:
                break
            }
        }
        // A failing issue is the only trace of a test whose condition threw; one that started is a test cut short, and stays missing.
        let reached = started.union(endings.map(\.id))
        let unstarted = failingInOrder.filter { !reached.contains($0.id) }
        endings += unstarted
        var read = ShardEventStream()
        read.declared = Set(functions.values.compactMap(\.self))
        read.printedNames = printed
        read.recordedIDs = recorded
        read.unfinishedSources = DeclaredTestSource.stretches(of: Set(running.values), among: sites)
        for failure in unstarted {
            if let listed = functions[failure.id], let test = listed, read.failedBeforeStarting[test] == nil {
                read.failedBeforeStarting[test] = messages[key(failure.id, failure.iteration)] ?? "recorded a failing issue without starting"
            }
        }
        for ending in endings {
            guard let listed = functions[ending.id] else {
                continue
            }
            guard let test = listed else {
                if !read.unreadable.contains(ending.id) {
                    read.unreadable.append(ending.id)
                }
                continue
            }
            let key = key(ending.id, ending.iteration)
            let outcome: RunTestOutcomes.Ending = skipped.contains(key) ? .skipped : failing.contains(key) ? .failed : .passed
            var seconds: Double?
            if outcome != .skipped, let start = starts[key], let end = ends[key] {
                seconds = max(0, end - start)
            }
            read.attempts[test, default: []].append(RunTestOutcomes.Attempt(ending: outcome, seconds: seconds, iteration: ending.iteration))
        }
        return read
    }
}

private extension ShardEventStream {
    /// One attempt's key: a test's stream identifier within one iteration.
    static func key(_ id: String, _ iteration: Int) -> String {
        "\(iteration) \(id)"
    }

    /// The listed identifier of a stream identifier, which is `swift test list`'s spelling followed by `/File.swift:line:column`.
    static func identifier(of id: String) -> TestIdentifier? {
        // The location is the last component, and a file name holds no `/`, so a raw identifier's own slashes stay in the spelling before it.
        guard let slash = id.lastIndex(of: "/") else {
            return nil
        }
        return PackageShardPlanner.identifier(listedAs: String(id[..<slash]))
    }
}
