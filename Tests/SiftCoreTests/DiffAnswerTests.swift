//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// What `sift diff`'s answer says of the less common states a file or member can be in — renamed and nothing more, deleted in the index but on disk, given a byte-order mark, headed under an extension, one of several same-labeled members — and how the whole answer is priced across its pages.
///
/// Built on `DiffEngineTests`' repository.
@Suite(.temporaryDirectories)
struct DiffAnswerTests {
    /// A rename that changed nothing else is not a file "changed only outside declarations".
    @Test func anUnchangedRenameIsCountedAsUnchangedNotAsChangedOutsideDeclarations() async throws {
        let root = try DiffEngineTests.makeRepo()
        try TestSources.runGit(["mv", "Sources/Lib/Widget.swift", "Sources/Lib/Gadget.swift"], in: root)
        try TestSources.commitAll(in: root, message: "rename")
        let output = try await DiffEngineTests.diff(root, range: "HEAD")

        #expect(output.contains("Sources/Lib/Gadget.swift (renamed from Sources/Lib/Widget.swift"))
        #expect(output.contains("(content unchanged)"))
        #expect(output.contains("1 with content unchanged"))
        #expect(!output.contains("changed only outside declarations"))
    }

    /// `git rm --cached` leaves the file on disk, untracked: one file, listed once, whose content is what `HEAD` holds.
    @Test func aFileRemovedFromTheIndexButStillOnDiskIsListedOnce() async throws {
        let root = try DiffEngineTests.makeRepo()
        try TestSources.runGit(["rm", "-q", "--cached", "Sources/Lib/Widget.swift"], in: root)
        let output = try await DiffEngineTests.diff(root)

        #expect(output.components(separatedBy: "Sources/Lib/Widget.swift (").count - 1 == 1)
        #expect(output.contains("Sources/Lib/Widget.swift (deletion staged, but the file is still on disk, untracked, +0/-0):"))
        #expect(output.contains("(content unchanged)"))
    }

