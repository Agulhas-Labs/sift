//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A grep of one file for declaration vocabulary alone — keywords and attributes, alternated, with `-n` or `-E` — answered with the file's digest wherever every line it prints is a declaration's own line or an attribute line of one the digest lists.
@Suite(.temporaryDirectories)
struct DeclarationGrepDigestTests {
    /// The shape a test file is listed by — `@Test` on one line and `func` on the next — is the file's digest: the digest entry opening on the attribute's line stands for both lines.
    @Test
    func attributeAndKeywordAlternatedAreTheDigest() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(#"grep -n 'func \|@Test' Sources/App/Checks.swift"#, in: root))

        #expect(answered.calls.map(\.tool) == ["digest"])
        #expect(answered.calls.map(\.target) == ["Sources/App/Checks.swift"])
    }

    /// The keyword alone, and the extended dialect's alternation in each flag spelling, are the same digest.
    @Test(arguments: [
        "grep -n 'func ' Sources/App/Checks.swift",
        "grep 'func ' Sources/App/Checks.swift",
        "grep -nE 'func |@Test' Sources/App/Checks.swift",
        "grep -En 'func |@Test' Sources/App/Checks.swift",
        "grep -n -E 'func |@Test' Sources/App/Checks.swift",
        "grep -E 'func |@Test|@MainActor' Sources/App/Checks.swift",
        #"grep -n "func \|@Test\|actor " Sources/App/Checks.swift"#,
    ])
    func everyListedSpellingIsTheDigest(_ command: String) async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))

        #expect(answered.calls.map(\.target) == ["Sources/App/Checks.swift"])
    }

    /// A keyword the grep finds in a comment is a line no digest shows, so the grep runs.
    @Test
    func aKeywordInACommentIsWithheld() async throws {
        let root = try await Self.repository()

        #expect(try await InPlaceAnswerTests.outcome(#"grep -n 'func \|@Test' Sources/App/Remarked.swift"#, in: root) == .withheld(.notExact))
    }

    /// Every form outside the list keeps the reading it had: a name after the keyword, a count, two files, a dialect's wrong separator, an anchor, a folded case, a second pattern, a cut, and a statement beside it.
    @Test(arguments: [
        "grep -n 'func load' Sources/App/Checks.swift",
        "grep -c 'func ' Sources/App/Checks.swift",
        "grep -n 'func ' Sources/App/Checks.swift Sources/App/Remarked.swift",
        #"grep -n 'func\|x' Sources/App/Checks.swift"#,
        "grep -n 'func |@Test' Sources/App/Checks.swift",
        #"grep -nE 'func \|@Test' Sources/App/Checks.swift"#,
        "grep -n '^func' Sources/App/Checks.swift",
        "grep -in 'FUNC ' Sources/App/Checks.swift",
        "grep -n -e func -e var Sources/App/Checks.swift",
        "grep -n 'func ' Sources/App/Checks.swift | head -5",
        "grep -rn 'func ' Sources/App",
    ])
    func aFormOutsideTheListIsNotWidened(_ command: String) {
        let widened = InPlaceShape.match(forShell: command, in: "/nowhere")?.calls.contains { call in
            guard case let .declarations(_, search) = call else { return false }
            return search.asksForDeclarationVocabulary
        }

        #expect(widened != true)
    }

    /// A name after the keyword is still the member it names, answered with that member's source rather than the file's digest.
    @Test
    func aNamedMemberKeepsItsAnswer() async throws {
        let root = try await Self.repository()

        let member = try #require(try await InPlaceAnswerTests.answered("grep -n 'func first' Sources/App/Checks.swift", in: root))

        #expect(member.calls.map(\.target) == ["Checks.first()"])
    }

    /// The answer is credited as any in-place digest is: the file is located, so a ranged window of it that follows is guided.
    @Test
    func theAnswerLocatesTheFileForTheAudit() async throws {
        let root = try await Self.repository()
        let command = #"grep -n 'func \|@Test' Sources/App/Checks.swift"#
        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))

        var state = TranscriptScanState()
        for line in [
            TranscriptTurns.call("Bash", id: "b1", input: ["command": command], turn: "m1", cwd: root.path),
            TranscriptTurns.result(id: "b1", text: answered.reason, isError: true),
        ] {
            _ = TranscriptScan.events(line: line, state: &state)
        }

        let key = CallerRoot.root(forCallerIn: root.path) ?? ""

        #expect(state.locates(root.appendingPathComponent("Sources/App/Checks.swift").path, in: key))
    }

    /// A long `@Test(arguments:)` cuts its digest entry before the `func` line, so the name line the grep prints is one the digest never shows, and the grep runs.
    @Test(arguments: [
        #"grep -n 'func \|@Test' Sources/App/Longer.swift"#,
        "grep -n 'func ' Sources/App/Longer.swift",
    ])
    func aNameCutFromItsEntryIsWithheld(_ command: String) async throws {
        let root = try await Self.attributeRepository()

        #expect(try await InPlaceAnswerTests.outcome(command, in: root) == .withheld(.notExact))
    }

    /// An attribute on its own line after a long attribute stands past the cut, so it is no line the digest shows.
    @Test
    func anAttributePastTheCutIsWithheld() async throws {
        let root = try await Self.attributeRepository()

        #expect(try await InPlaceAnswerTests.outcome(#"grep -n 'struct \|@MainActor' Sources/App/Actors.swift"#, in: root) == .withheld(.notExact))
    }

    /// A line starting with `@` inside a multi-line string among a long attribute's arguments is no attribute and, cut from the entry, no line the digest shows.
    @Test
    func anAtLineInsideAnAttributesStringIsWithheld() async throws {
        let root = try await Self.attributeRepository()

        #expect(try await InPlaceAnswerTests.outcome(#"grep -n 'struct \|@Test' Sources/App/Smuggle.swift"#, in: root) == .withheld(.notExact))
    }

    /// Attributes short enough for their entries to show them whole, on one line or several, still leave the grep answered with the digest.
    @Test
    func shortAttributesAreStillTheDigest() async throws {
        let root = try await Self.attributeRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered(#"grep -n 'func \|@Test\|@MainActor' Sources/App/Short.swift"#, in: root))

        #expect(answered.calls.map(\.target) == ["Sources/App/Short.swift"])
    }
}

