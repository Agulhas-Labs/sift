//
// Copyright © Agulhas Labs
//

/// Answers the two questions the affected-tests walk asks of the syntactic index: which declaration encloses a given line, and whether that declaration is (or sits inside) a test.
///
/// **Recognition is by shape, from rows the index already holds, not from the build system.** A file whose import list carries `Testing` or `XCTest` is a test file and its module is the test target; a `func` whose signature carries `@Test` is a swift-testing test; a `test…` instance method inside a class whose inheritance reaches `XCTestCase` is an XCTest one. Reading `.testTarget` out of a SwiftPM manifest would have been the other candidate and would have covered exactly one of the three build systems this tool resolves modules from — the same "supported at the paths we look in" mistake Docs/Design.md §2 records against XcodeGen. Shape covers all three at once, and it covers a repository whose build files the resolver cannot read at all.
///
/// The cost of that choice is stated where it is felt: `-only-testing:` names the *module*, which is the target name for SwiftPM and for any Xcode target that has not overridden `PRODUCT_MODULE_NAME` — see `AffectedBlindSpots`.
final class TestSymbolReader {
    private let store: IndexStore
    private var symbolsByFile: [String: [SymbolRow]] = [:]
    private var fileRows: [String: FileRow?] = [:]
    private var suiteCache: [Int64: TestSymbol.Style?] = [:]
    private var extensionSuiteCache: [Int64: TestSymbol.Style?] = [:]

    init(store: IndexStore) {
        self.store = store
    }

    /// Every declaration in one file, innermost-last, read once per query however many hits land in it.
    func symbols(inFile path: String) throws -> [SymbolRow] {
        if let cached = symbolsByFile[path] {
            return cached
        }
        let rows = try store.symbols(inFile: path)
        symbolsByFile[path] = rows
        return rows
    }

    /// The innermost declaration whose source range covers `line`, or `nil` when the line sits outside every declaration (an import, a top-level comment, a file the index has no rows for).
    ///
    /// Innermost rather than outermost because the walk follows *what referenced the changed symbol*, and that is the method, not the type it happens to live in — expanding the type would drag in every other member's references as if they shared the dependency.
    func enclosingSymbol(path: String, line: Int) throws -> SymbolRow? {
        try symbols(inFile: path)
            .filter { $0.line <= line && line <= $0.endLine }
            .min { ($0.endLine - $0.line, $0.line) < ($1.endLine - $1.line, $1.line) }
    }

    /// The test this declaration is, or sits inside — `nil` when it is ordinary code, including a helper inside a test target.
    ///
    /// Three grains, coarsening outward. A `@Test`/`test…` function is named individually. A reference landing anywhere else *inside a suite* — a stored property, a private helper method, the inheritance clause, a helper type nested in it that is no suite — names the **whole suite**, because nothing in the evidence singles out which of its tests uses that member, and a suite's own private members are suite-scoped by construction: `makeBuiltRepo()` is used by every test in the suite that declares it. Over-inclusive is the direction to err. The suite is not the end of the road, though: a helper of one suite is often called from the tests of others, so `affected` records the suite and follows the helper's own references as well. Anything in a test target that is not inside a suite at all — a shared fixture type, a file of free helpers — is not a test: the walk follows its references rather than reporting it.
    func testSymbol(enclosing row: SymbolRow) throws -> TestDeclaration? {
        guard let file = try fileRow(path: row.path) else { return nil }
        let styles = Self.styles(importedBy: file)
        let chain = try store.parentChain(of: row) + [row]
        // A file with no test-library import holds no test of its own, but an extension in it can still extend a suite declared in another file, so only the outward walk below may go on.
        guard !styles.isEmpty || chain.contains(where: { $0.kind == .extensionKind }) else { return nil }
        for index in chain.indices.reversed() where !styles.isEmpty {
            let owners = Array(chain[..<index])
            guard let style = try testStyle(of: chain[index], styles: styles, owners: owners) else { continue }
            let symbol = try TestSymbol(
                target: file.module,
                suite: Self.suiteName(of: owners, store: store),
                function: Self.runnerName(of: chain[index], style: style),
                style: style
            )
            return TestDeclaration(symbol: symbol, path: row.path, line: chain[index].line)
        }
        // Nothing in the chain is a test, so the reference sits in the suite's own surface — a stored property, an inheritance clause, a helper member. Every test in that suite is built from what changed, and naming one of them would be a claim the evidence does not support.
        // A type nested in a suite that has no tests of its own is part of that suite's surface, at any depth, so the nearest enclosing type that is a suite is the one named; a nested type with tests of its own is a suite and is the nearest. An extension counts as a suite when it is one itself or when the type it extends, in the same module, is — the shape a helper takes where the linter forbids nesting a type in a primary type's body — and an extension of a type that is no suite stays no suite.
        let types = chain.filter { $0.kind.isTypeDeclaration || $0.kind == .extensionKind }
        for index in types.indices.reversed() {
            guard let style = try outerSuiteStyle(of: types[index], styles: styles) else { continue }
            let symbol = try TestSymbol(target: file.module, suite: Self.suiteName(of: Array(types[...index]), store: store), function: nil, style: style)
            let helperType = types[types.index(after: index)...].last { $0.kind.isTypeDeclaration }
            return TestDeclaration(symbol: symbol, path: row.path, line: types[index].line, helperType: helperType)
        }
        return nil
    }

