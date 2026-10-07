//
// Copyright © Agulhas Labs
//

/// The refusals the sequence itself owns — the ones no part it calls is in a position to say.
public enum TestRunError: Error, CustomStringConvertible, Sendable {
    /// The build wrote no `.xctestrun` this run could have run, with the file names that were there.
    case noXCTestRun([String])

    /// The build wrote more than one `.xctestrun` and nothing says which plan to run, with the file names that were there.
    case severalXCTestRuns([String])

    /// The enumeration wrote nothing this run could read as its expected set.
    case unreadableEnumeration(String)

    /// `swift test list` printed lines naming no test this run can read, each as printed, so its expected set would be short of whatever they name.
    case unreadableListing([String])

    /// The run was ended by its caller — a signal, or a cancellation from another thread.
    case interrupted

    /// A SwiftPM package's run was ended by its caller, which has shards to end and no devices.
    case packageRunInterrupted

    public var description: String {
        switch self {
        case let .noXCTestRun(found):
            "the build wrote no .xctestrun file this run began — \(TestRunError.listed(found)) — so there is nothing to run the tests from"
        case let .severalXCTestRuns(found):
            "the build wrote \(found.count) .xctestrun files — \(TestRunError.listed(found)) — and one run runs one plan: name it with --plan"
        case let .unreadableEnumeration(detail):
            "the enumeration wrote nothing this run could read as its expected set: \(detail)"
        case let .unreadableListing(lines):
            "swift test list --skip-build printed \(lines.count == 1 ? "a line" : "\(lines.count) lines") naming no test this run can read, the first `\(lines.first ?? "")`, so the run is refused rather than answered short of \(lines.count == 1 ? "it" : "them")"
        case .interrupted:
            "the run was interrupted, so its shards were ended and its devices deleted rather than waited on"
        case .packageRunInterrupted:
            "the run was interrupted, so its shards were ended rather than waited on"
        }
    }

    /// What was in the products directory, as a refusal states it — every name, since the reader's next step is to look at them.
    private static func listed(_ names: [String]) -> String {
        names.isEmpty ? "the products directory held no files at all" : names.sorted().joined(separator: ", ")
    }
}
