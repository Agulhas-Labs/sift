//
// Copyright © Agulhas Labs
//

import Foundation

/// Why an `xcodebuild -enumerate-tests` answer cannot be read as one plan's set of tests.
///
/// Every case is a **described failure** rather than a crash or a shrug: the enumeration is where a sharded run learns what it is supposed to see, so an answer that cannot be read has to stop the run with a sentence a human can act on. A run that guessed here would reconcile against the wrong inventory and call the result green.
public enum TestEnumerationError: Error, CustomStringConvertible, Sendable {
    /// The file is not the JSON document this reads, and what the decoder said about it.
    case unreadable(String)
    /// The enumeration reported errors of its own, in whatever spelling they arrived in.
    case reported([String])
    /// The document carried no test plan at all.
    case noTestPlan
    /// The document carried more than one test plan, and their names.
    case severalTestPlans([String])
    /// A test identifier that is not the `Target/Type/function()` shape enumeration was measured to print.
    case unreadableIdentifier(String)

    public var description: String {
        switch self {
        case let .unreadable(reason):
            "sift test could not read xcodebuild's test enumeration: \(reason). It is the set every count in the answer is reconciled against, so there is nothing safe to run without it."
        case let .reported(messages):
            "xcodebuild's test enumeration reported \(messages.count == 1 ? "an error" : "\(messages.count) errors"): \(messages.joined(separator: "; ")). The enumeration is the expected set, so a run against a partial one would report tests as missing that were never listed."
        case .noTestPlan:
            "xcodebuild's test enumeration named no test plan, so there is no expected set of tests to reconcile the run against. Check that the scheme has a test plan and that the build's `.xctestrun` is the one that was enumerated."
        case let .severalTestPlans(names):
            "xcodebuild's test enumeration named \(names.count) test plans (\(names.joined(separator: ", "))), and sift test runs one plan per run: shards that mixed plans would run a combination of targets on one device that no serial run ever exercised. Name the plan with --plan."
        case let .unreadableIdentifier(identifier):
            "xcodebuild's test enumeration listed `\(identifier)`, which is not the Target/Type/function() shape every enumerated test was measured to take. sift test counts individual tests, so an identifier it cannot split is one it cannot count."
        }
    }
}
