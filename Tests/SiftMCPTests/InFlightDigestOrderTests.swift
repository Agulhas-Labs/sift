//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole read of a file whose digest is in flight is held back, and one whose digest has its result written is let through as already digested, whether or not `git` answers in time.
@Suite(.temporaryDirectories)
struct InFlightDigestOrderTests {
    private static var digestID: String {
        "toolu_digest"
    }

    private static var digestUse: String {
        #"{"isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(digestID)","name":"mcp__sift__digest","input":{"target":"Shell"},"caller":{"type":"direct"}}]}}"#
    }

    private static var digestResult: String {
        #"{"isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(digestID)","type":"tool_result","content":"Shell — Sources/App/Shell.swift:2"}]}}"#
    }

    /// A `git` that never answers in time, as one on a loaded machine does not.
    private static let gitFailing = RootDiscovery(discover: { _ in nil })

    private func wholeRead(of fixture: InFlightPointerTests.Fixture, sourceLocation: SourceLocation = #_sourceLocation) async throws -> PreToolUseCommand.Lookup {
        let file = fixture.repo.appendingPathComponent("Sources/App/Shell.swift").path
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        return \($0)\n    }" }.joined(separator: "\n")
        try ("struct Shell {\n" + members + "\n}\n").write(toFile: file, atomically: true, encoding: .utf8)
        try await SiftEngine(directory: fixture.repo, registry: nil).ensureFresh()
        return try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Read", "tool_input": ["file_path": file]],
            in: fixture.repo.path,
            noting: SuppressionLog(fileURL: fixture.suppressionsURL),
            couldAnswer: { _, _ in true }
        ), sourceLocation: sourceLocation)
    }

    private func verdict(lines: [String], gitAnswers: Bool, after seconds: TimeInterval = 0) async throws -> PreToolUseCommand.Verdict {
        let fixture = try InFlightPointerTests.Fixture(lines: lines)
        fixture.take(tool: "\(IndexToolName.prefix)digest", input: ["target": "Shell"], id: Self.digestID)
        let read = try await wholeRead(of: fixture)
        guard !gitAnswers else { return fixture.judge(read, after: seconds) }
        return RootDiscovery.$current.withValue(Self.gitFailing) { fixture.judge(read, after: seconds) }
    }

    @Test(arguments: [true, false])
    func aDigestInFlightHoldsAWholeReadWhetherOrNotGitAnswers(gitAnswers: Bool) async throws {
        let held = try await verdict(lines: [Self.digestUse], gitAnswers: gitAnswers)

        #expect(held.token == "held", "\(held.line)")
        #expect(held.rule == "inFlight")
    }

    @Test(arguments: [true, false])
    func aDigestWithItsResultWrittenLetsAWholeReadThroughWhetherOrNotGitAnswers(gitAnswers: Bool) async throws {
        let allowed = try await verdict(lines: [Self.digestUse, Self.digestResult], gitAnswers: gitAnswers)

        #expect(allowed.token == "allowed", "\(allowed.line)")
        #expect(allowed.rule == "alreadyDigested")
    }

    /// The fixture's clock, not the machine's, decides whether a digest is still in flight: judged past the window, a digest with no result written lets the whole read through as already digested, however quickly the test ran.
    @Test
    func aDigestJudgedPastTheInFlightWindowLetsAWholeReadThroughOnTheFixturesClock() async throws {
        let late = try await verdict(lines: [Self.digestUse], gitAnswers: true, after: AdviceLedger.inFlightWindow + 1)

        #expect(late.token == "allowed", "\(late.line)")
        #expect(late.rule == "alreadyDigested")
    }
}
