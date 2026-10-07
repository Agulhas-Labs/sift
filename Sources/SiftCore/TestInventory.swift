//
// Copyright © Agulhas Labs
//

import Foundation

/// Every test the index can see, with the static disposition each one's declaration promises.
///
/// This is the count of what is *supposed* to run, which no runner's output carries: a crash loses the tests that never started, a retry counts attempts, a plan's exclusion leaves no trace, and a test target in no plan compiles on every build and is never run by anything.
///
/// Recognition is `TestSymbolReader`'s, unchanged — a file whose imports name a testing library, a `@Test` function or a `test…()` method on an `XCTestCase` — so a test counted here is the same declaration `affected` names.
///
/// One addition is the runner's rather than the declaration's: a case also declares every `test…` method its superclasses in the repository declare, because XCTest runs each of them under the subclass as well.
public struct TestInventory: Sendable {
    /// Every declared test, ordered by target, then suite, then function.
    public let tests: [DeclaredTest]
    /// The distinct targets among those tests whose module attribution was guessed rather than read from a build file, sorted.
    public let guessedTargets: [String]
    /// The cases each XCTest case is a superclass of, directly or further down, keyed and listed as `module/suite`, generic cases never among those listed.
    var descendants: [String: [String]] = [:]
    /// The XCTest cases, as `module/suite`, that declare generic parameters and so run nothing themselves.
    var genericCases: Set<String> = []
    /// The runtime class name of each XCTest case nested inside another type, keyed as `module/suite` — the one spelling `xcodebuild -only-testing:` selects such a case by — for every case whose enclosing types are all spelt by `MangledClassName`.
    var runtimeCaseNames: [String: String] = [:]

    /// Reads the whole inventory from an index, parsing each test file at most once for the bodies that decide whether a test runs.
    public static func read(store: IndexStore, repositoryRoot: URL) throws -> TestInventory {
        let reader = TestSymbolReader(store: store)
        let files = try store.fileInventory()
        var tests: [DeclaredTest] = []
        var cases: [(row: SymbolRow, suite: String)] = []
        var genericSuites: Set<String> = []
        var runtimeCaseNames: [String: String] = [:]
        var caseCompilations: [String: DeclaredTest.Compilation] = [:]
        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            let styles = TestSymbolReader.styles(importedBy: file)
            guard !styles.isEmpty else { continue }
            let rows = try reader.symbols(inFile: path)
            let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let openings = styles.contains(.xcTest) ? openings(ofFileAt: path, under: repositoryRoot) : [:]
            let regions = rows.contains { $0.ifConfigCondition != nil } ? compilationRegions(ofFileAt: path, under: repositoryRoot) : []
            for row in rows where row.kind == .classKind && styles.contains(.xcTest) {
                let chain = Self.owners(of: row, in: rowsByID) + [row]
                guard try reader.suiteStyle(of: row, styles: styles) == .xcTest, let suite = try TestSymbolReader.suiteName(of: chain, store: store) else { continue }
                cases.append((row, suite))
                caseCompilations["\(file.module)/\(suite)"] = compilation(of: row, in: regions)
                runtimeCaseNames["\(file.module)/\(suite)"] = MangledClassName.mangled(module: TestIdentifier.moduleName(ofTarget: file.module), chain: chain)
                if chain.contains(where: Self.isGeneric) {
                    genericSuites.insert("\(file.module)/\(suite)")
                }
            }
            for row in rows where row.kind == .function {
                let owners = Self.owners(of: row, in: rowsByID)
                guard let style = try reader.testStyle(of: row, styles: styles, owners: owners) else { continue }
                let attributeArguments = AttributeScanner.attributeArguments(in: row.signature, named: "Test")
                try tests.append(DeclaredTest(
                    target: file.module,
                    targetWasGuessed: file.moduleGuessed,
                    suite: TestSymbolReader.suiteName(of: owners, store: store) ?? "",
                    function: row.name,
                    style: style,
                    displayName: displayName(inAttributeArguments: attributeArguments),
                    disposition: disposition(of: row, style: style, attributeArguments: attributeArguments, owners: owners, openings: openings),
                    path: path,
                    line: row.line,
                    compilation: compilation(of: row, in: regions)
                ))
            }
        }
        // A generic case lends its methods to its subclasses and runs none of them itself.
        let (inherited, descendants) = try inherited(by: cases, from: tests, skipping: genericSuites, reader: reader, files: files)
        // An inherited method is compiled under its subclass only where both the method and the subclass are.
        let compiledUnderCase = inherited.map { test in
            var test = test
            test.compilation = combined(test.compilation, caseCompilations["\(test.target)/\(test.suite)"] ?? .compiled)
            return test
        }
        tests = tests.filter { $0.style != .xcTest || !genericSuites.contains("\($0.target)/\($0.suite)") } + compiledUnderCase
        tests.sort { ($0.target, $0.suite, $0.function) < ($1.target, $1.suite, $1.function) }
        let guessed = Set(tests.filter(\.targetWasGuessed).map(\.target))
        return TestInventory(tests: tests, guessedTargets: guessed.sorted(), descendants: descendants, genericCases: genericSuites, runtimeCaseNames: runtimeCaseNames)
    }

    /// Every test that declares its own `@Test("…")` literal, grouped under the name a log prints it by, which is the only thing that can say whose an ending carrying one is.
    ///
    /// The whole inventory, unbounded by any run's scope: a sharded reconciliation spends one of these only on a test the shard was given and heard nothing from, so a literal declared by a test outside the run can never be spent on anything.
    public var displayNames: [String: [TestIdentifier]] {
        var names: [String: [TestIdentifier]] = [:]
        for test in tests {
            guard let logName = test.logName, let identifier = test.identifier else { continue }
            names[logName, default: []].append(identifier)
        }
        return names.mapValues { $0.sorted { $0.enumerated < $1.enumerated } }
    }

    /// Every test whose declaration makes it conditional, which a run decides at runtime and may report nothing for without having lost it.
    ///
    /// The whole inventory, unbounded by any run's scope, as ``displayNames`` is: a sharded reconciliation asks it only about the tests its plan holds.
    public var conditionalTests: Set<TestIdentifier> {
        Set(tests.compactMap { test in
            guard case .conditional = test.disposition else { return nil }
            return test.identifier
        })
    }
}

