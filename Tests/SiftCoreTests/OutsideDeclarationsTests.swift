//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// What changed outside every declaration: each shape a change can take that no declaration's own text covers, named for what it is — and the guarantee that none of them reads as "unchanged".
struct OutsideDeclarationsTests {
    private static func compared(from old: String, to new: String) -> FileDiff {
        compared(from: Data(old.utf8), to: Data(new.utf8))
    }

    private static func compared(from old: Data, to new: Data) -> FileDiff {
        FileDiff.compare(path: "Widget.swift", status: .modified, lineStat: nil, bytes: (old, new))
    }

    private static func change(_ category: OutsideDeclarations.Category, in file: FileDiff) -> OutsideChange? {
        file.outside.first { $0.category == category }
    }

    @Test func anImportAddedOrReattributedIsNamed() throws {
        let file = Self.compared(
            from: "import Foundation\n\nstruct W {\n    func f() -> Int { 1 }\n}\n",
            to: "@preconcurrency import Foundation\nimport Combine\n\nstruct W {\n    func f() -> Int { 1 }\n}\n"
        )
        let imports = try #require(Self.change(.imports, in: file))

        #expect(file.changes.isEmpty)
        #expect(imports.added.map(\.text) == ["import Combine"])
        #expect(imports.edited.map(\.new.text) == ["@preconcurrency import Foundation"])
    }

    @Test func aFlippedConditionIsNamedWithBothSides() throws {
        let file = Self.compared(from: "#if DEBUG\nfunc f() -> Int { 1 }\n#endif\n", to: "#if !DEBUG\nfunc f() -> Int { 1 }\n#endif\n")
        let conditions = try #require(Self.change(.conditions, in: file))

        #expect(conditions.removed.map(\.text) == ["#if DEBUG"])
        #expect(conditions.added.map(\.text) == ["#if !DEBUG"])
    }

    @Test func wrappingAMemberInAConditionNamesTheNewLines() throws {
        let file = Self.compared(
            from: "struct W {\n    func f() -> Int { 1 }\n}\n",
            to: "struct W {\n    #if DEBUG\n    func f() -> Int { 1 }\n    #endif\n}\n"
        )
        let conditions = try #require(Self.change(.conditions, in: file))

        #expect(Set(conditions.added.map(\.text)) == ["#if DEBUG", "#endif"])
    }

    /// The symbol visitor never records a `deinit`, so its body is compared here — by its type, so an edit reads as one edit.
    @Test func aDeinitBodyEditIsNamedByItsType() throws {
        let file = Self.compared(
            from: "final class W {\n    var x = 1\n    deinit { x = 0 }\n}\n",
            to: "final class W {\n    var x = 1\n    deinit { x = 2 }\n}\n"
        )
        let deinits = try #require(Self.change(.deinitializers, in: file))

        #expect(deinits.edited.map(\.new.label) == ["deinit in W"])
        #expect(deinits.edited.first?.new.line == 3)
    }

    @Test func aFreestandingMacroBodyEditIsNamedByItsMacro() throws {
        let file = Self.compared(
            from: "struct V {}\n#Preview { V() }\n",
            to: "struct V {}\n#Preview { V(); V() }\n"
        )
        let macros = try #require(Self.change(.macroExpansions, in: file))

        #expect(macros.edited.map(\.new.label) == ["#Preview"])
    }

    @Test func topLevelStatementsAreNamedWithTheirLines() throws {
        let file = Self.compared(from: "let x = 1\nemit(x)\nrun()\n", to: "let x = 1\nemit(x + 1)\n")
        let code = try #require(Self.change(.topLevelCode, in: file))

        #expect(code.removed.map(\.line) == [2, 3])
        #expect(code.added.map(\.line) == [2])
    }

    @Test func aCommentBetweenMembersIsNamed() throws {
        let file = Self.compared(
            from: "struct W {\n    func f() -> Int { 1 }\n}\n",
            to: "struct W {\n    // note\n    func f() -> Int { 1 }\n    // another\n}\n"
        )
        let comments = try #require(Self.change(.comments, in: file))

        #expect(file.changes.isEmpty)
        #expect(comments.added.map(\.line) == [2, 4])
    }

