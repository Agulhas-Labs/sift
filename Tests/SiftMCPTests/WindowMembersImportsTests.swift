//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A window over a file's imports keeps the whole file's digest where that digest would stand in for it, however much smaller the members answer is: the digest's `imports:` line accounts for the import lines the window prints, and the members answer leaves them without a trace.
@Suite(.temporaryDirectories)
struct WindowMembersImportsTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// `import Mod1` to `import Mod40` on lines 1-40, a blank line, a doc comment, then `struct Thing` over lines 43-119 with `step1()` to `step5()`, fifteen long lines each from line 44 — so a window of lines 1-60 weighs well more than the whole digest, and its members answer, naming `step1()` and `step2()` alone, far less.
    private static var imports: [String] {
        var lines = (1 ... 40).map { "import Mod\($0) // \(String(repeating: "x", count: 60))" } + ["", "/// A thing.", "struct Thing {"]
        for step in 1 ... 5 {
            lines.append("    func step\(step)() -> Int {")
            lines += (1 ... 13).map { "        let value\($0) = \($0) // a long trailing comment padding this line out well past the digest, and further on still, then further again for good measure\(String(repeating: "x", count: 178))" }
            lines.append("    }")
        }
        return lines + ["}", ""]
    }

    /// A repository holding `Thing` at `Sources/App/Imports.swift`, indexed.
    private static func repository() async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository()
        try imports.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Imports.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A window over the imports and the first members is answered with the whole digest, which lists every import, rather than with the two members alone.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOverTheImportsKeepsTheWholeDigest(spelling: WindowReadSpelling) async throws {
        let root = try await Self.repository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Imports.swift", lines: 1 ... 60, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Imports.swift"])
        #expect(answered.reason.contains("imports: Mod1 Mod2"))
        #expect(answered.reason.contains("func step5() -> Int  :104-118"))
        #expect(!answered.reason.contains(FileDigestParts.larger))
    }

    /// A window below the imports is still answered with the members it overlaps, strictly smaller than the whole digest as they are.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowBelowTheImportsIsAnsweredWithItsMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.repository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Imports.swift", lines: 44 ... 80, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Imports.swift:44-80"])
        #expect(answered.reason.contains("func step3() -> Int  :74-88"))
        #expect(answered.reason.contains(FileDigestParts.larger))
        #expect(!answered.reason.contains("imports: Mod1"))
    }

    /// Beside another file's whole read on one shell line, a window over the imports keeps the whole digests too, the line weighed as one.
    @Test
    func aWindowOverTheImportsBesideAnotherFilesWholeReadKeepsTheWholeDigests() async throws {
        let root = try await Self.repository()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '1,60p' Sources/App/Imports.swift && cat Sources/App/Depot.swift", in: root.path))

        let outcome = try await Self.outcome(match)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Imports.swift", "Sources/App/Depot.swift"])
        #expect(answered.reason.contains("imports: Mod1 Mod2"))
        #expect(!answered.reason.contains(FileDigestParts.larger))
    }
}