extension DeclarationGrepDigestTests {
    /// A repository with two files long enough to be digested: one of tests whose every `func` and `@Test` line is a declaration's own, and the same with a comment spelling the keyword.
    static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let fillers = (0 ..< 40).flatMap { index in
            ["    func stock\(index)() -> Int {", "        let count = \(index)", "        let doubled = count * 2", "        return doubled + count", "    }"]
        }
        let checks = ["struct Checks {", "    @Test", "    func first() {}", "    @Test", "    @MainActor", "    func second() {}", "    @MainActor func third() {}"]
            + fillers + ["}", "", "actor Worker {", "    func run() {}", "}"]
        let remarked = ["struct Remarked {", "    @Test", "    func first() {}", "    // a func in prose"] + fillers + ["}"]
        try MCPTestRepo.add([
            "Sources/App/Checks.swift": checks.joined(separator: "\n") + "\n",
            "Sources/App/Remarked.swift": remarked.joined(separator: "\n") + "\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A repository of files some six hundred lines long, each opening on attributes: long ones that cut their digest entries short, one hiding an `@` line in a string among its arguments, and short ones shown whole.
    static func attributeRepository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let fillers = (0 ..< 40).flatMap { index in
            ["    func stock\(index)() -> Int {", "        let count = \(index)"]
                + (1 ... 12).map { "        let value\($0) = count * \($0) + \(index)" }
                + ["    }"]
        }
        let long = [
            "    @Test(arguments: [", "        \"an empty manifest with no targets\",", "        \"a manifest that declares two executable targets\",",
            "        \"a manifest whose products name a missing target\",", "        \"a manifest with a plugin and a macro target\",", "    ])",
        ]
        let entries = (0 ..< 60).map { "\"entry \($0)\"" }.joined(separator: ", ")
        let files = [
            "Longer": long + ["    func loads(named fixture: String) {}"],
            "Actors": long + ["    @MainActor", "    func loads(named fixture: String) {}"],
            "Smuggle": ["    @Test(arguments: [#\"\"\"", "    @Test func smuggled()", "    \"\"\"#, \(entries)])", "    func loads(named fixture: String) {}"],
            "Short": [
                "    @Test(arguments: [", "        \"one\",", "        \"two\",", "    ])", "    func loads(named fixture: String) {}",
                "    @Test(arguments: [\"one\", \"two\"])", "    func second(named fixture: String) {}", "    @Test", "    @MainActor", "    func third() {}",
            ],
        ]
        try MCPTestRepo.add(Dictionary(uniqueKeysWithValues: files.map { name, head in
            ("Sources/App/\(name).swift", (["struct \(name) {"] + head + fillers + ["}"]).joined(separator: "\n") + "\n")
        }), to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }
}