    @Test func aDocCommentEditIsNamed() throws {
        let file = Self.compared(
            from: "struct W {\n    /// Returns one.\n    func f() -> Int { 1 }\n}\n",
            to: "struct W {\n    /// Returns two.\n    func f() -> Int { 1 }\n}\n"
        )
        let comments = try #require(Self.change(.comments, in: file))

        #expect(comments.removed.map(\.text) == ["/// Returns one."])
        #expect(comments.added.map(\.text) == ["/// Returns two."])
    }

    /// Blank lines and indentation alone still make a file differ, and are named as that, with their lines.
    @Test func whitespaceAloneIsNamedWithItsLines() {
        let file = Self.compared(
            from: "struct W {\n    func f() -> Int { 1 }\n    func g() -> Int { 2 }\n}\n",
            to: "struct W {\n    func f() -> Int { 1 }\n\n    func g() -> Int { 2 }\n}\n"
        )

        #expect(file.changes.isEmpty)
        #expect(file.outside.isEmpty)
        #expect(file.lineChanges == [LineChange(kind: .whitespace, old: nil, new: DeclarationRange(line: 3, endLine: 3))])
    }

    @Test func identicalSidesAreSaidToBeIdentical() {
        let file = Self.compared(from: "struct W {}\n", to: "struct W {}\n")

        #expect(file.identical)
        #expect(!file.reportsChanges)
    }

    // MARK: Text in front of a type

    /// A type's header is its signature; the comments in front of it are text of their own, named with their lines — alongside, not instead of, a member edit elsewhere in the file.
    @Test(arguments: [
        ("a type's doc comment", "/// A wallet.\nstruct W {\n    func f() -> Int { 1 }\n}\n", "/// A purse.\nstruct W {\n    func f() -> Int { 2 }\n}\n", 1),
        ("a licence header over the first type", "// Licence one\nstruct W {\n    func f() -> Int { 1 }\n}\n", "// Licence two\nstruct W {\n    func f() -> Int { 2 }\n}\n", 1),
        (
            "a MARK before an extension",
            "struct W {\n    func f() -> Int { 1 }\n}\n\n// MARK: - Old\nextension W {}\n",
            "struct W {\n    func f() -> Int { 2 }\n}\n\n// MARK: - New\nextension W {}\n",
            5
        ),
        (
            "a nested type's doc comment",
            "struct W {\n    /// Old.\n    struct N {}\n    func f() -> Int { 1 }\n}\n",
            "struct W {\n    /// New.\n    struct N {}\n    func f() -> Int { 2 }\n}\n",
            2
        ),
    ])
    func aCommentInFrontOfATypeIsNamedAlongsideAMemberEdit(shape: String, old: String, new: String, line: Int) throws {
        let file = Self.compared(from: old, to: new)
        let comments = try #require(Self.change(.comments, in: file), "\(shape)")

        #expect(file.changes.map(\.name) == ["f()"], "\(shape)")
        #expect(comments.removed.map(\.line) == [line], "\(shape)")
        #expect(comments.added.map(\.line) == [line], "\(shape)")
        #expect(file.lineChanges.isEmpty, "\(shape)")
    }

    // MARK: What the line diff holds the breakdown to

    /// A type's closing brace moved past the next type: the lines that changed are the type's own, and the type is named as what changed — not left to "other changes".
    @Test func aTypeWhoseClosingBraceMovedIsNamed() throws {
        let file = Self.compared(
            from: "struct W {\n    var a = 1\n}\n\nenum Level {\n    case low\n}\n",
            to: "struct W {\n    var a = 1\n\nenum Level {\n    case low\n}\n}\n"
        )
        let extent = try #require(file.changes.first { $0.name == "W" })

        #expect(extent.kind == .changed)
        #expect(extent.extentChanged)
        #expect(file.lineChanges.isEmpty)
    }

    /// Of two identical declarations, the one whose line the line diff kept is the one that was there before, and the other is the addition — at the line git shows added.
    @Test func ofTwoIdenticalDeclarationsTheOneWhoseLineWasKeptIsPaired() throws {
        let file = Self.compared(
            from: "struct W {\n    // note\n        var size = 0\n}\n",
            to: "struct W {\n    var size = 0\n    // note\n        var size = 0\n}\n"
        )
        let added = try #require(file.changes.first { $0.kind == .added })

        #expect(added.newRange?.line == 2)
        #expect(file.lineChanges.isEmpty)
    }

