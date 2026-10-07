//
// Copyright © Agulhas Labs
//

import Foundation

/// What a `swift test` run's event stream adds to the console's account of it: the Swift Testing endings the console lost, the failing tests it relayed no line of, and the one line that says the two disagreed.
///
/// **The stream is the record, the console a relay of it.** SwiftPM relays `swiftpm-testing-helper`'s output, and under load whole `✔ Test … passed` and `✘ Test …` lines go missing on the way; the stream is written by the testing library itself and kept every ending (see ``ShardEventStream``). The console is still read for everything else, the failure messages above all.
///
/// **Nothing where the two agree.** Where the console relayed as many Swift Testing endings as the stream recorded, the answer is the console's alone and carries no line about the stream, so a run that lost nothing reads exactly as it did without one.
///
/// **Nothing for a repeated run.** Asked to repeat (`--maximum-repetitions`, `--repeat-until`), the testing library starts a test once per iteration and prints one ending for it, while the stream ends it in every iteration: two tests repeated three times stream six endings and print two. Counted against each other the two always disagree, so a stream that ended any test past its first iteration is not folded, and a repeated run's answer is the console's alone.
struct RunEventStreamFold {
    /// Each ending to record that the console never relayed, under the name the console prints for its test.
    let endings: [(name: String, attempt: RunTestOutcomes.Attempt)]

    /// Every test the stream ended failing that the console named nowhere, by the name the console prints for it.
    let failedNames: [String]

    /// The message of the failing issue each test that failed without starting recorded — a condition that threw — by the name the console prints for it: the console's own line for it is not one the filter reads, so the stream's message is the only one the answer has.
    let messages: [String: String]

    /// The line the answer carries: how many endings each recorded, and which the counts are read from.
    let note: String

    /// The fold of `stream` into what the console relayed as `outcomes`, where `named` holds every test the console already named failing; `nil` where the two agree, or where the stream cannot be matched to the console at all.
    static func of(_ stream: ShardEventStream, console outcomes: RunTestOutcomes, named: Set<String>) -> RunEventStreamFold? {
        // A stream that declared nothing is an XCTest-only run's, and one holding an ending no name could be read for cannot be counted against the console test for test.
        guard !stream.declared.isEmpty, stream.unreadable.isEmpty else {
            return nil
        }
        guard stream.attempts.values.allSatisfy({ $0.allSatisfy { $0.iteration == 1 } }) else {
            return nil
        }
        var streamed: [String: [RunTestOutcomes.Attempt]] = [:]
        var failing: Set<String> = []
        var messages: [String: String] = [:]
        for test in stream.attempts.keys.sorted(by: { $0.enumerated < $1.enumerated }) {
            let attempts = stream.attempts[test] ?? []
            // Two suites' tests can print the same name, so the counts below are compared name by name, never test by test.
            let name = stream.printedNames[test] ?? test.function
            streamed[name, default: []].append(contentsOf: attempts)
            if RunTestOutcomes.lastAttempt(of: attempts)?.ending == .failed {
                failing.insert(name)
            }
            if let message = stream.failedBeforeStarting[test], messages[name] == nil {
                messages[name] = message
            }
        }
        let recorded = streamed.values.reduce(0) { $0 + $1.count }
        let relayed = outcomes.swiftTestingNames.reduce(0) { $0 + (outcomes.attempts[$1]?.count ?? 0) }
        guard recorded != relayed else {
            return nil
        }
        let counts = "event stream: \(recorded) Swift Testing \(recorded == 1 ? "ending" : "endings"), the console relayed \(relayed)"
        guard recorded > relayed else {
            return RunEventStreamFold(endings: [], failedNames: [], messages: [:], note: "\(counts) — the tests and failures here are the console's")
        }
        let endings = streamed.keys.sorted().flatMap { name in
            (streamed[name] ?? []).dropFirst(outcomes.attempts[name]?.count ?? 0).map { (name: name, attempt: $0) }
        }
        return RunEventStreamFold(
            endings: endings,
            failedNames: failing.subtracting(named).sorted(),
            messages: messages,
            note: "\(counts) — the other \(recorded - relayed) read from the stream"
        )
    }
}
