//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// Where one file's own windows save too little but the line as a whole saves plenty, the members answer's note names that file and its own saving, not the whole digests' or the line's.
@Suite(.temporaryDirectories)
struct WholeSetAsideNamesShortFileTests {
    /// `struct Big` opening on `big()`, forty long lines from line 3, then `tail()` on line 44 and sixty one-line members: a window from inside `big()` to `tail()` weighs a little over the whole digest.
    private static var big: String {
        var lines = ["struct Big {", "    func big() -> Int {"]
        lines += (1 ... 40).map { "        let value\($0) = \($0) // a long trailing comment padding this line out well past the digest, and further on still, then further again\(String(repeating: "x", count: 180))" }
        lines += ["    }", "    func tail() -> Int { 0 }"]
        lines += (1 ... 240).map { "    func f\($0)() -> Int { \($0) }" }
        return (lines + ["}", ""]).joined(separator: "\n")
    }

    /// A window of `Big` from inside `big()` to `tail()` beside `Depot` read whole: the line saves kilobytes, `Big`'s own window less than the floor, and the note says that of `Sources/App/Big.swift` rather than of the whole digests.
    @Test
    func theNoteNamesTheFileWhoseWindowsFellShort() async throws {
        let root = try await CompoundSetAsideReasonTests.repository(small: CompoundSetAsideReasonTests.smalls[0])
        try Self.big.write(to: root.appendingPathComponent("Sources/App/Big.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        var opening: [String] = []
        for start in 22 ... 29 {
            let match = try #require(InPlaceShape.match(forShell: "cat Sources/App/Depot.swift; sed -n \(start),44p Sources/App/Big.swift", in: root.path))
            let outcome = try await CompoundSetAsideReasonTests.outcome(match)
            if case let .answered(answered) = outcome {
                opening.append(String(answered.reason.prefix { $0 != "\n" }))
            } else {
                opening.append("\(start): \(outcome)")
            }
        }

        #expect(opening.contains { $0.contains("Sources/App/Big.swift's windows save only ") })
        #expect(!opening.contains { $0.contains("the whole digests save") }, "\(opening)")
    }
}
