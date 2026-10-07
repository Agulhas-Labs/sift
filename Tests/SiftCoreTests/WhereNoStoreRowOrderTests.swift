//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A no-store `--refs` sweep lists each file's rows by line, whatever the wording of each row's detail.
@Suite(.temporaryDirectories)
struct WhereNoStoreRowOrderTests {
    private static func answer(_ symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    private static func lines(of file: String, in output: String) -> [Int] {
        var inFile = false
        var found: [Int] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("  \(file)") {
                inFile = true
            } else if line.hasPrefix("    :") {
                if inFile, let number = Int(line.dropFirst(5).prefix { $0.isNumber }) {
                    found.append(number)
                }
            } else {
                inFile = false
            }
        }
        return found
    }

    /// Uses and label calls interleaved in the source, some worded alike and some not, print in line order.
    @Test
    func rowsWithDifferentDetailsAscendByLine() async throws {
        let depot = """
        func stock(a: Gizmo) {
            check(a.isReady)
            let first = Gizmo(weight: 1, isReady: true)
            check(a.isReady)
            let second = Gizmo(weight: 2, isReady: false)
            check(a.isReady)
        }
        """
        let output = try await Self.answer("Gizmo.isReady", files: [
            "Sources/App/Gizmo.swift": "struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n",
            "Sources/App/Depot.swift": depot,
        ])

        #expect(Self.lines(of: "Sources/App/Depot.swift", in: output) == [2, 3, 4, 5, 6], "\(output)")
    }
}
