//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A grep whose pattern does not compile where the command runs it is not answered, since the re-run an answer offers would fail with the command's own error.
@Suite(.temporaryDirectories)
struct UncompilableGrepTests {
    private static func balanced(_ pattern: String, _ dialect: GrepPattern.Dialect) -> Bool {
        PatternCompiles.balanced(pattern, dialect: dialect)
    }

    @Test
    func basicGrepReadsAnEscapedParenAsAGroup() {
        #expect(!Self.balanced(#"Widget\.spin\("#, .basic))
        #expect(Self.balanced(#"Widget\.spin("#, .basic))
        #expect(Self.balanced(#"Widget\.spin\(\)"#, .basic))
        #expect(!Self.balanced(#"Widget\.spin\)"#, .basic))
    }

    @Test
    func extendedGrepAndRipgrepReadAnUnescapedParenAsAGroup() {
        #expect(Self.balanced(#"Widget\.spin\("#, .extended))
        #expect(!Self.balanced("spin(", .extended))
        #expect(Self.balanced(#"spin\("#, .extended))
        #expect(Self.balanced("spin(a|b)", .extended))
        #expect(!Self.balanced("spin)", .extended))
        #expect(!Self.balanced(")spin(", .extended))
    }

    @Test
    func aBracketExpressionHoldsNoGroup() {
        for dialect in [GrepPattern.Dialect.basic, .extended] {
            #expect(Self.balanced("spin[(]", dialect))
            #expect(Self.balanced("spin[^)]", dialect))
            #expect(Self.balanced("spin[])(]", dialect))
            #expect(Self.balanced("spin[[:alpha:](]", dialect))
        }
    }

    @Test
    func aFixedStringAlwaysCompiles() {
        #expect(Self.balanced(#"Widget\.spin\("#, .fixed))
        #expect(Self.balanced("spin(", .fixed))
    }

    /// The hook's own decision: the grep the command line spells, withheld with the new reason where it would not compile, and answered where it does.
    @Test
    func theHookWithholdsAGrepThatWouldNotCompile() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let shelves = (1 ... 24).map { "    var shelf\($0) = Gizmo.make(\($0)) // the shelf every row in the store holds" }.joined(separator: "\n")
        try MCPTestRepo.add([
            "Sources/App/Gizmo.swift": "enum Gizmo {\n    static func make(_ value: Int) -> Int { value }\n}\n",
            "Sources/App/Catalogue/Volumes/Sections/Chapters/Shelves.swift": "struct Shelves {\n\(shelves)\n}\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        let backoff = try InPlaceAnswerTests.backoff()
        func outcome(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceAnswerer.Outcome {
            let shaped = try #require(InPlaceShape.match(forShell: command, in: root.path), "\(command) is not a candidate", sourceLocation: sourceLocation)
            return InPlaceAnswerer.answer(shaped, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
        #expect(try outcome(#"grep -rn "Gizmo\.make\(" Sources"#) == .withheld(.patternInvalid))
        #expect(try outcome(#"grep -rnE "Gizmo\.make(" Sources"#) == .withheld(.patternInvalid))
        #expect(try outcome(#"grep -rnE "Gizmo\.make\(" Sources"#) != .withheld(.patternInvalid))
        let compiling = try outcome(#"grep -rn "Gizmo\.make(" Sources"#)
        guard case .answered = compiling else {
            Issue.record("the compiling grep was not answered: \(compiling)")
            return
        }
    }

    /// The `Grep` tool searches in the extended dialect, so its unbalanced pattern is withheld through the tool's own path (`toolSearch`) as the shell `grep -E` is.
    @Test
    func theHookWithholdsAGrepToolPatternThatWouldNotCompile() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        try MCPTestRepo.add(["Sources/App/Gizmo.swift": "enum Gizmo {\n    static func make(_ value: Int) -> Int { value }\n}\n"], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        let backoff = try InPlaceAnswerTests.backoff()
        func outcome(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceAnswerer.Outcome {
            let input: [String: Any] = ["output_mode": "content", "pattern": pattern, "path": root.path]
            let shaped = try #require(InPlaceShape.match(forSearchTool: "Grep", input: input, in: root.path), "\(pattern) is not a candidate", sourceLocation: sourceLocation)
            return InPlaceAnswerer.answer(shaped, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }

        #expect(try outcome(#"Gizmo\.make("#) == .withheld(.patternInvalid))
        #expect(try outcome(#"Gizmo\.make\("#) != .withheld(.patternInvalid))
    }

    /// An escaped `]` inside a bracket expression does not end it in the extended dialect (`rg` accepts `[\](]`), so the `(` after it is a member, not a group; basic grep keeps POSIX, where the backslash is a member and the `]` closes the class.
    @Test
    func anEscapedCloseBracketDoesNotEndAnExtendedBracketExpression() {
        #expect(Self.balanced(#"[\](]"#, .extended))
        #expect(Self.balanced(#"spin[^\])]x"#, .extended))
        #expect(!Self.balanced(#"[\](]("#, .extended))
        #expect(!Self.balanced(#"[\]](("#, .extended))
        #expect(!Self.balanced(#"[\]\("#, .basic))
    }

    /// An unclosed bracket expression compiles in no dialect: `rg`, `ugrep` and BSD grep all reject it, so an escaped `]` that runs a class to the pattern's end must not read as balanced.
    @Test
    func anUnclosedBracketExpressionDoesNotCompile() {
        #expect(!Self.balanced(#"Gizmo|x[\]("#, .extended))
        #expect(!Self.balanced(#"x[\]"#, .extended))
        #expect(!Self.balanced(#"[a\]"#, .extended))
        #expect(!Self.balanced("x[", .extended))
        #expect(!Self.balanced("x[", .basic))
        #expect(!Self.balanced("x[a", .basic))
        #expect(!Self.balanced("[[:alpha:]", .basic))
        #expect(Self.balanced(#"[\](]"#, .extended))
        #expect(Self.balanced("[]a]", .extended))
        #expect(Self.balanced("[^]a]", .extended))
        #expect(Self.balanced("[]a]", .basic))
        #expect(Self.balanced("[^]a]", .basic))
    }
}
