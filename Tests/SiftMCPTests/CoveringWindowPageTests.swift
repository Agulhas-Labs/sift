//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Pins that a window covering a file whose whole digest is over the size budget is answered the page a whole read of it is.
@Suite(.temporaryDirectories)
struct CoveringWindowPageTests {
    private static var target: String {
        "Sources/App/Paged.swift"
    }

    /// A repository whose one file runs to 484 lines and 40 kB, its whole digest past the size budget, so a whole read of it is served its first page cut to fit.
    private static func pagedRepository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let long = (1 ... 10).map { index in
            "    func long\(index)() -> Int {\n" + (1 ... 40).map { line in "        let value\(line) = \(line) // \(String(repeating: "p", count: 40))" }.joined(separator: "\n") + "\n        return \(index)\n    }"
        }
        let short = (1 ... 50).map { index in
            "    func short\(index)(" + (1 ... 15).map { "placeholderCount\($0): Int" }.joined(separator: ", ") + ") -> Int { \(index) }"
        }
        try ("import Foundation\n/// A page.\nstruct Paged {\n" + (long + short).joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent(target), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// What the answerer serves `command` with, failing the test where it is not answered.
    private static func answered(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Answered {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        let outcome = await InPlaceAnswerTests.onItsOwnThread { InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer to \(command), got \(outcome)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return answered
    }

    /// `reason` without its opening line, which names the call made, and its closing line, which states the size of the source the call stands in for.
    private static func page(of reason: String) -> String {
        reason.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().dropLast().joined(separator: "\n")
    }

    /// A window over most of the file is served the page `cat` of it is, apart from the lines naming the call and stating the source it stands in for.
    @Test(arguments: ["sed -n 1,400p", "head -n 400"])
    func aCoveringWindowIsServedTheWholeReadsCutPage(window: String) async throws {
        let root = try await Self.pagedRepository()

        let whole = try await Self.answered("cat \(Self.target)", in: root)
        let covering = try await Self.answered("\(window) \(Self.target)", in: root)

        #expect(whole.reason.contains("truncated: "), "\(whole.reason.suffix(300))")
        #expect(covering.reason.contains("truncated: "), "\(covering.reason.suffix(300))")
        #expect(Self.page(of: covering.reason) == Self.page(of: whole.reason), "\(covering.reason.prefix(300))")
        #expect(Self.page(of: whole.reason).count > 1000)
    }
}