    /// A byte-order mark added to a file is a change git shows; the answer names it rather than calling the content unchanged.
    @Test func anAddedByteOrderMarkIsNamed() async throws {
        let root = try DiffEngineTests.makeRepo()
        let path = root.appendingPathComponent("Sources/Lib/Widget.swift")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(contentsOf: path)).write(to: path)
        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("+ byte-order mark  :1"))
        #expect(!output.contains("(content unchanged)"))
    }

    /// A protocol's own members and an extension's are never headed alike.
    @Test func anExtensionIsHeadedAsOneApartFromItsType() async throws {
        let root = try DiffEngineTests.makeRepo()
        try TestSources.write("public protocol Shiny {\n    func shine() -> Int\n}\n\nextension Shiny {\n    func buff() -> Int { 1 }\n}\n", to: "Sources/Lib/Shiny.swift", in: root)
        try TestSources.commitAll(in: root, message: "shiny")
        try TestSources.write("public protocol Shiny {\n    func shine() -> String\n}\n\nextension Shiny {\n    func buff() -> Int { 2 }\n}\n", to: "Sources/Lib/Shiny.swift", in: root)
        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("  Shiny:\n    ~ func shine()"))
        #expect(output.contains("  Shiny (extension):\n    ~ func buff()"))
    }

    /// Two extensions of one type share a dotted path; the refusal says which extension each address is in.
    @Test func anAmbiguityRefusalSaysWhichExtensionEachAddressIsIn() async throws {
        let root = try DiffEngineTests.makeRepo()
        let source: (Int) -> String = { value in
            "extension Array where Element == Int {\n    func total() -> Int { \(value) }\n}\n\nextension Array where Element == String {\n    func total() -> Int { \(value) }\n}\n"
        }
        try TestSources.write(source(1), to: "Sources/Lib/Totals.swift", in: root)
        try TestSources.commitAll(in: root, message: "totals")
        try TestSources.write(source(2), to: "Sources/Lib/Totals.swift", in: root)

        let refusal = try await DiffEngineTests.diff(root, member: "Array.total")

        #expect(refusal.contains("changed, in Array (extension where Element == Int)"))
        #expect(refusal.contains("changed, in Array (extension where Element == String)"))
    }

    /// `--member` keeps the body of the declaration it names and of nothing else in the range.
    @Test func memberKeepsOnlyTheNamedDeclarationsBody() {
        let file = DiffGatherer.fileDiff(
            GitContext.Change(kind: .addedOrModified, path: "Sources/Lib/Widget.swift"),
            old: Data("struct W {\n    func a() -> Int { 1 }\n    func b() -> Int { 1 }\n}\n".utf8),
            new: Data("struct W {\n    func a() -> Int { 2 }\n    func b() -> Int { 2 }\n}\n".utf8),
            member: "W.a"
        )

        #expect(file.changes.first { $0.name == "a()" }?.newBody != nil)
        #expect(file.changes.first { $0.name == "b()" }?.newBody == nil)
    }

    /// Overloads can share a labeled name; the line picks the one that changed, never simply the first.
    @Test func callersResolveTheOverloadAtTheChangedLine() {
        func row(line: Int) -> SymbolRow {
            SymbolRow(
                id: Int64(line), fileID: 1, path: "Sources/Lib/Widget.swift", module: "Lib", parentID: nil, kind: .function, name: "polish(_:)",
                line: line, column: 5, endLine: line, accessLevel: .internalLevel, isStatic: false, isStored: false,
                signature: "func polish(_ x: Int) -> Int", docSummary: nil, ifConfigCondition: nil, viewOutline: nil
            )
        }
        let target = DiffCallers.Target(label: "Widget.polish(_:)", name: "polish(_:)", kind: .function, path: "Sources/Lib/Widget.swift", line: 9, removed: false)

        guard case let .row(chosen) = DiffCallers.declaration(among: [row(line: 8), row(line: 9)], for: target) else {
            Issue.record("the overload at the target's line was not chosen")
            return
        }
        #expect(chosen.line == 9)
        guard case .fallback = DiffCallers.declaration(among: [row(line: 3), row(line: 4)], for: target) else {
            Issue.record("an overload at another line was resolved as this one")
            return
        }
    }

    /// The saving is the whole answer's, stated once: the first page prices every page, and a later page says it is a continuation rather than claiming the saving again.
    @Test func theWholeAnswerIsPricedOnceOnTheFirstPage() async throws {
        let root = try DiffEngineTests.makeRepo()
        let functions = (1 ... 130).map { "    public func step\($0)() -> Int { \($0) }" }.joined(separator: "\n")
        try TestSources.write("public struct Stepper {\n\(functions)\n}\n", to: "Sources/Lib/Stepper.swift", in: root)
        try TestSources.commitAll(in: root, message: "steps")
        try TestSources.write("public struct Stepper {\n\(functions.replacingOccurrences(of: "{ ", with: "{ 0 + "))\n}\n", to: "Sources/Lib/Stepper.swift", in: root)

        let first = try await DiffEngineTests.diff(root)
        let second = try await DiffEngineTests.diff(root, offset: DiffRenderer.pageCap)
        let served = try #require(first.firstMatch(of: /this answer ([0-9.]+) kB across its 2 pages/)?.output.1)

        // A figure in kB is cut to its unit, so it may read up to a kilobyte short of the bytes — never more.
        #expect(Double(served).map { $0 * 1000 > Double(first.utf8.count + second.utf8.count) - 1000 } == true)
        #expect(!second.contains("size:"))
        #expect(second.contains("continued (page 2 of 2, from declaration entry 101 of 130)"))
    }

    /// A signature is cut only for display, and where both sides would be cut at the same place over a difference past the cut, both are shown from shortly before it.
    @Test func aSignatureEditPastTheDisplayCutIsShown() {
        let clause = (1 ... 12).map { "T\($0): Equatable" }.joined(separator: ", ")
        let header = "struct Widget<T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12> where \(clause), T12: "
        let file = FileDiff.compare(
            path: "Sources/Lib/Widget.swift",
            status: .modified,
            lineStat: nil,
            bytes: (Data("\(header)Sendable {}\n".utf8), Data("\(header)Codable {}\n".utf8))
        )
        let range = DiffRange(from: "HEAD", to: .workingTree, described: "working tree vs HEAD")
        let rendered = DiffRenderer.render(DiffRenderer.Input(
            range: range, files: [file], notBrokenDown: [], nonSwift: [], callers: [], workingTreeIsAfterSide: true,
            tests: nil, options: DiffOptions(range: range), rawDiffBytes: 0, axis: .syntacticOnly
        )).body

        #expect(rendered.contains("T12: Sendable"))
        #expect(rendered.contains("T12: Codable"))
    }

    /// The served figure is exact: the first page, its own size line, and every later page's bytes.
    @Test func theServedFigureCountsEveryLaterPage() throws {
        let answer = "tree: example\ndiff: something\n" + String(repeating: "x", count: 200)
        let priced = DiffRenderer.priced(answer, rawBytes: 50000, laterPageBytes: [150, 90])
        let served = try #require(priced.firstMatch(of: /this answer (\d+) B across its 3 pages/)?.output.1)

        #expect(Int(served) == priced.utf8.count + 240)
    }
}