    /// The suite path a runner spells, built from the type and extension rows enclosing a test.
    ///
    /// An extension written with its own module's name in front of the type drops that prefix, since the runner's selector carries the module once; a prefix naming another module stays, and so does one that names a top-level type sharing the module's name, which takes precedence over the module.
    ///
    /// Not `private`: `TestInventory` spells a suite the same way, rather than inventing a second path that a join would then have to reconcile with this one.
    static func suiteName(of owners: [SymbolRow], store: IndexStore) throws -> String? {
        let types = owners.filter { $0.kind.isTypeDeclaration || $0.kind == .extensionKind }
        return try types.isEmpty ? nil : types.map { try Self.spelledName(of: $0, store: store) }.joined(separator: ".")
    }

    /// A type or extension row's name as a suite path spells it: an extension's own module prefix removed.
    private static func spelledName(of row: SymbolRow, store: IndexStore) throws -> String {
        let prefix = row.module + "."
        guard row.kind == .extensionKind, row.name.hasPrefix(prefix) else { return row.name }
        let shadowed = try store.typeDeclarations(named: row.module, inModule: row.module).contains { $0.parentID == nil }
        guard !shadowed else { return row.name }
        return String(row.name.dropFirst(prefix.count))
    }

    /// The stored row for a file, cached including the miss — a path outside the index is asked about once per query, not once per hit.
    private func fileRow(path: String) throws -> FileRow? {
        if let cached = fileRows[path] {
            return cached
        }
        let row = try store.fileRow(path: path)
        fileRows[path] = .some(row)
        return row
    }

    /// The testing libraries a file's imports declare, empty when it is not a test file at all.
    ///
    /// Both at once is an ordinary file — a suite migrating from one library to the other — so the imports only say which arms may fire, and each declaration is then decided by its own shape: a `@Test` marker makes a swift-testing test, and a `test…` method on an `XCTestCase` an XCTest one.
    ///
    /// Not `private`: `SuiteAnnotation`, which a test suite's digest is built through, reads a file's libraries the same way, rather than inventing a second copy of the recognition rule.
    static func styles(importedBy file: FileRow) -> Set<TestSymbol.Style> {
        var styles: Set<TestSymbol.Style> = []
        if file.imports.contains("Testing") {
            styles.insert(.swiftTesting)
        }
        if file.imports.contains("XCTest") {
            styles.insert(.xcTest)
        }
        return styles
    }

    /// The library one declaration is a test of, given the libraries its file imports and the declarations that enclose it, or `nil` when it is not a test function.
    ///
    /// A `@Test` marker is swift-testing's whatever else the file imports, because the marker is that library's own. The XCTest arm restates the runtime's own discovery rule — an instance method taking no arguments whose name begins with `test`, on an `XCTestCase` — rather than inventing a looser one, because a name that only *looks* like a test would put an identifier in the `-only-testing:` list that the runner then rejects, and a rejected argument fails the whole invocation rather than one test.
    ///
    /// Not `private`: `SuiteAnnotation` classifies a suite's own members the same way, to tell its tests from its helpers.
    func testStyle(of row: SymbolRow, styles: Set<TestSymbol.Style>, owners: [SymbolRow]) throws -> TestSymbol.Style? {
        guard row.kind == .function else { return nil }
        if AttributeScanner.attributeNames(in: row.signature).contains("Test") {
            return .swiftTesting
        }
        guard styles.contains(.xcTest), !row.isStatic, row.baseName.hasPrefix("test"), row.name.hasSuffix("()") else { return nil }
        // The innermost enclosing declaration, not the innermost class: a method of a struct nested in a test case is a test of neither, and the runner rejects the path that would name it.
        guard let owner = owners.last, owner.kind == .classKind || owner.kind == .extensionKind else { return nil }
        return try inheritsXCTestCase(owner) ? .xcTest : nil
    }

