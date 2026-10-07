//
// Copyright © Agulhas Labs
//

import Foundation

/// What each suite of a SwiftPM package's shard cost on the wall clock, read from the Swift Testing event stream that shard wrote.
///
/// **A span, never a sum.** Swift Testing's `passed after` is each test's own clock, and under its in-process parallelism that clock includes the time a test spent waiting for a thread, so a suite's summed test times can exceed the whole run's wall clock many times over. The event stream stamps every test's start and end on one clock, and the span from a suite's first start to its last end is what the suite held the process for.
///
/// **Swift Testing only.** XCTest writes nothing to the stream; its tests run one after another in the process, so their own durations are already wall time, and a suite with no span is charged those instead.
public struct SuiteSpans: Sendable {
    /// The options a `swift test` that knows the event stream spells it with, newest first.
    public static let outputOptions = ["--event-stream-output-path", "--experimental-event-stream-output"]

    /// The key a suite's span is kept under in ``TestDurationStore``, apart from every test identifier, which always carries a `/`.
    public static func storeKey(for suite: String) -> String {
        "suite \(suite)"
    }

    /// The event-stream option `help` names, or `nil` where this `swift test` offers none.
    ///
    /// Asked of `swift test --help-hidden` rather than assumed, because the option was renamed between toolchains and an option `swift test` does not know fails every shard it is given to.
    public static func outputOption(inHelp help: String) -> String? {
        outputOptions.first { option in
            help.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(option + " ") }
        }
    }

    /// Each suite's span in `stream`, keyed as ``PackageShardPlanner/suite(of:)`` names a suite, from the first test start to the last test end.
    ///
    /// A line that is not a `testStarted` or `testEnded` event with an instant is skipped, and a suite with no end is given no span, since a span cut short would record a lost run as a cheap one.
    public static func read(_ stream: String) -> [String: Double] {
        var starts: [String: Double] = [:]
        var ends: [String: Double] = [:]
        for line in stream.split(whereSeparator: \.isNewline) {
            if let start = event(in: line, kind: "testStarted") {
                starts[start.suite] = min(starts[start.suite] ?? start.instant, start.instant)
            } else if let end = event(in: line, kind: "testEnded") {
                ends[end.suite] = max(ends[end.suite] ?? end.instant, end.instant)
            }
        }
        return starts.reduce(into: [:]) { spans, entry in
            if let end = ends[entry.key], end >= entry.value {
                spans[entry.key] = end - entry.value
            }
        }
    }
}

private extension SuiteSpans {
    /// The suite a `kind` event on `line` belongs to and when it happened on the stream's monotonic clock, or `nil` where the line is not that event.
    static func event(in line: Substring, kind wanted: String) -> (suite: String, instant: Double)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["kind"] as? String == "event",
              let payload = object["payload"] as? [String: Any],
              payload["kind"] as? String == wanted,
              let identifier = payload["testID"] as? String,
              let instant = (payload["instant"] as? [String: Any])?["absolute"] as? Double
        else {
            return nil
        }
        // `Module.Outer/Inner/function()/File.swift:7:10`: everything before the first `/` outside backticks is the outermost suite, qualified by its module, which is the partition's unit.
        let suite = PackageShardPlanner.splitOutsideBackticks(identifier).first ?? identifier
        guard suite.contains(".") else {
            return nil
        }
        return (suite: suite, instant: instant)
    }
}