private extension TestInventory {
    /// The declarations enclosing a row, outermost first, taken from the file's own rows rather than a query per test.
    static func owners(of row: SymbolRow, in rowsByID: [Int64: SymbolRow]) -> [SymbolRow] {
        var chain: [SymbolRow] = []
        var parentID = row.parentID
        while let id = parentID, let parent = rowsByID[id] {
            chain.append(parent)
            parentID = parent.parentID
        }
        return chain.reversed()
    }

    /// The `test…` methods each case inherits from the superclasses the repository declares, declared again under the case that runs them, and the cases each superclass lends to.
    ///
    /// XCTest runs every `test…` method a case's superclasses declare as a test of that case, so a base's methods run once under each subclass, and a subclass that writes none of its own still runs them all. The nearest declaration of a name wins — an override is the subclass's own test, declared once — and an inherited test keeps the site and disposition of the method it runs, since that is the body that runs. A generic case in `genericSuites` inherits nothing, since it runs nothing, and lends only the methods its own body declares: an extension of a generic class cannot expose a method to the Objective-C runtime XCTest discovers tests through, so `swift test list` names none of them.
    static func inherited(
        by cases: [(row: SymbolRow, suite: String)],
        from declared: [DeclaredTest],
        skipping genericSuites: Set<String>,
        reader: TestSymbolReader,
        files: [String: FileRow]
    ) throws -> (tests: [DeclaredTest], descendants: [String: [String]]) {
        let bySuite = Dictionary(grouping: declared.filter { $0.style == .xcTest }) { "\($0.target)/\($0.suite)" }
        let suites = Dictionary(cases.map { ($0.row.id, $0.suite) }, uniquingKeysWith: { first, _ in first })
        var inherited: [DeclaredTest] = []
        var descendants: [String: [String]] = [:]
        for testCase in cases where !genericSuites.contains("\(testCase.row.module)/\(testCase.suite)") {
            var functions = Set((bySuite["\(testCase.row.module)/\(testCase.suite)"] ?? []).map(\.function))
            var seen: Set<Int64> = [testCase.row.id]
            var ancestor = try reader.superclass(of: testCase.row)
            while let base = ancestor, seen.insert(base.id).inserted {
                let key = "\(base.module)/\(suites[base.id] ?? base.name)"
                descendants[key, default: []].append("\(testCase.row.module)/\(testCase.suite)")
                let lent = (bySuite[key] ?? []).filter { !genericSuites.contains(key) || Self.isInsideBody(of: base, $0) }
                for test in lent where functions.insert(test.function).inserted {
                    inherited.append(DeclaredTest(
                        target: testCase.row.module,
                        targetWasGuessed: files[testCase.row.path]?.moduleGuessed ?? false,
                        suite: testCase.suite,
                        function: test.function,
                        style: .xcTest,
                        displayName: nil,
                        disposition: test.disposition,
                        path: test.path,
                        line: test.line,
                        compilation: test.compilation
                    ))
                }
                ancestor = try reader.superclass(of: base)
            }
        }
        return (inherited, descendants)
    }

    /// Whether a class declares generic parameters of its own, which XCTest never runs as a case: there is no one specialisation for it to instantiate.
    static func isGeneric(_ row: SymbolRow) -> Bool {
        // The signature is the source text, so a class whose name is written in backticks is found by that spelling.
        guard row.kind == .classKind,
              let written = row.signature.range(of: "class \(row.name)") ?? row.signature.range(of: "class `\(row.name)`") else { return false }
        return row.signature[written.upperBound...].drop(while: \.isWhitespace).first == "<"
    }