    /// The library an enclosing type or extension is a suite of, for the outward walk: an extension that is no suite by its own signature or members still counts when the type it extends, in the same module, is one.
    private func outerSuiteStyle(of row: SymbolRow, styles: Set<TestSymbol.Style>) throws -> TestSymbol.Style? {
        if let own = try suiteStyle(of: row, styles: styles) {
            return own
        }
        guard row.kind == .extensionKind else { return nil }
        if let cached = extensionSuiteCache[row.id] {
            return cached
        }
        var verdict: TestSymbol.Style?
        for declaration in try exactlyExtendedTypes(of: row) where declaration.module == row.module {
            // The suite's own file decides its library, not the file the extension is written in.
            guard let declaringFile = try fileRow(path: declaration.path),
                  let style = try suiteStyle(of: declaration, styles: Self.styles(importedBy: declaringFile))
            else { continue }
            verdict = style
            break
        }
        extensionSuiteCache[row.id] = verdict
        return verdict
    }

    /// The library a type is a suite of, when it is a suite whose every test the reference implicates, or `nil` when it is none.
    ///
    /// Not `private`: `SuiteAnnotation` reads this to decide which of a file's top-level declarations to look inside for tests and helpers at all.
    func suiteStyle(of row: SymbolRow, styles: Set<TestSymbol.Style>) throws -> TestSymbol.Style? {
        if let cached = suiteCache[row.id] {
            return cached
        }
        let verdict: TestSymbol.Style? = if styles.contains(.xcTest), try inheritsXCTestCase(row) {
            .xcTest
        } else if !styles.contains(.swiftTesting) {
            nil
        } else if AttributeScanner.attributeNames(in: row.signature).contains("Suite") {
            .swiftTesting
        } else {
            // An unannotated `struct XTests { @Test func … }` is the commonest suite shape there is: swift-testing infers the suite from the members, so the members are what has to be read.
            try store.children(of: row.id).contains { AttributeScanner.attributeNames(in: $0.signature).contains("Test") } ? .swiftTesting : nil
        }
        suiteCache[row.id] = verdict
        return verdict
    }

    /// Whether a class's written inheritance reaches `XCTestCase`, following named superclasses declared in this repository and the typealiases visible from wherever each name was written.
    ///
    /// Unbounded but cycle-guarded rather than depth-capped: a shared base test case two or three subclasses deep is ordinary, and a cap would silently stop recognising tests at whatever depth it was set to — the failure mode this whole command exists to avoid. Syntax cannot tell a superclass from a protocol, so every inherited name is followed; a protocol name simply resolves to a protocol declaration that inherits nothing called `XCTestCase`.
    ///
    /// An extension answers for the class it extends, because XCTest runs the `test…` methods an extension adds and an extension's own clause can only add conformances — but only for a same-named type its own file can see, since an extension can extend nothing else. Only a class qualifies at the start, since nothing else can inherit one.
    private func inheritsXCTestCase(_ row: SymbolRow) throws -> Bool {
        let classes = try (row.kind == .extensionKind ? exactlyExtendedTypes(of: row) : [row]).filter { $0.kind == .classKind }
        var seen = Set(classes.map(\.id))
        var pending: [(name: String, path: String)] = []
        for declaration in classes {
            try pending.append(contentsOf: store.inheritedNames(of: declaration.id).map { (Self.unspecialised($0), declaration.path) })
        }
        while let (name, path) = pending.popLast() {
            if name == "XCTestCase" {
                return true
            }
            for declaration in try store.typeDeclarations(named: name) where seen.insert(declaration.id).inserted {
                try pending.append(contentsOf: store.inheritedNames(of: declaration.id).map { (Self.unspecialised($0), declaration.path) })
            }
            for alias in try typealiases(named: name, visibleFrom: path) where seen.insert(alias.id).inserted {
                if let aliased = Self.aliasedName(in: alias.signature) {
                    pending.append((aliased, alias.path))
                }
            }
        }
        return false
    }

