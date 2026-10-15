//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A single cited line inside a long member is answered as one window of 7 lines, a page by itself; an offset past that page prints the past-end line naming the window's lines.
@Suite(.temporaryDirectories, .serialized)
struct PastEndLineSingleLineTests {
    private static func renderer() throws -> DigestRenderer {
        let root = try TemporaryDirectory.make("past-end-single-line")
        let body = (0 ..< 70).map { "        let value\($0) = \($0)" }.joined(separator: "\n")
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed("struct Long {\n    func run() {\n\(body)\n    }\n}", path: "Sources/Alpha/Long.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    @Test
    func aSingleLineWindowWithAnOffsetPastItsEndNamesTheWindowsLines() throws {
        let answer = try Self.renderer().render(target: "Sources/Alpha/Long.swift:40", options: DigestOptions(offset: 9))

        #expect(answer.contains("offset 9 is past the last of 7 body lines — drop offset to see them"))
        #expect(!answer.contains("skipped"))
        #expect(!answer.contains("let value"))
    }

    @Test
    func aSingleLineWindowWithAnOffsetAtItsLastLineStillShowsIt() throws {
        let answer = try Self.renderer().render(target: "Sources/Alpha/Long.swift:40", options: DigestOptions(offset: 6))

        #expect(!answer.contains("is past the last of"))
        #expect(answer.contains("let value40 = 40"))
    }

    @Test(arguments: [(0, 1, false), (1, 1, true), (9, 1, true), (9, 7, true), (7, 7, true), (6, 7, false), (0, 0, false), (3, 0, false)])
    func theSinglePageListAppliesOnlyFromItsCount(offset: Int, count: Int, applies: Bool) {
        #expect(PastEndLine.applies(offset: offset, count: count) == applies)
    }
}
