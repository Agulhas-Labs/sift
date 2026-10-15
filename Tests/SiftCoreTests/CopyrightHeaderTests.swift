//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Every Swift file in the tree opens with the copyright header.
///
/// The files read are the ones the permit list reads, under `Sources/` and `Tests/` plus `Package.swift`. The header is three lines, at the top of the file. `Package.swift` is the one exception: SwiftPM needs its tools-version line first, so the header follows that line.
struct CopyrightHeaderTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    private static let header = ["//", "// Copyright © Agulhas Labs", "//"]

    @Test func everySwiftFileCarriesTheHeader() throws {
        let files = try ExampleNamesTests.tree(in: Self.repository).filter {
            $0.hasSuffix(".swift")
                && ($0 == "Package.swift" || $0.hasPrefix("Sources/") || $0.hasPrefix("Tests/"))
        }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for path in files {
            let text = try String(contentsOf: Self.repository.appending(path: path), encoding: .utf8)
            let lines = text
                .split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false)
                .map(String.init)
            let start = path == "Package.swift" ? 1 : 0
            let top = Array(lines.dropFirst(start).prefix(Self.header.count))
            if top != Self.header {
                offenders.append(path)
            }
        }
        #expect(offenders.isEmpty, "Missing the copyright header: \(offenders.joined(separator: ", "))")
    }
}