    /// Whether a test is declared in a class's own body rather than in an extension of it.
    static func isInsideBody(of row: SymbolRow, _ test: DeclaredTest) -> Bool {
        test.path == row.path && row.line <= test.line && test.line <= row.endLine
    }

    /// The openings of one file's function bodies, keyed by the name the join matches on.
    ///
    /// A file the index holds but the working tree no longer does contributes nothing, which reads every test in it as running — the honest reading, since there is no body left to say otherwise.
    static func openings(ofFileAt path: String, under repositoryRoot: URL) -> [String: [TestBodyOpening]] {
        guard let source = try? String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8) else { return [:] }
        return Dictionary(grouping: TestBodyScanner.openings(in: source, path: path), by: \.name)
    }

    /// The `#if` clauses of one file and what the host makes of each, read only for a file where some declaration sits inside one.
    ///
    /// A file the working tree no longer holds contributes none, which reads its tests as compiled — the reading ``openings(ofFileAt:under:)`` gives such a file too.
    static func compilationRegions(ofFileAt path: String, under repositoryRoot: URL) -> [HostCompilation.Region] {
        guard let source = try? String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8) else { return [] }
        return HostCompilation.regions(in: source)
    }

    /// Whether the host compiles a declaration, read from the clauses around its line, with the condition the index recorded for it.
    static func compilation(of row: SymbolRow, in regions: [HostCompilation.Region]) -> DeclaredTest.Compilation {
        guard let condition = row.ifConfigCondition else { return .compiled }
        return switch HostCompilation.state(atLine: row.line, in: regions) {
        case .active: .compiled
        case .inactive: .compiledOut(condition: condition)
        case .undecided: .undecided(condition: condition)
        }
    }

    /// Two declarations' compilation as one: compiled out where either is, undecided where either is, and compiled otherwise.
    static func combined(_ first: DeclaredTest.Compilation, _ second: DeclaredTest.Compilation) -> DeclaredTest.Compilation {
        switch (first, second) {
        case (.compiledOut, _): first
        case (_, .compiledOut): second
        case (.undecided, _): first
        default: second
        }
    }

    /// The display name a test wrote for itself: the unlabelled string literal that opens its `@Test` arguments.
    ///
    /// The first argument is what decides it, because `@Test(.disabled("not ready"))` opens with a trait whose own literal is a reason and never a name.
    static func displayName(inAttributeArguments arguments: String?) -> String? {
        guard let arguments else { return nil }
        let leading = arguments.drop(while: \.isWhitespace)
        guard leading.first == "\"" else { return nil }
        return AttributeScanner.firstStringLiteral(in: String(leading))
    }

    /// The disposition of one test, in the order the declaration decides it.
    ///
    /// The function's own annotation is read first, then its body, then the suite's annotation: a `@Test(.disabled(…))` on the function wins over a `@Suite(.disabled(…))` on the type that owns it, and inherits nothing from it.
    ///
    /// A mixed file's openings hold XCTest bodies only, but the dictionary is keyed by name alone, so it is read for `style == .xcTest` tests only — a swift-testing test sharing a name with an XCTest one elsewhere in the file must not inherit that one's exclusion.
    static func disposition(
        of row: SymbolRow,
        style: TestSymbol.Style,
        attributeArguments: String?,
        owners: [SymbolRow],
        openings: [String: [TestBodyOpening]]
    ) -> DeclaredTest.Disposition {
        if let arguments = attributeArguments {
            if let disabled = AttributeScanner.traitArguments(in: arguments, named: "disabled") {
                return .disabled(reason: AttributeScanner.firstStringLiteral(in: disabled))
            }
            if AttributeScanner.traitArguments(in: arguments, named: "enabled") != nil {
                return .conditional(marker: "enabled(if:)")
            }
        }
        // Both sides record the position after the declaration's leading trivia — `SymbolVisitor.head(of:headEnd:)`
        // for the row and `TestBodyScanner` for the opening — so a row's line is the opening's first line and an
        // equality would serve. The containment join is kept because it is the weaker claim of the two: it survives
        // either side moving its anchor onto the attribute or onto the `func` keyword, and costs nothing.
        if style == .xcTest, let opening = openings[row.name]?.first(where: { $0.startLine <= row.line && row.line <= $0.endLine }) {
            return opening.disposition
        }
        for owner in owners.reversed() {
            guard let suiteArguments = AttributeScanner.attributeArguments(in: owner.signature, named: "Suite"),
                  let disabled = AttributeScanner.traitArguments(in: suiteArguments, named: "disabled")
            else { continue }
            return .disabled(reason: AttributeScanner.firstStringLiteral(in: disabled))
        }
        return .runs
    }
}
