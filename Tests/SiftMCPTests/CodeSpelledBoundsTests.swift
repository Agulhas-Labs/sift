//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The check behind a name search of named Swift files numbers lines as grep does, a line feed alone ends a line.
@Suite(.temporaryDirectories)
struct CodeSpelledBoundsTests {
    /// A package, built with an index store, holding `settle` in files whose line endings or literals the check has to read right.
    ///
    /// `Lone` has a lone carriage return between two code lines and a comment naming `settle` on the line after; `Shifted` has one between two members, and a comment naming a third on the line after; `Crlf` spells `settle` in code alone, with every line closed by `\r\n`; `Verse` names it in a multi-line string literal; `Pattern` in a regex literal.
    private static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Lone.swift": "struct Lone {\n    func settle() -> Int { 12 }\n    func a() -> Int { settle() }\r    func b() -> Int { settle() }\n    // settle in a comment only\n}\n",
            "Sources/App/Shifted.swift": "struct Shifted {\n    func a() -> Int { 1 }\r    func b() -> Int { 2 }\n    // func c() is gone\n}\n",
            "Sources/App/Crlf.swift": "struct Crlf {\r\n    func settle() -> Int { 4 }\r\n    func c() -> Int { settle() }\r\n}\r\n",
            "Sources/App/Verse.swift": "struct Verse {\n    func settle() -> Int { 5 }\n    let text = \"\"\"\n        settle\n        \"\"\"\n}\n",
            "Sources/App/Pattern.swift": "struct Pattern {\n    func settle() -> Int { 6 }\n    @available(macOS 13, *)\n    var rule: Regex<Substring> { #/settle/# }\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A lone carriage return ends a line to the index but not to grep, so a declaration search of a file holding one is withheld, whichever answer would stand in for it; a name search of a named file is no candidate at all.
    @Test
    func lineEndingsNumberAsGrepDoes() async throws {
        let root = try await Self.repository()
        var lone: [InPlaceAnswerer.Outcome] = []
        for command in ["grep -n 'func ' Sources/App/Shifted.swift", "grep -n 'func b' Sources/App/Shifted.swift"] {
            try await lone.append(InPlaceAnswerTests.outcome(command, in: root))
        }

        #expect(lone == Array(repeating: .withheld(.unchecked), count: 2))
        #expect(InPlaceShape.match(forShell: "grep -n settle Sources/App/Lone.swift", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -n settle Sources/App/Crlf.swift", in: root.path) == nil)
    }

    /// The search itself is undecided on a file holding a lone carriage return, at the end of the file too, and decided on one closing its lines with `\r\n`.
    @Test
    func aLoneCarriageReturnLeavesTheSearchUndecided() throws {
        let directory = try TemporaryDirectory.make("bounds")
        let files = ["Lone.swift": "let a = 1\rlet b = 2\n", "Last.swift": "let a = 1\nlet b = 2\r", "Crlf.swift": "let a = 1\r\nlet b = 2\r\n"]
        for (name, contents) in files {
            try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let outcomes = try files.keys.sorted().map { name in
            try #require(ShellGrep(arguments: ["-n", "let b", name])).run(in: directory.path)
        }

        #expect(outcomes == [.printed([ShellGrep.PrintedLine(file: directory.appendingPathComponent("Crlf.swift").path, line: 2, matched: true)]), .undecided("line"), .undecided("line")])
    }
}
