//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the strings answer keeping its echo line and each catalog line to one line, however the query or a catalog value is spelled.
@Suite(.temporaryDirectories)
struct StringsEchoEscapeTests {
    private static func makeRepo() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            "greeting" = "First line\\n2 of 2";
            "quoted" = "He said \\"hi\\" twice";
            "tabbed" = "Column\\t2";
            """,
            to: "en.lproj/Localizable.strings",
            in: root
        )
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    @Test(arguments: [
        ("\n1 2", #"strings "\n1 2""#),
        ("Hel\0lo", #"strings "Hel\0lo""#),
        ("a\tb\r", #"strings "a\tb\r""#),
        ("a\u{1B}b", #"strings "a\u{1B}b""#),
    ])
    func theEchoWritesEachControlCharacterAsAnEscape(query: String, echo: String) throws {
        let lines = try Self.makeRepo().strings(query: query).split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count > 2 && lines[1] == echo, "\(lines)")
    }

    @Test(arguments: [
        ("First line", #"greeting = "First line\n2 of 2""#),
        ("He said", #"quoted = "He said \"hi\" twice""#),
        ("Column", #"tabbed = "Column\t2""#),
    ])
    func aCatalogValueIsPrintedEscapedOnItsOwnLine(query: String, line: String) throws {
        let output = try Self.makeRepo().strings(query: query)

        #expect(output.split(separator: "\n").contains { $0 == "  " + line }, Comment(rawValue: output))
    }
}