    /// A line diff may align an untouched declaration as moved when its neighbour was removed; its bytes are unchanged and its place among its siblings is too, so nothing is claimed about it.
    @Test func aDeclarationALineDiffShowsDisplacedIsNotAChange() {
        let file = Self.compared(
            from: "struct W {\n    func f() -> Int { 1 }\n    func g() -> Int { 2 }\n}\n",
            to: "struct W {\n    func g() -> Int { 2 }\n}\n\nextension W {\n    func f() -> Int { 1 }\n}\n"
        )

        #expect(!file.changes.contains { $0.name == "g()" })
        #expect(file.lineChanges.isEmpty)
    }

    /// Every changed line is printed — adjacent ones merged, none cut to a count — and a multi-line text with its whole range.
    @Test func everyLineIsPrintedWithItsWholeRange() {
        let comments = (1 ... 20).map { "// note \($0)\nlet x\($0) = \($0)\n" }.joined()
        let file = Self.compared(
            from: comments + "final class H {\n    deinit {\n        emit(0)\n    }\n}\n",
            to: comments.replacingOccurrences(of: "// note", with: "// line") + "final class H {\n    deinit {\n        emit(1)\n    }\n}\n"
        )
        let range = DiffRange(from: "HEAD", to: .workingTree, described: "working tree vs HEAD")
        let rendered = DiffRenderer.render(DiffRenderer.Input(
            range: range, files: [file], notBrokenDown: [], nonSwift: [], callers: [], workingTreeIsAfterSide: true,
            tests: nil, options: DiffOptions(range: range), rawDiffBytes: 0, axis: .syntacticOnly
        )).body

        #expect(rendered.contains("+ comments or doc comments  " + (1 ... 20).map { ":\(2 * $0 - 1)" }.joined(separator: ", ")))
        #expect(!rendered.contains(" more"))
        #expect(rendered.contains("~ deinit in H  :42-44"))
    }

    // MARK: Bytes, not decoded text

    /// Decoding drops a byte-order mark, so two decoded sides compare equal; the bytes do not, and the mark is named.
    @Test func anAddedByteOrderMarkIsNamedNotUnchanged() {
        let source = "struct W {\n    func f() -> Int { 1 }\n}\n"
        let file = Self.compared(from: Data(source.utf8), to: Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8))

        #expect(!file.identical)
        #expect(file.lineChanges.map(\.kind) == [.byteOrderMark(added: true)])
    }

    /// A mark taken away on a line whose code changed too is still named: the declaration answers for the code, not for the mark.
    @Test func aByteOrderMarkRemovedAlongsideAnEditOnItsLineIsNamed() {
        let file = Self.compared(
            from: Data([0xEF, 0xBB, 0xBF]) + Data("func f() -> Int { 1 }\n".utf8),
            to: Data("func f() -> Int { 2 }\n".utf8)
        )

        #expect(file.changes.map(\.name) == ["f()"])
        #expect(file.lineChanges.map(\.kind) == [.byteOrderMark(added: false)])
    }

    /// Swift's string equality calls a composed and a decomposed `é` the same; git does not, and neither does a declaration's comparison.
    @Test func aChangeOfUnicodeNormalizationIsADeclarationChange() {
        let file = Self.compared(from: "let greeting = \"caf\u{E9}\"\n", to: "let greeting = \"cafe\u{301}\"\n")

        #expect(!file.identical)
        #expect(file.changes.map(\.name) == ["greeting"])
    }

    /// A line-ending conversion is not every multi-line declaration's body changing, and not blank lines or indentation either: it is named as what it is.
    @Test func aLineEndingConversionIsNamedAsOne() {
        let file = Self.compared(
            from: "struct W {\n    func f() -> Int {\n        1\n    }\n}\n",
            to: "struct W {\r\n    func f() -> Int {\r\n        1\r\n    }\r\n}\r\n"
        )

        #expect(file.changes.isEmpty)
        #expect(file.lineChanges.map(\.kind) == [.lineEndings(" (LF → CRLF)")])
    }
}