    /// The class a class's written superclass names, resolved within the modules its file can see, or `nil` where the chain leaves the repository.
    ///
    /// Only the clause's first entry can be a superclass, so it is the only one read. A name resolves in the declaring file's own module before the modules it imports, and through the typealiases visible from wherever it was written, as ``inheritsXCTestCase(_:)`` resolves it. A name that resolves to no class — `XCTestCase` itself, a type from outside the repository — or to more than one ends the chain rather than guessing between them.
    ///
    /// Not `private`: `TestInventory` walks this chain to declare the `test…` methods a case inherits.
    func superclass(of row: SymbolRow) throws -> SymbolRow? {
        guard let written = try store.inheritedNames(of: row.id).first else { return nil }
        var name = Self.unspecialised(written)
        var path = row.path
        var aliasesSeen: Set<Int64> = []
        while true {
            let visible = try visibleModules(of: path)
            let classes = try store.typeDeclarations(named: name).filter { $0.kind == .classKind && visible.contains($0.module) }
            let local = classes.filter { $0.module == row.module }
            let candidates = local.isEmpty ? classes : local
            guard candidates.isEmpty else {
                return candidates.count == 1 ? candidates[0] : nil
            }
            guard let alias = try typealiases(named: name, visibleFrom: path).first(where: { aliasesSeen.insert($0.id).inserted }),
                  let aliased = Self.aliasedName(in: alias.signature)
            else { return nil }
            name = aliased
            path = alias.path
        }
    }

    /// A written type name without its generic arguments: `BaseCase<Int>` names the class `BaseCase`.
    private static func unspecialised(_ written: String) -> String {
        String(written.prefix { $0 != "<" }).trimmingCharacters(in: .whitespaces)
    }

    /// The type declarations an extension extends, found by the last component of the name it wrote, filtered to the modules its own file can see.
    private func extendedTypes(of row: SymbolRow) throws -> [SymbolRow] {
        let name = row.name.split(separator: ".").last.map(String.init) ?? row.name
        let visible = try visibleModules(of: row.path)
        return try store.typeDeclarations(named: name).filter { visible.contains($0.module) }
    }

    /// The type declarations an extension extends, matched on the whole written name rather than its last component: `extension Inner` extends a top-level `Inner` and `extension Outer.Inner` the `Inner` declared in `Outer`, never a same-named type elsewhere.
    private func exactlyExtendedTypes(of row: SymbolRow) throws -> [SymbolRow] {
        let written = try Self.suiteName(of: [row], store: store)
        return try extendedTypes(of: row).filter { declaration in
            try Self.suiteName(of: store.parentChain(of: declaration) + [declaration], store: store) == written
        }
    }

    /// The top-level typealiases declared under a name, in a module the given path's file can see.
    ///
    /// Scoped to the file's own module plus the modules it imports, so an alias another module happens to spell the same way does not stand in for it unless that module is actually visible there.
    private func typealiases(named name: String, visibleFrom path: String) throws -> [SymbolRow] {
        let visible = try visibleModules(of: path)
        return try store.symbols(named: name).filter { $0.kind == .typealiasKind && $0.parentID == nil && visible.contains($0.module) }
    }

    /// The modules a file at the given path can see: its own module plus every module it imports.
    private func visibleModules(of path: String) throws -> Set<String> {
        guard let file = try fileRow(path: path) else { return [] }
        return Set(file.imports).union([file.module])
    }

    /// The type a typealias's stored signature names, without its generic arguments, or `nil` when the signature names none.
    private static func aliasedName(in signature: String) -> String? {
        guard let equals = signature.firstIndex(of: "=") else { return nil }
        let aliased = signature[signature.index(after: equals)...]
            .drop { $0.isWhitespace }
            .prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return aliased.isEmpty ? nil : String(aliased)
    }

    /// The function as its runner spells it: swift-testing keeps the labelled form (`argvDecidesTheFilter(arguments:expected:)`, verified against `swift test list`), XCTest names the selector without parentheses.
    private static func runnerName(of row: SymbolRow, style: TestSymbol.Style) -> String {
        switch style {
        case .swiftTesting: row.name
        case .xcTest: row.baseName
        }
    }
}
