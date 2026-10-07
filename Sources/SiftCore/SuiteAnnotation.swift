//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// What a digest of a test suite carries beyond its declarations: each small helper's own source beneath its signature, and where the next test goes.
///
/// Serves the agent about to add a test. A suite's helpers — the fixture builders and assertion wrappers its tests call — are what a new test is written against, and a signature alone rarely says what one does; the last test is where the new one goes. A suite is recognised the same structural way `affected` and `flakes` recognise one (`TestSymbolReader`): the file's imports name the library, and `@Test`/`@Suite` or `XCTestCase` inheritance name the suite.
///
/// A helper is any member of a suite that is not a test and has a body — a method, an initializer, a computed property. Its source is **bounded twice**: past `lineCap` lines it keeps its signature alone, and past `budget` lines across the whole digest every further helper does too, so a suite with many helpers cannot grow its digest towards the size of its file. Either way a helper left uninlined is named by its signature and range, like any member, and the answer says how many were — a body that could not be read at all included.
final class SuiteAnnotation {
    /// The most body lines one helper may inline — a short assertion wrapper or fixture builder, not a long one.
    static var lineCap: Int {
        10
    }

    /// The most helper lines one digest may inline, across every helper in it.
    static var budget: Int {
        20
    }

    private let store: IndexStore
    private let reader: TestSymbolReader
    private let styles: Set<TestSymbol.Style>
    private let repoRoot: URL
    private let inlining: Bool
    private var linesLeft = SuiteAnnotation.budget
    private var withheld = 0
    private var lastTests: [(suite: SymbolRow, test: SymbolRow)] = []

    /// `nil` for a file that imports no testing library — every ordinary file, which takes none of this.
    ///
    /// `signaturesOnly` asks for exactly the signatures, so it inlines nothing; the last test is still named, since it is a location rather than source.
    init?(file: FileRow, store: IndexStore, repoRoot: URL, options: DigestOptions) {
        let styles = TestSymbolReader.styles(importedBy: file)
        guard !styles.isEmpty else { return nil }
        self.store = store
        reader = TestSymbolReader(store: store)
        self.styles = styles
        self.repoRoot = repoRoot
        inlining = !options.signaturesOnly
    }

    /// The suite a container's members belong to — the container itself when it is one, the type an extension extends when that is one — or `nil`.
    ///
    /// An extension is resolved to the type it extends first, because an `XCTestCase` subclass's extension restates no inheritance and would otherwise never read as a suite at all; a swift-testing extension whose own members carry `@Test` is one either way.
    func suite(owning container: SymbolRow) throws -> SymbolRow? {
        if container.kind == .extensionKind {
            let extended = try store.typeDeclarations(named: container.name)
            if extended.count == 1, try reader.suiteStyle(of: extended[0], styles: styles) != nil {
                return extended[0]
            }
        }
        guard container.kind.isTypeDeclaration || container.kind == .extensionKind else { return nil }
        return try reader.suiteStyle(of: container, styles: styles) != nil ? container : nil
    }

    /// Whether `member` is eligible to carry its own source beneath its signature — always `false` for a test, which is recorded as its suite's latest instead.
    ///
    /// Run over every member of a suite, whichever page of the digest ends up served: the last test is a fact about the suite, not about one page of it, so recording it can never depend on what pagination keeps. Eligibility for inlining is decided here too, but the source itself — and the budget and withheld count it costs — is charged only once `inline(_:member:indent:)` is called, which the caller does only for members a page actually serves (Docs/Design.md §3).
    func classify(_ member: SymbolRow, suite: SymbolRow) throws -> Bool {
        if try reader.testStyle(of: member, styles: styles, owners: [suite]) != nil {
            // Members arrive in the order the digest lists them, so the latest seen is the last listed.
            if let index = lastTests.firstIndex(where: { $0.suite.id == suite.id }) {
                lastTests[index] = (suite, member)
            } else {
                lastTests.append((suite, member))
            }
            return false
        }
        return inlining && Self.isHelperShaped(member)
    }

    /// `line` — the member's own line in the digest — with `member`'s source beneath it at `indent`, or unchanged.
    ///
    /// Charges the helper budget and the withheld count, so call it only for a member a served page actually carries.
    func inline(_ line: String, member: SymbolRow, indent: String) -> String {
        // A body that could not be read is withheld like one over the cap — counted, never dropped in silence;
        // an empty one is already said in full by its signature and range.
        guard let body = Self.body(of: member, under: repoRoot) else {
            withheld += 1
            return line
        }
        guard !body.isEmpty else { return line }
        guard body.count <= Self.lineCap, body.count <= linesLeft else {
            withheld += 1
            return line
        }
        linesLeft -= body.count
        return ([line] + Self.reindented(body, under: indent + "    ")).joined(separator: "\n")
    }

