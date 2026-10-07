//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The line diff `diff`'s safety net is measured against: every line that differs lands in a hunk, and the hunks are as few lines as any diff's.
struct LineDiffTests {
    private static func data(_ lines: [String]) -> [Data] {
        lines.map { Data(($0 + "\n").utf8) }
    }

    /// Applying the hunks to the before side gives back the after side — so no changed line is outside every hunk.
    private static func applied(_ hunks: [LineDiff.Hunk], old: [Data], new: [Data]) -> [Data] {
        var result: [Data] = []
        var cursor = 0
        for hunk in hunks {
            result += old[cursor ..< hunk.old.lowerBound]
            result += new[hunk.new]
            cursor = hunk.old.upperBound
        }
        return result + old[cursor...]
    }

    @Test func hunksReconstructTheAfterSideAndAreMinimal() {
        var random = DiffCoveragePropertyTests.SplitMix(state: 7)
        for seed in 0 ..< 400 {
            let alphabet = ["a", "b", "c", "}", ""]
            let old = (0 ..< Int.random(in: 0 ... 30, using: &random)).map { _ in alphabet.randomElement(using: &random) ?? "" }
            let new = (0 ..< Int.random(in: 0 ... 30, using: &random)).map { _ in alphabet.randomElement(using: &random) ?? "" }
            let hunks = LineDiff.hunks(old: Self.data(old), new: Self.data(new))

            #expect(Self.applied(hunks, old: Self.data(old), new: Self.data(new)) == Self.data(new), "seed \(seed): \(old) → \(new)")
            let changed = hunks.reduce(0) { $0 + $1.old.count + $1.new.count }
            #expect(changed == new.difference(from: old).count, "seed \(seed): \(old) → \(new) — not a shortest edit")
        }
    }

    /// A line is its bytes and its terminator: a line-ending conversion, a byte-order mark and a missing final newline are all differences.
    @Test func linesKeepTheirTerminators() {
        let lines = LineDiff.lines(of: Data("a\r\nb\nc".utf8))

        #expect(lines == [Data("a\r\n".utf8), Data("b\n".utf8), Data("c".utf8)])
        #expect(LineDiff.hunks(old: LineDiff.lines(of: Data("a\n".utf8)), new: LineDiff.lines(of: Data("a\r\n".utf8))).count == 1)
        #expect(LineDiff.hunks(old: LineDiff.lines(of: Data("a".utf8)), new: LineDiff.lines(of: Data("a\n".utf8))).count == 1)
    }

    /// An inserted line between equal ones could sit in any of their places; each of them is the same hunk.
    @Test func anInsertionAmongEqualLinesSlidesOverThem() throws {
        let hunks = LineDiff.hunks(old: Self.data(["x", "", "y"]), new: Self.data(["x", "", "", "", "y"]))
        let hunk = try #require(hunks.first)

        #expect(hunks.count == 1)
        #expect(hunk.old.isEmpty)
        #expect(hunk.slideUp + hunk.slideDown == 1)
        #expect(hunk.meets(old: nil, new: DeclarationRange(line: 2, endLine: 2)))
        #expect(hunk.meets(old: nil, new: DeclarationRange(line: 4, endLine: 4)))
        #expect(!hunk.meets(old: nil, new: DeclarationRange(line: 5, endLine: 5)))
    }

    @Test func entirelyDifferentSidesAreOneHunk() {
        let old = (0 ..< 400).map { "old \($0)" }
        let new = (0 ..< 400).map { "new \($0)" }

        #expect(LineDiff.hunks(old: Self.data(old), new: Self.data(new)) == [LineDiff.Hunk(old: 0 ..< 400, new: 0 ..< 400)])
    }
}
