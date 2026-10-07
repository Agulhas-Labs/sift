//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers reading a floor verdict for a named file out of the answer the hook serves in place of a read.
///
/// The fixtures' opening lines are copied from real in-place answers, with only a private tree name made neutral: the freshness line such an answer leads with, and the guessed-module banner and blank line it can carry under that.
struct FileVerdictTests {
    private static var freshness: String {
        "tree: repo  head: unborn  dirty: 2  parse_errors: 0  semantic: syntactic-only"
    }

    private static let banner = "⚠ module guessed — no build file declares: Sources/App/Depot.swift — `digest <Module>` and `Module.Type` are wrong for them. "
        + "No query can fix this, and no build file this tool reads (SwiftPM, XcodeGen, .xcodeproj) declares them — "
        + "if they do belong to a target, tell the user to run `sift init` here and take its `moduleMap` proposals."

    private static var servedNote: String {
        "(20 lines; a digest of 1 declaration over 17 lines of code summarises little the source does not say, so the source itself follows)"
    }

    /// A single file's answer opening on its freshness line still yields the file's verdict.
    @Test
    func aVerdictIsReadBehindTheFreshnessLine() {
        let answer = [Self.freshness, "Sources/App/Depot.swift — module: App", "", "struct Depot — 40 members  :2-203"].joined(separator: "\n")

        let verdict = SourcePassthrough.fileVerdict(in: answer, of: "Sources/App/Depot.swift")

        #expect(verdict == SourcePassthrough.FileVerdict(path: "Sources/App/Depot.swift", servedSource: false))
    }

    /// A shared answer under a freshness line and a guessed-module banner yields both files' verdicts, the first part's included.
    @Test
    func everyPartsVerdictIsReadBehindTheBanner() {
        let answer = [
            Self.freshness,
            Self.banner,
            "",
            "Sources/App/Depot.swift — module: Sources",
            "",
            "struct Depot — 40 members  :2-203",
            "",
            "\(SourcePassthrough.partMarker)Sources/App/Alpha.swift — module: Sources",
            Self.servedNote,
            "struct Alpha {",
            "}",
        ].joined(separator: "\n")

        #expect(SourcePassthrough.fileVerdict(in: answer, of: "Sources/App/Depot.swift") == SourcePassthrough.FileVerdict(path: "Sources/App/Depot.swift", servedSource: false))
        #expect(SourcePassthrough.fileVerdict(in: answer, of: "Sources/App/Alpha.swift") == SourcePassthrough.FileVerdict(path: "Sources/App/Alpha.swift", servedSource: true))
    }

    /// A header-shaped line inside the first part's body is not the top of an answer, however near the top it sits.
    @Test
    func aLookAlikeHeaderUnderTheFirstPartCreditsNothing() {
        let answer = [Self.freshness, "Sources/App/Depot.swift — module: App", Self.servedNote, "Sources/App/Alpha.swift — module: App"].joined(separator: "\n")

        #expect(SourcePassthrough.fileVerdict(in: answer, of: "Sources/App/Alpha.swift") == nil)
    }
}