    /// The lines that close the digest: how many helpers were left uninlined, then each suite's last test, one line per suite.
    var closingLines: [String] {
        var lines: [String] = []
        if withheld > 0 {
            lines.append("(\(withheld) helper\(withheld == 1 ? "" : "s") named by signature and range only — helper source is inlined up to \(Self.lineCap) lines each and \(Self.budget) in all)")
        }
        for (suite, test) in lastTests {
            lines.append("last test in \(suite.name): \(test.name) — \(test.path)\(test.rangeDescription) — a new test goes after line \(test.endLine)")
        }
        return lines.isEmpty ? [] : [""] + lines
    }

    /// The member kinds a body can belong to.
    ///
    /// A stored property's whole declaration is already its signature line.
    private static func isHelperShaped(_ row: SymbolRow) -> Bool {
        switch row.kind {
        case .function, .initializer, .subscriptKind: true
        case .variable: !row.isStored
        default: false
        }
    }

    /// The lines of a declaration's body — exactly the source between its own `{` and `}` — empty when that holds nothing, or `nil` when no body could be read at all.
    ///
    /// The brace pair is found by parsing the member's own source, not by scanning its text for "the first line ending in `{`": a signature whose own opening brace carries a trailing comment (`func f() -> Int { // note`) has no line that ends in one, and the scan would otherwise settle on a brace opening a nested block instead.
    ///
    /// Sliced at the braces themselves, not at the lines they sit on, so code sharing a line with either one is kept: `func f() { let x = 7` opens a body whose first statement is `let x = 7`, and `_ = 8 }` closes one whose last is `_ = 8`. Dropping either would serve a body that refers to what it no longer shows — or serve nothing and say nothing. What follows the opening brace on its line stands at the indentation of the lines beneath it, the level it belongs to.
    static func body(of row: SymbolRow, under repoRoot: URL) -> [String]? {
        guard case let .lines(all, _) = SourceSlicer.slice(of: row, under: repoRoot),
              let inner = bodyText(of: all)
        else { return nil }
        var lines = inner.components(separatedBy: "\n")
        let afterOpening = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        if let beforeClosing = lines.popLast() {
            let kept = String(beforeClosing.reversed().drop(while: \.isWhitespace).reversed())
            if !kept.isEmpty {
                lines.append(kept)
            }
        }
        if !afterOpening.isEmpty {
            let indents = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map { String($0.prefix { $0 == " " || $0 == "\t" }) }
            let indent = indents.min { $0.count < $1.count } ?? ""
            lines.insert(indent + afterOpening, at: 0)
        }
        return lines.contains { !$0.allSatisfy(\.isWhitespace) } ? lines : []
    }

    /// The source strictly between the brace pair that opens and closes a member's own body, as written.
    ///
    /// `lines` is wrapped in a throwaway one-member host type before parsing, so a function, an initializer, a subscript and a computed property all parse the same way regardless of what is legal at file scope; the braces' byte positions are in the wrapped text, which is what is sliced.
    private static func bodyText(of lines: [String]) -> String? {
        let wrapped = "struct Scratchpad {\n" + lines.joined(separator: "\n") + "\n}\n"
        let tree = Parser.parse(source: wrapped)
        guard let first = tree.statements.first,
              case let .decl(hostDecl) = first.item,
              let host = hostDecl.as(StructDeclSyntax.self),
              let member = host.memberBlock.members.first?.decl,
              let (leftBrace, rightBrace) = braces(of: member),
              leftBrace.presence == .present, rightBrace.presence == .present
        else { return nil }
        let utf8 = wrapped.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: leftBrace.endPositionBeforeTrailingTrivia.utf8Offset)
        let end = utf8.index(utf8.startIndex, offsetBy: rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset)
        guard start <= end else { return nil }
        return String(wrapped[start ..< end])
    }

    /// The brace pair that opens and closes `decl`'s own body, for the member kinds a helper can be.
    private static func braces(of decl: DeclSyntax) -> (TokenSyntax, TokenSyntax)? {
        if let function = decl.as(FunctionDeclSyntax.self), let body = function.body {
            return (body.leftBrace, body.rightBrace)
        }
        if let initializer = decl.as(InitializerDeclSyntax.self), let body = initializer.body {
            return (body.leftBrace, body.rightBrace)
        }
        if let subscriptDecl = decl.as(SubscriptDeclSyntax.self), let accessors = subscriptDecl.accessorBlock {
            return (accessors.leftBrace, accessors.rightBrace)
        }
        if let variable = decl.as(VariableDeclSyntax.self), let accessors = variable.bindings.first?.accessorBlock {
            return (accessors.leftBrace, accessors.rightBrace)
        }
        return nil
    }

    /// `lines` moved under `indent`: their shared leading whitespace taken off, so a helper reads one level beneath its signature whatever depth it was written at, and a blank line left empty rather than carrying the indent.
    static func reindented(_ lines: [String], under indent: String) -> [String] {
        let shared = lines
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        return lines.map { $0.allSatisfy(\.isWhitespace) ? "" : indent + $0.dropFirst(shared) }
    }
}
