//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A whole read the hook lets through standing alone — of a file whose whole digest this context holds, or that it wrote — still prints its source beside a cold read, so the line runs with the note naming the call for the cold one, rather than being denied with the digest the context already holds in place of the source it asked for.
@Suite(.temporaryDirectories)
struct HeldReadLineTests {
    /// The cold reads a held whole read sits beside: a window, a whole read, and a grep.
    private static let coldLegs = [
        "sed -n '5,40p' Sources/App/Other.swift",
        "cat Sources/App/Other.swift",
        "grep -rn part1 Sources",
    ]

    /// A whole read of a file whose whole digest this context holds, through either record of the digest, beside each cold read.
    @Test(arguments: [false, true])
    func aHeldDigestsWholeReadBesideAColdReadLetsTheLineRun(throughTheUsageLog: Bool) throws {
        for cold in Self.coldLegs {
            let fixture = try HeldWindowLineTests.fixture()
            if !throughTheUsageLog {
                fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
            }

            let judged = try HeldWindowLineTests.judged("cat Sources/App/Shell.swift; \(cold)", in: fixture, located: throughTheUsageLog)

            #expect(judged.line == "allowed\t\totherStatementsRun", "\(cold)")
            #expect(judged.json?.contains("permissionDecision") == false, "\(cold)")
        }
    }

    /// A whole read of a file this context wrote, beside each cold read.
    @Test
    func aWrittenFilesWholeReadBesideAColdReadLetsTheLineRun() throws {
        for cold in Self.coldLegs {
            let fixture = try HeldWindowLineTests.fixture()
            #expect(fixture.edit())

            let judged = try HeldWindowLineTests.judged("cat Sources/App/Shell.swift; \(cold)", in: fixture)

            #expect(judged.line == "allowed\t\totherStatementsRun", "\(cold)")
            #expect(judged.json?.contains("permissionDecision") == false, "\(cold)")
        }
    }

    /// The controls: the held read alone is let through under its own rule, a line of nothing but held whole reads is let through as one, and the cold reads alone are still answered.
    @Test
    func heldReadsWithNothingColdBesideThemAreJudgedAsBefore() throws {
        let digested = try HeldWindowLineTests.fixture()
        digested.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let written = try HeldWindowLineTests.fixture()
        #expect(written.edit())
        let both = try HeldWindowLineTests.fixture()
        both.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        both.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Other.swift"])

        #expect(try HeldWindowLineTests.judged("cat Sources/App/Shell.swift", in: digested).line == "allowed\t\talreadyDigested")
        #expect(try HeldWindowLineTests.judged("cat Sources/App/Shell.swift", in: written).line == "allowed\t\twritten")
        #expect(try HeldWindowLineTests.judged("cat Sources/App/Shell.swift; cat Sources/App/Other.swift", in: both).line == "allowed\t\talreadyDigested")
        #expect(try HeldWindowLineTests.judged("cat Sources/App/Other.swift", in: digested).line.hasPrefix("in-place\t"))
    }

    /// A line of reads let through where one file was only written by this context, not digested, is let through as a written read is, and notes no `alreadyDigested`: that note holds only where the context has every whole read's digest.
    @Test(arguments: ["cat Sources/App/Other.swift", "sed -n '1,200p' Sources/App/Other.swift"])
    func aWrittenFilesReadBesideADigestedOneIsNotNotedAsDigested(other: String) throws {
        let fixture = try HeldWindowLineTests.fixture()
        #expect(fixture.edit())
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Other.swift"])

        let judged = try HeldWindowLineTests.judged("cat Sources/App/Shell.swift; \(other)", in: fixture)

        #expect(judged.line == "allowed\t\twritten")
        #expect(judged.json == nil)
        let notes = try? String(contentsOf: fixture.stores.appendingPathComponent("suppressions.jsonl"), encoding: .utf8)
        #expect(notes?.contains("alreadyDigested") != true)
    }
}
