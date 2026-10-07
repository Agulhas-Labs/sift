//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import Testing

/// Every code a `sift run --without` can exit with is named where a script writer reads the list: the Guide's exit-code bullet and the command's own `--help`.
///
/// Derived from ``RunWithoutCommand/Exit`` plus the parser's usage error, which is what a line the command cannot prove anything with is refused as — so a code added to the enum, or the usage error left out of a list again, fails here rather than in a script that read the list as complete.
struct RunWithoutExitCodeDocsTests {
    /// The codes a `--without` or `--without-line` run exits with, other than an interruption's `128 + n`.
    static var codes: [Int32] {
        RunWithoutCommand.Exit.allCases.map(\.rawValue) + [ExitCode.validationFailure.rawValue]
    }

    /// The Guide's bullet on what a `--without` run exits with names every code, each in backticks.
    @Test
    func theGuidesExitBulletNamesEveryCode() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let guide = try String(contentsOf: root.appendingPathComponent("Docs/Guide.md"), encoding: .utf8)
        let section = try #require(guide.range(of: "### Proving a test fails without your change"))
        let bulletStart = try #require(guide.range(of: "- **The exit code is the answer's**", range: section.upperBound ..< guide.endIndex))
        let rest = guide[bulletStart.upperBound...]
        let bullet = rest[..<(rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex)]

        for code in Self.codes {
            #expect(bullet.contains("`\(code)`"), "the Guide's --without exit bullet does not name \(code): \(bullet)")
        }
    }

    /// `sift run --help` names every code in its sentence on what the proof exits with.
    @Test
    func theHelpNamesEveryCode() throws {
        let discussion = RunCommand.configuration.discussion
        let sentenceStart = try #require(discussion.range(of: "It exits 0 only when"))
        let sentence = discussion[sentenceStart.lowerBound...]

        for code in Self.codes {
            #expect(sentence.contains(" \(code) when") || sentence.contains(" \(code) only when"), "sift run --help does not say when a --without run exits \(code)")
        }
    }
}
