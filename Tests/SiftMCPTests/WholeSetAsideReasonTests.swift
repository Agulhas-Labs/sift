//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The reason a members answer's note gives for setting the whole answer aside is the check the whole answer failed — over the size budget, no smaller than what it weighed, or saving too little for the lines it does not show — said of the whole digests together where a file read whole beside the window weighs in too, and never 'no smaller than the lines asked for' of a digest smaller than its window.
@Suite(.temporaryDirectories)
struct WholeSetAsideReasonTests {
    /// `struct Big` opening on `big()`, forty long lines from line 3, then `tail()` on line 44 and thirty-eight members of long signatures: a window from line 3, 4 or 5 to `tail()` saves the floor with its members, and weighs a little over the whole digests together.
    private static var big: String {
        var lines = ["struct Big {", "    func big() -> Int {"]
        lines += (1 ... 40).map { "        let value\($0) = \($0) // a long trailing comment padding this line out well past the digest, and further on still, then further again" }
        lines += ["    }", "    func tail() -> Int { 0 }"]
        lines += (1 ... 38).map { "    func stock\($0)(quantity: Int, label: String, owner: String, location: String, reference: Int, count: Int) -> Int { \($0) }" }
        return (lines + ["}", ""]).joined(separator: "\n")
    }

    /// The opening line of each answer `lines` get in a repository holding a one-line `Small.swift`, `Imports.swift` and `Big.swift`, or the outcome where one is not answered.
    private static func openingLines(_ lines: [String], sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String] {
        let root = try await CompoundSetAsideReasonTests.repository(small: CompoundSetAsideReasonTests.smalls[0])
        try big.write(to: root.appendingPathComponent("Sources/App/Big.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        var opening: [String] = []
        for line in lines {
            let match = try #require(InPlaceShape.match(forShell: line, in: root.path), sourceLocation: sourceLocation)
            let outcome = try await CompoundSetAsideReasonTests.outcome(match)
            guard case let .answered(answered) = outcome else {
                opening.append("\(line): \(outcome)")
                continue
            }
            opening.append(String(answered.reason.prefix { $0 != "\n" }))
        }
        return opening
    }

    /// Windows of `Thing` below its imports, fifteen to nineteen long lines against a whole digest well under half their size: where the digest saves too little for lines it does not show, the note says so, of the digest alone or of the whole digests beside a file read whole, and never that the digest is no smaller than the lines asked for.
    ///
    /// Each line of the window adds 330 B of source, so one window always sits within a line of the floor. Lines 44-60 are the first the members answer serves, and the whole digest saves under the floor; the pin holds while the refusal's framing moves by less than a line, and lines 44-62 are pinned only beside the file read whole, whose digests save 858 B.
    @Test
    func aDigestSavingTooLittleIsNeverCalledNoSmaller() async throws {
        let windows = (58 ... 62).map { "sed -n 44,\($0)p Sources/App/Imports.swift" }
        let opening = try await Self.openingLines(windows + windows.map { "cat Sources/App/Small.swift; " + $0 })

        #expect(opening.contains { $0.contains("only the members of lines 44-60 are shown; the whole digest saves under 4096 B)") })
        #expect(opening.contains { $0.contains("only members of Sources/App/Imports.swift lines 44-62 are shown; the whole digests save under 4096 B)") })
        #expect(!opening.contains { $0.contains("no smaller") })
    }

    /// Windows from inside `big()` to `tail()` beside a file read whole: where the whole digests together are no smaller than what the line prints, the note says that of the whole digests and the line, not of the window's own digest and its lines.
    @Test
    func aWholeReadBesideTheWindowIsWeighedInTheReason() async throws {
        let opening = try await Self.openingLines((3 ... 10).map { "cat Sources/App/Small.swift; sed -n \($0),44p Sources/App/Big.swift" })

        #expect(opening.contains { $0.contains("only members of Sources/App/Big.swift lines 4-44 are shown; the whole digests would be no smaller than the output)") })
        #expect(!opening.contains { $0.contains("these lines") })
    }
}
