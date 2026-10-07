//
// Copyright © Agulhas Labs
//

/// What a finished sharded run hands back: the one text to print and the one code to exit with.
///
/// The answer is already rendered here rather than left as a report for the caller to render, because every ending this run has — a refusal, a failed build, an interruption, a reconciliation — is answered in the same shape, and a front end that rendered them would be a second place that shape is decided.
public struct TestRunResult: Sendable {
    /// The whole answer, ready to print.
    public let answer: String

    /// What `sift test` exits with.
    public let exitCode: Int32

    public init(answer: String, exitCode: Int32) {
        self.answer = answer
        self.exitCode = exitCode
    }
}
