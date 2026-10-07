//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The reason a compound line's answer gives for setting a whole digest aside names the condition that set it aside, never one that does not hold of the file it names.
@Suite(.temporaryDirectories)
struct CompoundSetAsideReasonTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// `import Mod1` to `import Mod40` on lines 1-40, a blank line, a doc comment, then `struct Thing` with `step1()` to `step5()`, fifteen long lines each from line 44 — a window of lines 1-60 weighs well more than the whole digest.
    static var imports: [String] {
        var lines = (1 ... 40).map { "import Mod\($0) // \(String(repeating: "x", count: 60))" } + ["", "/// A thing.", "struct Thing {"]
        for step in 1 ... 5 {
            lines.append("    func step\(step)() -> Int {")
            lines += (1 ... 13).map { "        let value\($0) = \($0) // a long trailing comment padding this line out well past the digest, and further on still, then further again for good measure\(String(repeating: "x", count: 178))" }
            lines.append("    }")
        }
        return lines + ["}", ""]
    }

    /// A repository holding `Thing` at `Sources/App/Imports.swift` and `small` at `Sources/App/Small.swift`, indexed.
    static func repository(small: String) async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: 80)
        try imports.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Imports.swift"), atomically: true, encoding: .utf8)
        try small.write(to: root.appendingPathComponent("Sources/App/Small.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Files read whole beside the window: one served as its own source, one whose digest is about its size, and one naming a nested type's members on its line alone.
    static let smalls: [String] = [
        "struct Small {\n    let size = 1\n}\n",
        "struct Small {\n" + (1 ... 60).map { "    func f\($0)() -> Int { \($0) }" }.joined(separator: "\n") + "\n}\n",
        "struct Small {\n    struct Inner {\n" + (1 ... 12).map { "        func n\($0)() {}" }.joined(separator: "\n") + "\n    }\n}\n",
    ]

    /// A whole read beside a window over another file's imports whose digest is smaller than the window: both are answered with their whole digests, and no note says the window's digest is no smaller than its lines.
    @Test(arguments: smalls)
    func aDigestSmallerThanItsWindowIsNeverCalledNoSmaller(small: String) async throws {
        let root = try await Self.repository(small: small)
        let match = try #require(InPlaceShape.match(forShell: "cat Sources/App/Small.swift; sed -n 1,60p Sources/App/Imports.swift", in: root.path))

        let outcome = try await Self.outcome(match)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Small.swift", "Sources/App/Imports.swift"])
        #expect(answered.reason.contains("imports: Mod1 Mod2"))
        #expect(!answered.reason.contains("no smaller than these lines"))
    }
}
